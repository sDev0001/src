#!/usr/bin/env python3
"""
Ingest: PDF / Markdown / txt / cod / HTML  ->  chunks  ->  embeddings  ->  index.

Incremental: reproceseaza doar fisierele modificate si re-embed doar chunk-urile noi.
Ruleaza dupa ce ai pornit serverele:  bin/serve.sh start && bin/ingest.py
"""
import os, re, sys, json, time, hashlib, shutil, subprocess, tempfile
import urllib.request

import numpy as np

if sys.version_info < (3, 7):
    sys.exit("Nevoie de Python 3.7+. Ruleaza:  dnf install python3.11")

# Consola minimala are adesea LANG=C -> Python crapa la diacritice. Fortam UTF-8.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ------------------------------------------------------------------ config
H          = os.environ.get("AGENT_HOME", "/opt/agent")
DOCS_DIRS  = [d for d in os.environ.get("DOCS_DIRS", H + "/docs").split(":") if d]
DATA       = os.environ.get("DATA_DIR", H + "/data")
EMB_URL    = os.environ.get("EMB_URL", "http://127.0.0.1:8081")
CHUNK      = int(os.environ.get("CHUNK_CHARS", 1100))
OVERLAP    = int(os.environ.get("CHUNK_OVERLAP", 180))
BATCH      = int(os.environ.get("EMB_BATCH", 16))
OCR_LANGS  = os.environ.get("OCR_LANGS", "ron+eng+rus")

TEXT_EXT = {".md", ".markdown", ".txt", ".rst", ".adoc", ".org",
            ".py", ".js", ".ts", ".go", ".java", ".sh", ".sql",
            ".yaml", ".yml", ".toml", ".ini", ".conf", ".json"}
HTML_EXT = {".html", ".htm", ".xhtml"}
SKIP_DIR = {".git", "node_modules", "__pycache__", ".venv", "venv",
            "dist", "build", ".next", "target", ".idea", ".cache"}
MAX_FILE_MB = 25

CHUNKS_F   = os.path.join(DATA, "chunks.jsonl")
EMB_F      = os.path.join(DATA, "emb.npy")
MANIFEST_F = os.path.join(DATA, "manifest.json")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ extractie
def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True,
                          errors="replace", **kw)


def have(prog):
    return shutil.which(prog) is not None


def ocr_pdf(path):
    """Fallback pentru PDF scanate (imagini). Lent, dar ruleaza o singura data."""
    if not (have("pdftoppm") and have("tesseract")):
        log("    ! PDF scanat dar lipseste pdftoppm/tesseract - sarit")
        return None
    pages = []
    with tempfile.TemporaryDirectory() as td:
        sh(["pdftoppm", "-r", "200", "-png", path, os.path.join(td, "p")])
        imgs = sorted(f for f in os.listdir(td) if f.endswith(".png"))
        for i, img in enumerate(imgs, 1):
            log("    OCR pagina %d/%d" % (i, len(imgs)))
            r = sh(["tesseract", os.path.join(td, img), "-",
                    "-l", OCR_LANGS, "--psm", "3"])
            pages.append(r.stdout)
    return pages


def extract_pdf(path):
    if not have("pdftotext"):
        log("    ! lipseste pdftotext (dnf install poppler-utils)")
        return []
    r = sh(["pdftotext", "-layout", "-enc", "UTF-8", "-q", path, "-"])
    pages = r.stdout.split("\f")
    if pages and not pages[-1].strip():
        pages.pop()
    if not pages:
        return []
    avg = sum(len(p.strip()) for p in pages) / len(pages)
    if avg < 40:                      # aproape gol => PDF scanat
        log("    PDF pare scanat (%.0f car/pag) -> OCR" % avg)
        ocr = ocr_pdf(path)
        if ocr:
            pages = ocr
    return [("pag. %d" % i, p) for i, p in enumerate(pages, 1) if p.strip()]


def extract_html(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    raw = re.sub(r"(?is)<(script|style|nav|footer)[^>]*>.*?</\1>", " ", raw)
    raw = re.sub(r"(?s)<[^>]+>", " ", raw)
    raw = raw.replace("&nbsp;", " ").replace("&amp;", "&")
    return [("", raw)]


def extract_text(path):
    return [("", open(path, encoding="utf-8", errors="replace").read())]


def extract(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        return extract_pdf(path)
    if ext in HTML_EXT:
        return extract_html(path)
    if ext in TEXT_EXT:
        return extract_text(path)
    return []


# ------------------------------------------------------------------ chunking
def clean(t):
    t = t.replace("­", "").replace("\x00", "")
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def split_chunks(text):
    """Taie pe paragrafe, cu suprapunere, fara sa rupa fraza la mijloc."""
    text = clean(text)
    if not text:
        return []
    paras = re.split(r"\n\s*\n", text)
    out, cur = [], ""
    for p in paras:
        p = p.strip()
        if not p:
            continue
        if len(p) > CHUNK:                       # paragraf urias -> taie pe fraze
            for s in re.split(r"(?<=[.!?:;])\s+", p):
                if len(cur) + len(s) + 1 > CHUNK and cur:
                    out.append(cur.strip())
                    cur = cur[-OVERLAP:]
                cur += " " + s
        else:
            if len(cur) + len(p) + 2 > CHUNK and cur:
                out.append(cur.strip())
                cur = cur[-OVERLAP:]
            cur += "\n\n" + p
    if cur.strip():
        out.append(cur.strip())
    return [c for c in out if len(c) > 60]


def chunk_id(path, loc, text):
    raw = ("%s|%s|%s" % (path, loc, text)).encode("utf-8")
    return hashlib.sha1(raw).hexdigest()[:20]


# ------------------------------------------------------------------ embeddings
def embed(texts, retries=3):
    body = json.dumps({"input": texts, "model": "emb"}).encode("utf-8")
    req = urllib.request.Request(EMB_URL + "/v1/embeddings", data=body,
                                 headers={"Content-Type": "application/json"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                data = json.loads(r.read())
            rows = sorted(data["data"], key=lambda d: d.get("index", 0))
            return [d["embedding"] for d in rows]
        except Exception as e:
            if attempt == retries - 1:
                raise
            log("    ! embed a esuat (%s), reincerc..." % e)
            time.sleep(2)


def normalize(m):
    m = np.asarray(m, dtype=np.float32)
    n = np.linalg.norm(m, axis=1, keepdims=True)
    n[n == 0] = 1.0
    return m / n


# ------------------------------------------------------------------ index vechi
def load_previous():
    """Returneaza {chunk_id: vector} din indexul existent, ca sa nu re-embedam."""
    if not (os.path.exists(CHUNKS_F) and os.path.exists(EMB_F)):
        return {}
    try:
        ids = [json.loads(l)["id"]
               for l in open(CHUNKS_F, encoding="utf-8") if l.strip()]
        emb = np.load(EMB_F)
        if len(ids) != emb.shape[0]:
            log("    ! index vechi inconsistent, il reconstruiesc")
            return {}
        return dict(zip(ids, emb))
    except Exception as e:
        log("    ! nu pot citi indexul vechi (%s), il reconstruiesc" % e)
        return {}


def walk_files():
    seen = set()
    for root_dir in DOCS_DIRS:
        if not os.path.isdir(root_dir):
            continue
        for root, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIR and not d.startswith(".")]
            for f in sorted(files):
                p = os.path.join(root, f)
                ext = os.path.splitext(f)[1].lower()
                if ext != ".pdf" and ext not in TEXT_EXT and ext not in HTML_EXT:
                    continue
                try:
                    if os.path.getsize(p) > MAX_FILE_MB * 1024 * 1024:
                        continue
                except OSError:
                    continue
                rp = os.path.realpath(p)
                if rp in seen:
                    continue
                seen.add(rp)
                yield p


# ------------------------------------------------------------------ main
def main():
    os.makedirs(DATA, exist_ok=True)

    try:
        urllib.request.urlopen(EMB_URL + "/health", timeout=5).read()
    except Exception:
        log("EROARE: serverul de embeddings nu raspunde la " + EMB_URL)
        log("        porneste-l intai:  bin/serve.sh start")
        sys.exit(1)

    old_vecs = load_previous()
    files = list(walk_files())
    if not files:
        log("Nu am gasit niciun document in: " + ", ".join(DOCS_DIRS))
        sys.exit(1)
    log("==> %d fisiere de procesat\n" % len(files))

    chunks = []
    for n, path in enumerate(files, 1):
        log("[%d/%d] %s" % (n, len(files), path))
        try:
            parts = extract(path)
        except Exception as e:
            log("    ! eroare la extractie: %s" % e)
            continue
        cnt = 0
        for loc, txt in parts:
            for c in split_chunks(txt):
                chunks.append({"id": chunk_id(path, loc, c),
                               "path": path, "loc": loc, "text": c})
                cnt += 1
        log("    %d chunk-uri" % cnt)

    # deduplicare (acelasi text aparut in doua locuri)
    uniq, seen = [], set()
    for c in chunks:
        if c["id"] in seen:
            continue
        seen.add(c["id"])
        uniq.append(c)
    chunks = uniq

    todo = [c for c in chunks if c["id"] not in old_vecs]
    log("\n==> %d chunk-uri total, %d noi de embedat" % (len(chunks), len(todo)))

    new_vecs = {}
    t0 = time.time()
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        vecs = embed([c["text"] for c in batch])
        for c, v in zip(batch, vecs):
            new_vecs[c["id"]] = np.asarray(v, dtype=np.float32)
        done = min(i + BATCH, len(todo))
        el = time.time() - t0
        eta = el / max(done, 1) * (len(todo) - done)
        log("    embed %d/%d  (~%.1f min ramase)" % (done, len(todo), eta / 60))

    dim = None
    for src in (new_vecs, old_vecs):
        if src:
            dim = len(next(iter(src.values())))
            break
    if dim is None:
        log("Nimic de indexat.")
        sys.exit(1)

    mat, keep = [], []
    for c in chunks:
        v = new_vecs.get(c["id"])
        if v is None:
            v = old_vecs.get(c["id"])
        if v is None or len(v) != dim:
            continue
        keep.append(c)
        mat.append(v)

    emb = normalize(np.vstack(mat))

    tmp_c = CHUNKS_F + ".tmp"
    tmp_e = EMB_F + ".tmp"
    with open(tmp_c, "w", encoding="utf-8") as f:
        for c in keep:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    np.save(tmp_e, emb)
    os.replace(tmp_c, CHUNKS_F)
    os.replace(tmp_e + ".npy", EMB_F)

    json.dump({"built": time.strftime("%Y-%m-%d %H:%M:%S"),
               "files": len(files), "chunks": len(keep), "dim": int(dim)},
              open(MANIFEST_F, "w"), indent=2)

    log("\n==> GATA: %d chunk-uri, dim=%d" % (len(keep), dim))
    log("    " + CHUNKS_F)
    log("    " + EMB_F)


if __name__ == "__main__":
    main()
