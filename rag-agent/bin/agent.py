#!/usr/bin/env python3
"""
Agent RAG local peste documentatia ta.

Cautare hibrida: semantica (embeddings) + cuvinte-cheie (BM25), fuzionate prin RRF.
Raspuns generat de llama-server, in streaming, cu citarea surselor.

Folosire:
    bin/agent.py                      # mod interactiv
    bin/agent.py --once "intrebare"   # o singura intrebare (pentru scripturi)
    bin/agent.py --show               # arata si textul chunk-urilor gasite
"""
import os, re, sys, json, math, unicodedata
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

try:                      # sageti sus/jos + istoric in consola SSH
    import readline       # noqa: F401
except Exception:
    pass

H         = os.environ.get("AGENT_HOME", "/opt/agent")
DATA      = os.environ.get("DATA_DIR", H + "/data")
EMB_URL   = os.environ.get("EMB_URL", "http://127.0.0.1:8081")
LLM_URL   = os.environ.get("LLM_URL", "http://127.0.0.1:8080")
TOP_K     = int(os.environ.get("TOP_K", 8))
CAND_K    = int(os.environ.get("CAND_K", 40))
TEMP      = float(os.environ.get("TEMPERATURE", 0.2))
MAX_TOK   = int(os.environ.get("MAX_TOKENS", 1024))

CHUNKS_F  = os.path.join(DATA, "chunks.jsonl")
EMB_F     = os.path.join(DATA, "emb.npy")

SYSTEM = """Esti un asistent tehnic care raspunde EXCLUSIV pe baza documentatiei furnizate in context.

Reguli stricte:
1. Foloseste doar informatia din fragmentele marcate [1], [2], ... Nu inventa, nu completa din memorie.
2. Citeaza sursa dupa fiecare afirmatie, in forma [1] sau [2][3].
3. Daca documentatia nu contine raspunsul, scrie exact:
   "Nu am gasit informatia in documentatie."
   si, optional, spune ce fragment ar fi fost cel mai apropiat.
4. Daca fragmentele se contrazic, semnaleaza contradictia si citeaza ambele.
5. Raspunde in romana, concis si structurat. Pentru pasi, foloseste liste numerotate.
   Pentru comenzi sau cod, foloseste blocuri ``` .
"""

STOP_RO = set("""
si sau dar ca ce cum cand unde care cine este sunt era fost fi fie am ai are avem aveti au
la de din pe cu pentru prin fara catre spre intre despre dupa inainte peste sub langa
un o unul una niste acest aceasta acel acea aceste acesti acei acele
eu tu el ea noi voi ei ele mine tine lui ei nostru vostru lor se sa isi ii le il
mai foarte cel cea cei cele mult multa multi multe tot toata toti toate
nu da ma te ne va li al a ai ale in intr intru cat cate catva
the and or of to in for with without on at by is are was were be been this that these those
""".split())


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def die(msg):
    log("EROARE: " + msg)
    sys.exit(1)


# ------------------------------------------------------------------ tokenizare
def deaccent(s):
    s = unicodedata.normalize("NFD", s)
    return "".join(c for c in s if unicodedata.category(c) != "Mn")


def tokenize(s):
    s = deaccent(s.lower())
    toks = re.findall(r"[a-z0-9_\.\-]{2,}", s)
    return [t.strip(".-") for t in toks
            if t not in STOP_RO and len(t.strip(".-")) > 1]


# ------------------------------------------------------------------ index
class Index:
    def __init__(self):
        if not (os.path.exists(CHUNKS_F) and os.path.exists(EMB_F)):
            die("indexul lipseste. Ruleaza intai:  bin/ingest.py")
        self.chunks = [json.loads(l) for l in open(CHUNKS_F, encoding="utf-8") if l.strip()]
        self.emb = np.load(EMB_F).astype(np.float32)
        if len(self.chunks) != self.emb.shape[0]:
            die("index inconsistent. Sterge %s si %s si ruleaza din nou ingest.py"
                % (CHUNKS_F, EMB_F))
        self._build_bm25()
        log("==> index: %d chunk-uri, dim=%d" % (len(self.chunks), self.emb.shape[1]))

    def _build_bm25(self):
        self.docs = [tokenize(c["text"]) for c in self.chunks]
        self.dl = np.array([len(d) for d in self.docs], dtype=np.float32)
        self.avgdl = float(self.dl.mean()) if len(self.dl) else 1.0
        self.postings = {}
        for i, d in enumerate(self.docs):
            tf = {}
            for t in d:
                tf[t] = tf.get(t, 0) + 1
            for t, f in tf.items():
                self.postings.setdefault(t, []).append((i, f))
        n = len(self.docs)
        self.idf = {t: math.log(1 + (n - len(p) + 0.5) / (len(p) + 0.5))
                    for t, p in self.postings.items()}

    def bm25(self, query, k=CAND_K, k1=1.5, b=0.75):
        scores = {}
        for t in set(tokenize(query)):
            p = self.postings.get(t)
            if not p:
                continue
            idf = self.idf[t]
            for i, f in p:
                denom = f + k1 * (1 - b + b * self.dl[i] / self.avgdl)
                scores[i] = scores.get(i, 0.0) + idf * (f * (k1 + 1)) / denom
        return sorted(scores, key=scores.get, reverse=True)[:k]

    def dense(self, qvec, k=CAND_K):
        sims = self.emb @ qvec
        k = min(k, len(sims))
        top = np.argpartition(-sims, k - 1)[:k]
        return list(top[np.argsort(-sims[top])]), sims

    def search(self, query, qvec, top_k=TOP_K):
        """Reciprocal Rank Fusion intre cautarea densa si BM25."""
        d_ids, sims = self.dense(qvec, CAND_K)
        b_ids = self.bm25(query, CAND_K)
        rrf = {}
        for rank, i in enumerate(d_ids):
            rrf[i] = rrf.get(i, 0.0) + 1.0 / (60 + rank)
        for rank, i in enumerate(b_ids):
            rrf[i] = rrf.get(i, 0.0) + 1.0 / (60 + rank)
        # bonus mic pentru fragmente din acelasi fisier ca top-1 dens
        best = sorted(rrf, key=rrf.get, reverse=True)[:top_k]
        return [(i, float(sims[i])) for i in best]


# ------------------------------------------------------------------ HTTP
def post_json(url, payload, timeout=900, stream=False):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=timeout)
    return r if stream else json.loads(r.read())


def embed_query(q):
    # bge-m3 nu are nevoie de prefix de instructiune; textul brut e ok
    d = post_json(EMB_URL + "/v1/embeddings", {"input": [q], "model": "emb"})
    v = np.asarray(d["data"][0]["embedding"], dtype=np.float32)
    n = np.linalg.norm(v)
    return v / (n if n else 1.0)


def stream_answer(messages):
    payload = {
        "model": "local",
        "messages": messages,
        "temperature": TEMP,
        "top_p": 0.9,
        "max_tokens": MAX_TOK,
        "stream": True,
        # Qwen3 hibrid: opreste modul "thinking" (mult mai rapid pentru RAG)
        "chat_template_kwargs": {"enable_thinking": False},
    }
    out = []
    try:
        resp = post_json(LLM_URL + "/v1/chat/completions", payload, stream=True)
    except Exception:
        # build vechi de llama.cpp / fara --jinja: reincearca fara optiunea Qwen3
        payload.pop("chat_template_kwargs", None)
        try:
            resp = post_json(LLM_URL + "/v1/chat/completions", payload, stream=True)
        except Exception as e:
            log("\n! LLM nu raspunde: %s" % e)
            log("  verifica:  %s/bin/serve.sh status" % H)
            return ""
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        try:
            delta = json.loads(data)["choices"][0]["delta"]
        except Exception:
            continue
        piece = delta.get("content") or ""
        if piece:
            out.append(piece)
            sys.stdout.write(piece)
            sys.stdout.flush()
    print()
    return "".join(out)


# ------------------------------------------------------------------ prompt
def build_context(idx, hits, budget=9000):
    parts, srcs, used = [], [], 0
    for n, (i, score) in enumerate(hits, 1):
        c = idx.chunks[i]
        loc = (", " + c["loc"]) if c["loc"] else ""
        head = "[%d] %s%s" % (n, os.path.basename(c["path"]), loc)
        block = head + "\n" + c["text"]
        if used + len(block) > budget:
            break
        parts.append(block)
        srcs.append("[%d] %s%s  (scor %.2f)" % (n, c["path"], loc, score))
        used += len(block)
    return "\n\n---\n\n".join(parts), srcs


def answer(idx, question, history, show=False):
    try:
        qvec = embed_query(question)
    except Exception as e:
        log("! serverul de embeddings nu raspunde: %s" % e)
        return None
    hits = idx.search(question, qvec, TOP_K)
    if not hits:
        print("Nu am gasit informatia in documentatie.")
        return None

    ctx, srcs = build_context(idx, hits)
    if show:
        log("\n--- context folosit ---\n" + ctx + "\n--- sfarsit context ---\n")

    user = ("=== DOCUMENTATIE ===\n%s\n=== SFARSIT DOCUMENTATIE ===\n\n"
            "Intrebare: %s" % (ctx, question))

    messages = [{"role": "system", "content": SYSTEM}]
    messages += history[-4:]                    # ultimele 2 schimburi
    messages += [{"role": "user", "content": user}]

    print()
    reply = stream_answer(messages)
    print("\nSurse:")
    for s in srcs:
        print("  " + s)
    return reply


# ------------------------------------------------------------------ main
def main():
    args = sys.argv[1:]
    show = "--show" in args
    once = None
    if "--once" in args:
        i = args.index("--once")
        once = " ".join(args[i + 1:]).strip()

    idx = Index()
    history = []

    if once:
        answer(idx, once, history, show)
        return

    print("=== Agent documentatie (local) ===")
    print("Comenzi:  exit | /nou (sterge istoricul) | /k N (nr. fragmente) | "
          "/show | /reload")
    print()
    while True:
        try:
            q = input("Tu> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not q:
            continue
        if q in ("exit", "quit", "/exit", "/q"):
            break
        if q == "/nou":
            history = []
            print("(istoric sters)")
            continue
        if q == "/show":
            show = not show
            print("(afisare context: %s)" % ("ON" if show else "OFF"))
            continue
        if q == "/reload":
            idx = Index()
            continue
        if q.startswith("/k "):
            try:
                globals()["TOP_K"] = int(q.split()[1])
                print("(top_k = %d)" % TOP_K)
            except Exception:
                print("(folosire: /k 8)")
            continue

        reply = answer(idx, q, history, show)
        if reply:
            history += [{"role": "user", "content": q},
                        {"role": "assistant", "content": reply}]
        print()


if __name__ == "__main__":
    main()
