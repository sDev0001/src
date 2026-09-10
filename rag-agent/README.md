# Agent RAG local peste documentație

Server Oracle Linux, **doar consolă, doar CPU, fără placă video**. 100% offline.

## Pornire — o singură comandă

```bash
sudo ./start.sh
```

Atât. Scriptul face singur tot:

1. instalează pachetele lipsă (poppler-utils, tesseract + limba română, python3.11, numpy)
2. creează toate folderele
3. compilează llama.cpp dacă nu-l găsește (5–15 min, o singură dată)
4. descarcă modelul de embeddings (~600 MB)
5. folosește modelul `.gguf` pe care îl ai deja; dacă n-ai niciunul, îl descarcă
6. pornește serverele
7. indexează documentele
8. te lasă în prompt

Poate fi rulat de câte ori vrei — sare peste ce e deja făcut.

```bash
sudo ./start.sh --model-30b   # descarcă și Qwen3-30B-A3B (18 GB, ~4x mai rapid)
sudo ./start.sh --reingest    # reconstruiește indexul de la zero
./start.sh --status           # ce rulează
./start.sh --stop             # oprește serverele
```

## Unde pui documentele

```
/opt/agent/docs/pdf/     PDF-urile         cp *.pdf /opt/agent/docs/pdf/
/opt/agent/docs/repos/   git clone aici    cd /opt/agent/docs/repos && git clone <url>
/opt/agent/docs/md/      markdown, txt, cod
```

După ce adaugi ceva: `sudo ./start.sh` din nou (re-indexează doar ce e nou).

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
sudo ./start.sh
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
/opt/agent/bin/agent.py --once "care sunt pașii de deploy?"
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

## Dacă ceva nu merge

```bash
./start.sh --status
tail -f /opt/agent/logs/llm.log
cat /opt/agent/data/manifest.json    # câte chunk-uri are indexul
```

- ingest zice `0 chunk-uri` pentru un PDF → e scanat și lipsește
  `tesseract-langpack-ron` (OCR-ul durează ~5–15 s/pagină, dar o singură dată)
- descărcarea modelului s-a întrerupt → rulează din nou `start.sh`, `curl -C -`
  continuă de unde a rămas
