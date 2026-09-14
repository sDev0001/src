# Agent documentație — v2, în container

Agent care citește documentația ta locală și răspunde la întrebări.
**100% offline. Doar CPU — nicăieri nu se folosește placa video.**

Față de versiunea veche (`rag-agent/`), aici totul rulează în container. Serverul
nu mai compilează nimic și nu mai depinde de ce pachete are Oracle Linux.

---

## Ce duci pe server

Toată mapa asta. Conține și imaginea Docker gata construită (115 MB), deci pe
server nu se compilează nimic.

```
agent_v2/
├── rag-agent-image.tar.gz   imaginea gata făcută (115 MB)
├── docker-compose.yml       cum pornesc cele două containere
├── run-plain.sh             variantă de rezervă, fără docker compose
├── .env                     SINGURUL fișier pe care îl editezi
├── bin/                     agent.py, ingest.py
└── docker/                  Dockerfile (doar dacă vrei să reconstruiești)
```

---

## Pas cu pas

### 1. Copiezi mapa pe server

Din PowerShell, pe Windows:

```bash
scp -r C:\Users\sergi\Desktop\agenti\agent_v2 root@IP_SERVER:/root/
```

### 2. Încarci imaginea

Pe server:

```bash
cd /root/agent_v2 && docker load < rag-agent-image.tar.gz
```

Durează un minut. De aici încolo serverul are tot ce-i trebuie: llama.cpp
compilat, Python, numpy, `pdftotext`, `tesseract` cu română și rusă.

### 3. Pui documentele

```bash
mkdir -p /root/documentatie
```

Copiezi acolo tot ce ai — PDF-uri, manuale, note, cod. Orice structură de
subfoldere. Le citește pe toate, recursiv.

### 4. Verifici `.env`

```bash
nano /root/agent_v2/.env
```

Trei rânduri contează:

```ini
DOCS_DIR=/root/documentatie
LLM_MODEL_FILE=Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf
THREADS=80
```

Numele modelului trebuie să fie **exact** cum e fișierul. Verifică:

```bash
ls -lh /opt/agent/models/
```

### 5. Pornești

```bash
cd /root/agent_v2 && docker compose run --rm agent
```

Prima pornire încarcă modelul de 18 GB în RAM — durează. După aceea rămâne
încărcat, iar pornirile următoare sunt instantanee.

**Dacă `docker compose` nu există** pe server (Oracle Linux are uneori doar
`docker` simplu, sau podman), folosește varianta de rezervă:

```bash
cd /root/agent_v2 && ./run-plain.sh
```

Face exact același lucru, doar cu `docker run`.

---

## Cum se folosește

Ești într-un prompt obișnuit:

```
Tu> ce presiune maxima suporta pompa?

Pompa P-12 suporta presiunea maxima de 6 bar.

Surse:
  [1] /docs/manuale/pompa-p12.txt  (scor 2.91)
  [4.1s pana la primul cuvant | 7.3s total | ~14 tokeni | 4.4 tok/s]
```

- Dacă întrebarea se potrivește cu documentele, răspunde din ele și **citează sursa**.
- Dacă nu, **discută normal**, ca orice asistent.
- Linia cu timpii îți arată cât a durat — folosește-o ca să vezi dacă merită
  un model mai mic pentru întrebările simple.

Comenzi în prompt: `exit`, `/nou` (șterge istoricul), `/show` (arată fragmentele
brute trimise modelului), `/k 12` (mai multe fragmente), `/reload`.

### Adaugi documente noi

Le copiezi în mapă și pornești din nou. Observă singur ce s-a schimbat și
reindexează doar noutățile.

### Oprești tot

```bash
cd /root/agent_v2 && docker compose down
```

Sau, cu varianta simplă: `./run-plain.sh --stop`

---

## Ce citește

| | |
|---|---|
| PDF | prin `pdftotext`, cu OCR automat dacă e scanat (ro + ru + en) |
| text | `.txt` `.md` `.rst` `.log` `.csv` și orice altă extensie |
| HTML | fără taguri |
| cod | `.js` `.py` `.sql` `.sh` `.yaml` `.json` `.conf` — orice |
| fără extensie | `README`, `Makefile`, `Dockerfile` |

Sare peste imagini, arhive, video, executabile — le recunoaște și după conținut,
nu doar după extensie. **Word și Excel nu se citesc** (sunt arhive zip):
salvează-le ca PDF.

---

## De ce e mai sigur decât varianta veche

| ce pica înainte | de ce nu mai pică |
|---|---|
| gcc prea vechi pe Oracle Linux 8 | compilarea s-a făcut deja, în imagine |
| lipsea EPEL pentru tesseract | e deja în imagine |
| Python 3.6 prea vechi | imaginea are Python 3.11 |
| portul 8081 ocupat | fiecare container are rețeaua lui |
| procese `llama-server` rămase agățate | `docker compose down` le omoară pe toate |
| binar compilat pentru alt procesor | 14 variante de CPU, alege singur la pornire |

Imaginea se verifică singură la construire: dacă `llama-server` nu pornește sau
lipsește numpy / `pdftotext` / `tesseract`, construirea pică atunci, nu pe server
peste două zile.

---

## Porturile: nu e nicio pagină web

Nu ai nevoie de browser și nu se expune nimic în rețea. Cele două containere își
vorbesc pe rețeaua internă a lui Docker:

```
   tu, în consolă
        │
   agent  ──(rețea internă docker)──►  llm   (ține modelul în RAM)
        │
        └──► /docs   mapa ta, montată read-only
```

`docker compose ps` arată coloana PORTS goală — **niciun port publicat** către
mașină. Serverul cu modelul e vizibil doar din celălalt container.

Motivul pentru care e „server" deloc: ca modelul să rămână încărcat în RAM între
întrebări. Altfel s-ar reciti 18 GB de pe disc de fiecare dată.

---

## Dacă ceva nu merge

```bash
docker compose ps              # ce rulează, e "healthy"?
docker compose logs llm        # ce spune serverul cu modelul
docker compose logs --tail 50 llm
free -g                        # mai ai RAM?
```

**Se încarcă la nesfârșit:** modelul de 18 GB chiar durează prima dată.
`healthcheck`-ul așteaptă până la 30 de minute și îți spune clar `healthy` sau
nu. Vezi progresul cu `docker compose logs -f llm`.

**Nu găsește modelul:** numele din `.env` trebuie să fie exact. `run-plain.sh`
îți listează ce fișiere sunt de fapt în mapă.

**Ai editat `.env` în Notepad pe Windows și s-a stricat:** terminațiile CRLF
lasă un caracter invizibil la capătul valorilor. `run-plain.sh` le repară singur;
pentru compose, rulează o dată `./run-plain.sh` și gata.

---

## Reglaje în `.env`

| | |
|---|---|
| `DOCS_DIR` | mapa cu documentele tale |
| `MODELS_DIR` / `LLM_MODEL_FILE` | unde e modelul și cum se cheamă |
| `THREADS` | nuclee **fizice**, nu fire. Mai multe = mai lent |
| `CTX` | cât context citește deodată (mai mare = mai multă RAM, prefill mai lent) |
| `DOC_MIN_SCORE` | sub acest scor tratează întrebarea ca discuție normală |
| `TOP_K` | câte fragmente trimite modelului |
| `MAX_TOKENS` | lungimea maximă a răspunsului |
