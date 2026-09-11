# Agent RAG local peste documentație

Server Oracle Linux, **doar consolă, doar CPU, fără placă video**. 100% offline.

## Cum ajunge pe server

Ai nevoie de **un singur fișier**: `agent-bundle.sh` (21 KB). Conține tot.

Din PowerShell, pe calculatorul tău:

```powershell
scp C:\Users\sergi\Desktop\agenti\rag-agent\agent-bundle.sh root@IP_SERVER:/root/
```

## Pornire

O singură dată, la instalare:

```bash
sudo bash /root/agent-bundle.sh
```

**De atunci înainte, un singur cuvânt, de oriunde:**

```bash
agent
```

Asta e tot. `agent` verifică serverele și le repornește dacă au picat,
reindexează documentele noi dacă ai adăugat ceva, și te lasă direct în prompt.
Nu mai pornești nimic din `bin/` manual.

```bash
agent --status      # ce rulează, ce model, câte fragmente are indexul
agent --stop        # oprește tot
agent --reingest    # reconstruiește indexul de la zero
agent --model-30b   # descarcă Qwen3-30B-A3B (18 GB, ~4x mai rapid)
agent --kill-all    # oprește forțat orice llama-server agățat de porturi
```

### Pornire curată — `agent-fresh`

Dacă vrei să fii sigur că pornește din prima, indiferent ce a rămas agățat de la
rularea anterioară:

```bash
agent-fresh
```

Închide **tot** (orice `llama-server` de pe mașină), așteaptă să se elibereze
porturile, apoi pornește normal: servere, indexare, prompt. E același lucru cu
`agent --fresh`.

Merge și la prima instalare, direct din bundle:

```bash
sudo bash /root/agent-bundle.sh --fresh
```

**Când folosești care:**

| | ce face | cât durează |
|---|---|---|
| `agent` | refolosește serverele deja pornite | secunde |
| `agent-fresh` | oprește tot și reîncarcă modelul în RAM | 1–3 min (modelul se recitește) |

Deci `agent` e comanda de zi cu zi. `agent-fresh` e pentru când ceva s-a blocat.

**Serverele nu mor când închizi SSH-ul.** Modelul rămâne încărcat în RAM, deci a
doua rulare de `agent` intră în prompt imediat, fără să mai aștepte încărcarea.
Doar promptul interactiv se închide odată cu sesiunea SSH. Dacă vrei ca și
promptul să supravieţuiască deconectării, pornește-l în `tmux`:

```bash
tmux new -A -s agent
```

(ieși cu `Ctrl+B` apoi `D`; te întorci cu aceeaşi comandă)

**De ce primeai `command not found`:** `./start.sh` caută fișierul în folderul
în care te afli în acel moment. Comanda `agent` se instalează în
`/usr/local/bin/`, care e în `PATH`, deci merge din orice folder.

### Ce face la prima rulare

1. instalează pachetele lipsă (poppler-utils, tesseract + română, python3.11, numpy)
2. creează toate folderele și comanda `agent`
3. compilează llama.cpp dacă nu-l găsește (5–15 min, o singură dată) — **tu nu
   intri niciodată în folderul llama.cpp**
4. descarcă modelul de embeddings (~600 MB)
5. folosește modelul `.gguf` pe care îl ai deja; dacă n-ai niciunul, îl descarcă
6. pornește serverele
7. indexează documentele și te lasă în prompt

## De ce sunt două servere și un port

Nu vorbești tu cu portul — e cablul intern dintre două programe de pe același
server:

```
     tu, în consolă
          │
     agent.py  ──── caută în index ────►  chunks.jsonl + emb.npy
          │
          ├──► 127.0.0.1:8081   llama-server cu bge-m3   (căutare semantică)
          └──► 127.0.0.1:8080   llama-server cu Qwen3    (scrie răspunsul)
```

Cele două `llama-server` stau pornite ca să țină modelele **încărcate în RAM**.
Asta era exact problema cu `llama-cli`: reîncărca 9 GB de pe disc la fiecare
întrebare. `127.0.0.1` înseamnă că porturile sunt accesibile doar de pe server —
nu sunt expuse în rețea, nu ai nevoie de firewall.

Dacă unul din ele cade, `agent` îl repornește singur. `serve.sh` încearcă mai
multe variante de flaguri (`--embeddings` / `--embedding`, cu și fără
`--pooling cls`, cu și fără `--mlock`), pentru că numele diferă între versiunile
de llama.cpp. Dacă tot nu pornește, îți arată automat ultimele 20 de linii din
log în loc să tacă.

## Docker nu e folosit

llama.cpp rulează nativ, compilat pe serverul tău cu `-DGGML_NATIVE=ON`, ca să
folosească instrucțiunile AVX ale procesorului. Într-un container ai pierde
exact asta și inferența ar fi mai lentă. Nu instalez și nu pornesc Docker; dacă
îl ai deja, scriptul îți spune că e ignorat.

## Unde pui documentele

```
/opt/agent/docs/pdf/     PDF-urile         cp *.pdf /opt/agent/docs/pdf/
/opt/agent/docs/repos/   git clone aici    cd /opt/agent/docs/repos && git clone <url>
/opt/agent/docs/md/      markdown, txt, cod
```

După ce adaugi ceva: `agent` din nou (re-indexează doar ce e nou).

---

## Verificat pentru serverul tău

**Fără interfață grafică.** Niciun program din stivă nu are nevoie de X11 sau
de vreun display:

| Program | Ce face | GUI? |
|---|---|---|
| `pdftotext`, `pdftoppm` | PDF → text / imagine | nu, sunt CLI pure |
| `tesseract` | OCR pentru PDF scanate | nu |
| `llama-server` | rulează modelul | nu, e server HTTP pe 127.0.0.1 |
| `agent.py` | promptul tău | consolă, merge peste SSH |

Trei lucruri pe care le-am reparat special pentru consolă minimală:

- **`LANG=C`** — pe o instalare minimală, Python crapă cu `UnicodeEncodeError`
  la primul „ă". Acum `config.env` forțează `C.UTF-8` și scripturile
  reconfigurează `stdout`.
- **tesseract nu e în repo-urile de bază** ale Oracle Linux — e în EPEL.
  `start.sh` activează EPEL singur.
- **Oracle Linux 8 vine cu Python 3.6**, care nu are `subprocess.capture_output`.
  `start.sh` caută 3.7+ și instalează `python3.11` dacă e nevoie.

**Fără placă video.** `-ngl 0` peste tot; llama.cpp se compilează CPU-only
(fără CUDA). Nimic nu atinge GPU-ul.

**60 GB RAM — încape lejer:**

| | Qwen3-14B (ce ai) | Qwen3-30B-A3B |
|---|---|---|
| greutăți Q4_K_M | 9 GB | 18.6 GB |
| KV-cache @ 16k context | ~1.9 GB | ~1.5 GB |
| buffere de calcul | ~2 GB | ~2 GB |
| model embeddings | 0.7 GB | 0.7 GB |
| **total** | **~14 GB** | **~23 GB** |

Îți rămân 37 GB liberi chiar și cu modelul mare. `--mlock` ține modelul fix în
RAM ca să nu ajungă în swap (scriptul ridică singur `ulimit -l`; dacă nu poate,
renunță la flag în loc să crape).

**Threads.** `-t 64` din scriptul tău era o problemă reală: dacă ai mai puține
nuclee *fizice*, thread-urile în plus se bat pe aceeași memorie și inferența
devine **mai lentă**. Acum se calculează automat cu
`lscpu -p=Core,Socket | sort -u | wc -l`.

---

## Un sfat pentru SSH

Serverele pornesc cu `nohup setsid`, deci supraviețuiesc deconectării. Dar
`agent.py` nu — dacă îți cade SSH-ul în mijlocul unui răspuns, pierzi sesiunea.
Rulează-l în tmux:

```bash
tmux new -s agent
sudo bash /root/agent-bundle.sh
```

Detach cu `Ctrl+b` apoi `d`, revii cu `tmux attach -t agent`.

---

## Cum se folosește

```
Tu> cum se configurează gateway-ul de plată?

Se configurează în `payments.yaml` [2]. Cheia secretă se pune în variabila
de mediu `PAYMENT_SECRET`, nu în fișier [2].

Surse:
  [1] /opt/agent/docs/pdf/manual.pdf, pag. 34  (scor 0.71)
  [2] /opt/agent/docs/repos/api/README.md      (scor 0.68)
```

Comenzi: `exit`, `/nou` (șterge istoricul), `/k 12` (mai multe fragmente),
`/show` (arată contextul brut trimis modelului), `/reload`.

Non-interactiv, pentru scripturi:

```bash
agent --once "care sunt pașii de deploy?"
```

---

## De ce nu mergea scriptul vechi

| Problemă | Efect |
|---|---|
| `llama-cli` la **fiecare** întrebare | reîncărca 9–18 GB de pe disc de fiecare dată |
| `grep` pe `*.txt` dar în folder erau **PDF-uri** | context gol mereu → modelul răspundea din burtă |
| `grep` pe **fiecare cuvânt** din întrebare | căuta și „cum", „este", „de" → context plin de gunoi |
| `-t 64` fix | mai lent, nu mai rapid, dacă ai mai puține nuclee fizice |
| lipsea `-c` | promptul era tăiat silențios |
| heredoc nequotat cu `$(cat ...)` | conținutul documentelor era interpretat de shell |

Înlocuite cu: `llama-server` rezident + căutare hibridă (embeddings pentru sens
+ BM25 pentru termeni exacți, fuzionate prin RRF) + prompt construit în Python.

Saltul real de calitate vine din căutare, nu din model: `grep` nu găsește
„cum configurez plata" într-un document care scrie „setarea gateway-ului de
tranzacții". Embeddings da.

---

## Reglaje (`/opt/agent/config.env`)

Nu trebuie să modifici nimic — totul se detectează singur. Dacă totuși vrei:

- **răspunde prea general** → `TOP_K=12`, `CTX=24576`
- **prea lent** → `CTX=8192`
- **nu găsește lucruri care sigur sunt în documente** → `agent.py --show` ca să
  vezi ce fragmente a extras; la documente cu tabele mari, `CHUNK_CHARS=700`

## Ce am testat și ce nu

Testat automat aici:

- sintaxa tuturor scripturilor (`bash -n`, `py_compile`)
- bundle-ul despachetează cele 5 fișiere **byte cu byte identice**, fără CRLF
- logica de căutare hibridă pe un index de test — întrebarea „cum creez o
  comandă prin API?" găsește fragmentul corect, cu diacriticele normalizate
- auto-detecția de threads, model și foldere
- două bug-uri prinse de teste și reparate: `set -e` oprea bundle-ul înainte
  să ajungă la `start.sh`, și `mkdir` era presupus reușit fără verificare

**Nu am putut testa** compilarea llama.cpp și `dnf install` — pentru asta ar
trebui un Oracle Linux real. De aceea fiecare pas își verifică rezultatul și se
oprește cu un mesaj clar în loc să continue în gol.

## Dacă ceva nu merge

```bash
bash /root/agent-bundle.sh --status
tail -f /opt/agent/logs/llm.log
cat /opt/agent/data/manifest.json    # câte chunk-uri are indexul
```

- ingest zice `0 chunk-uri` pentru un PDF → e scanat și lipsește
  `tesseract-langpack-ron` (OCR-ul durează ~5–15 s/pagină, dar o singură dată)
- descărcarea modelului s-a întrerupt → rulează din nou `start.sh`, `curl -C -`
  continuă de unde a rămas
