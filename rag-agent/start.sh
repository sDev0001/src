#!/usr/bin/env bash
# ============================================================================
#  Agent RAG local, offline, CPU-only.  UN SINGUR SCRIPT.
#
#     sudo bash start.sh
#
#  Face tot: instaleaza pachetele, compileaza llama.cpp daca lipseste,
#  creeaza folderele, descarca modelul de embeddings, porneste serverele,
#  indexeaza documentele si te lasa in prompt.
#  Nu trebuie sa intri niciodata in folderul llama.cpp si sa nu editezi nimic.
#  Poate fi rulat de oricate ori: sare peste ce e deja facut si repara ce a picat.
#  Dupa prima rulare instaleaza comanda globala "agent" -- de atunci scrii doar
#  "agent", de oriunde, si ea face tot: verifica serverele, reindexeaza ce e nou
#  si te lasa in prompt.
#
#  Optiuni:
#     --model-30b   descarca Qwen3-30B-A3B (18 GB, de ~4x mai rapid pe CPU)
#     --reingest    forteaza reconstruirea completa a indexului
#     --no-agent    porneste doar serverele, fara promptul interactiv
#     --show        arata si fragmentele brute trimise modelului
#     --once "..."  o singura intrebare, non-interactiv (pentru scripturi)
#     --stop        opreste serverele
#     --status      arata ce ruleaza, ce model, cate fragmente are indexul
#     --docs CALE   arata-i mapa cu documentele (o tine minte de atunci)
#     --kill-all    opreste FORTAT orice llama-server ramas agatat de porturi
#     --semantic    porneste si cautarea semantica (al doilea server, 600 MB)
#     --no-semantic revine la cautarea pe cuvinte (implicit, un singur server)
#     --fresh       inchide TOT, elibereaza porturile, apoi porneste de la zero
#                   (acelasi lucru: comanda  agent-fresh )
# ============================================================================
set -uo pipefail

# Fisierele copiate de pe Windows au CRLF -> bash da "command not found" sau
# "bad interpreter". Ne reparam singuri si repornim.
if [ -f "$0" ] && LC_ALL=C grep -q $'\r' "$0" 2>/dev/null; then
  _d="$(cd "$(dirname "$0")" && pwd)"
  sed -i 's/\r$//' "$0" "$_d"/config.env "$_d"/bin/* 2>/dev/null
  exec bash "$0" "$@"
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="${AGENT_HOME:-/opt/agent}"

# Setarile memorate de la rularea trecuta (mapa cu documente, tipul de cautare)
if [ -z "${DOCS_DIR:-}" ] && [ -f "$AGENT_HOME/data/docs_dir" ]; then
  DOCS_DIR="$(cat "$AGENT_HOME/data/docs_dir" 2>/dev/null)"
fi
if [ -z "${USE_EMBEDDINGS:-}" ] && [ -f "$AGENT_HOME/data/use_emb" ]; then
  USE_EMBEDDINGS="$(cat "$AGENT_HOME/data/use_emb" 2>/dev/null)"
fi
export DOCS_DIR="${DOCS_DIR:-$AGENT_HOME/docs}"
export USE_EMBEDDINGS="${USE_EMBEDDINGS:-0}"

WANT_30B=0; REINGEST=0; RUN_AGENT=1; ACTION=start; ONCE=""; SHOW=""; FRESH=0
DOCS_SET=""; SEMANTIC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model-30b) WANT_30B=1 ;;
    --reingest)  REINGEST=1 ;;
    --no-agent)  RUN_AGENT=0 ;;
    --stop)      ACTION=stop ;;
    --status)    ACTION=status ;;
    --kill-all)  ACTION=kill-all ;;
    --fresh)     FRESH=1 ;;
    --docs)      shift; DOCS_SET="${1:-}" ;;
    --semantic)    SEMANTIC=1 ;;
    --no-semantic) SEMANTIC=0 ;;
    --show)      SHOW="--show" ;;
    --once)      shift; ONCE="$*"; break ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Optiune necunoscuta: $1"; echo "Vezi:  agent --help"; exit 1 ;;
  esac
  shift
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mEROARE: %s\033[0m\n' "$*" >&2; exit 1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif command -v sudo >/dev/null; then sudo "$@"
  else die "nu sunt root si nu am sudo. Ruleaza ca root: su - ; bash $0"
  fi
}

# ------------------------------------------------------------------- --fresh
# Inchide tot ce a ramas pornit, asteapta sa se elibereze porturile, apoi
# scriptul isi urmeaza cursul normal si porneste totul de la zero.
# Nu depinde de nimic din ce e deja instalat: merge si daca /opt/agent e vechi.
port_taken() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

fresh_cleanup() {
  local i p n
  say "0/7  Inchid ce a ramas pornit"

  n="$(pgrep -c -f llama-server 2>/dev/null || true)"
  case "${n:-0}" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    warn "$n proces(e) llama-server pornite - le opresc"
    as_root pkill -f llama-server 2>/dev/null || true
    for i in $(seq 1 15); do
      pgrep -f llama-server >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f llama-server >/dev/null 2>&1; then
      warn "nu s-au oprit frumos, le opresc fortat"
      as_root pkill -9 -f llama-server 2>/dev/null || true
      sleep 2
    fi
  fi
  if pgrep -f llama-server >/dev/null 2>&1; then
    warn "au ramas procese llama-server pe care nu le pot opri (alt utilizator?)"
  else
    ok "niciun llama-server pornit"
  fi

  rm -f "$AGENT_HOME/logs/llm.pid" "$AGENT_HOME/logs/emb.pid"         "$AGENT_HOME/data/ports.env" 2>/dev/null

  for p in "${LLM_PORT:-8080}" "${EMB_PORT:-8081}"; do
    for i in $(seq 1 20); do
      port_taken "$p" || break
      sleep 1
    done
    if port_taken "$p"; then
      warn "portul $p e ocupat de altceva - agentul va folosi automat alt port"
    else
      ok "portul $p: liber"
    fi
  done
}

if [ "$FRESH" = 1 ] && [ "$ACTION" = start ]; then
  fresh_cleanup
fi

# ---------------------------------------------------------------- stop/status
if [ "$ACTION" != start ]; then
  # shellcheck source=/dev/null
  [ -f "$AGENT_HOME/config.env" ] || die "$AGENT_HOME/config.env lipseste. Ruleaza intai: sudo bash start.sh"
  source "$AGENT_HOME/config.env"
  bash "$AGENT_HOME/bin/serve.sh" "$ACTION"
  exit $?
fi

# ---------------------------------------------------------------- 1. pachete
say "1/7  Pachete de sistem"
NEED=""
command -v pdftotext >/dev/null || NEED="$NEED poppler-utils"
command -v tesseract >/dev/null || NEED="$NEED tesseract"
command -v git       >/dev/null || NEED="$NEED git"
command -v curl      >/dev/null || NEED="$NEED curl"
command -v cmake     >/dev/null || NEED="$NEED cmake"
command -v g++       >/dev/null || NEED="$NEED gcc-c++"
command -v make      >/dev/null || NEED="$NEED make"
command -v tar       >/dev/null || NEED="$NEED tar"
command -v lscpu     >/dev/null || NEED="$NEED util-linux"
command -v setsid    >/dev/null || NEED="$NEED util-linux"
command -v free      >/dev/null || NEED="$NEED procps-ng"
command -v pgrep     >/dev/null || NEED="$NEED procps-ng"
command -v tmux      >/dev/null || NEED="$NEED tmux"
command -v ss        >/dev/null || NEED="$NEED iproute"

# Python >= 3.7 (avem nevoie de subprocess capture_output).
# Oracle Linux 8 vine cu 3.6 -> instalam python3.11. OL9 are 3.9, e ok.
find_py() {
  local c
  for c in python3.12 python3.11 python3.10 python3.9 python3; do
    command -v "$c" >/dev/null || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info>=(3,7) else 1)' 2>/dev/null; then
      echo "$c"; return 0
    fi
  done
  return 1
}
PY="$(find_py)" || NEED="$NEED python3.11 python3.11-pip"

if [ -n "$NEED" ]; then
  warn "lipsesc:$NEED"
  command -v dnf >/dev/null || die "nu gasesc dnf. Instaleaza manual:$NEED"
  as_root dnf install -y dnf-plugins-core >/dev/null 2>&1 || true

  # tesseract nu e in repo-urile de baza Oracle Linux, e in EPEL
  if echo "$NEED" | grep -q tesseract; then
    # shellcheck source=/dev/null
    . /etc/os-release 2>/dev/null || true
    MAJ="${VERSION_ID%%.*}"
    as_root dnf install -y "oracle-epel-release-el${MAJ}" >/dev/null 2>&1 \
      || as_root dnf install -y epel-release >/dev/null 2>&1 \
      || warn "nu am putut activa EPEL - OCR-ul pentru PDF scanate va lipsi"
    as_root dnf config-manager --set-enabled "ol${MAJ}_developer_EPEL" >/dev/null 2>&1 || true
  fi

  # shellcheck disable=SC2086
  as_root dnf install -y $NEED || warn "unele pachete nu s-au instalat, continui"
  as_root dnf install -y tesseract-langpack-ron tesseract-langpack-rus >/dev/null 2>&1 \
    || warn "lipsesc pachetele de limba tesseract - OCR va merge doar pe engleza"

  PY="$(find_py)" || true
fi

[ -n "${PY:-}" ] || die "nu am Python 3.7+.
        Incearca manual:  dnf install python3.11 python3.11-pip"
ok "python:    $PY ($("$PY" -V 2>&1))"
ok "pdftotext: $(command -v pdftotext || echo 'LIPSA - PDF-urile nu vor fi citite!')"
ok "tesseract: $(command -v tesseract || echo 'lipsa (doar PDF scanate afectate)')"

if ! "$PY" -c 'import numpy' 2>/dev/null; then
  as_root dnf install -y python3-numpy >/dev/null 2>&1 || true
  if ! "$PY" -c 'import numpy' 2>/dev/null; then
    "$PY" -m ensurepip --default-pip >/dev/null 2>&1 || true
    "$PY" -m pip install --quiet numpy \
      || die "nu am putut instala numpy. Incearca:  $PY -m pip install numpy"
  fi
fi
ok "numpy:     $("$PY" -c 'import numpy;print(numpy.__version__)')"
command -v docker >/dev/null && ok "docker:    instalat, dar NU e folosit (llama.cpp ruleaza nativ)"

# ---------------------------------------------------------------- 2. foldere
say "2/7  Foldere in $AGENT_HOME"
as_root mkdir -p "$AGENT_HOME"/models "$AGENT_HOME"/data "$AGENT_HOME"/logs \
                 "$AGENT_HOME"/bin "$AGENT_HOME"/docs/pdf "$AGENT_HOME"/docs/repos \
                 "$AGENT_HOME"/docs/md
[ "$(id -u)" -ne 0 ] && as_root chown -R "$(id -u):$(id -g)" "$AGENT_HOME"
if [ "$SELF_DIR" != "$AGENT_HOME/bin" ]; then
  cp "$SELF_DIR/config.env" "$AGENT_HOME/config.env"
  cp "$SELF_DIR"/bin/agent.py "$SELF_DIR"/bin/ingest.py "$SELF_DIR"/bin/serve.sh \
     "$AGENT_HOME/bin/"
  cp "$SELF_DIR/start.sh" "$AGENT_HOME/bin/start.sh"
fi
chmod +x "$AGENT_HOME"/bin/* 2>/dev/null || true
# shebang-ul .py sa arate exact spre interpretorul gasit
sed -i "1s|.*|#!$(command -v "$PY")|" "$AGENT_HOME"/bin/agent.py "$AGENT_HOME"/bin/ingest.py

# O SINGURA comanda globala: "agent". Face tot, de fiecare data, de oriunde.
printf '#!/usr/bin/env bash\nexec bash %s/bin/start.sh "$@"\n' "$AGENT_HOME" \
  > "/tmp/.agent-cmd.$$"
if as_root install -m 755 "/tmp/.agent-cmd.$$" /usr/local/bin/agent 2>/dev/null; then
  ok "comanda globala: agent"
else
  warn "nu am putut crea /usr/local/bin/agent (foloseste: bash $AGENT_HOME/bin/start.sh)"
fi
rm -f "/tmp/.agent-cmd.$$"

# ... si o scurtatura pentru repornirea curata: inchide tot, apoi porneste.
printf '#!/usr/bin/env bash
exec bash %s/bin/start.sh --fresh "$@"
' "$AGENT_HOME"   > "/tmp/.agent-fresh.$$"
if as_root install -m 755 "/tmp/.agent-fresh.$$" /usr/local/bin/agent-fresh 2>/dev/null; then
  ok "comanda globala: agent-fresh  (inchide tot, apoi porneste curat)"
fi
rm -f "/tmp/.agent-fresh.$$"
# --- mapa cu documentele si tipul de cautare ---------------------
if [ -n "$DOCS_SET" ]; then
  [ -d "$DOCS_SET" ] || die "mapa nu exista: $DOCS_SET"
  DOCS_DIR="$(cd "$DOCS_SET" && pwd)"
  echo "$DOCS_DIR" > "$AGENT_HOME/data/docs_dir"
  export DOCS_DIR
fi
if [ -n "$SEMANTIC" ]; then
  echo "$SEMANTIC" > "$AGENT_HOME/data/use_emb"
  export USE_EMBEDDINGS="$SEMANTIC"
fi
ok "documente: $DOCS_DIR"
if [ "$USE_EMBEDDINGS" = 1 ]; then
  ok "cautare:   pe cuvinte + semantica (doua servere)"
else
  ok "cautare:   pe cuvinte (un singur server)"
fi

# ---------------------------------------------------------------- 3. llama.cpp
say "3/7  llama.cpp (build CPU, fara GPU)"
LLAMA_BIN=""
for d in "$AGENT_HOME/llama.cpp/build/bin" "$HOME/llama.cpp/build/bin" \
         "/root/llama.cpp/build/bin" "/opt/llama.cpp/build/bin" \
         "/usr/local/bin" "/usr/bin"; do
  [ -x "$d/llama-server" ] && { LLAMA_BIN="$d"; break; }
done

if [ -z "$LLAMA_BIN" ]; then
  warn "nu gasesc llama-server, il compilez acum (5-15 min, o singura data)"
  SRC="$AGENT_HOME/llama.cpp"
  if [ ! -d "$SRC/.git" ]; then
    curl -sfI --max-time 20 https://github.com >/dev/null \
      || die "serverul nu ajunge la github.com. Verifica internetul sau proxy-ul."
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC" \
      || die "git clone a esuat"
  fi

  build_llama() {
    cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
          -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF \
      && cmake --build "$SRC/build" --target llama-server -j "$(nproc)"
  }

  if ! build_llama; then
    # Oracle Linux 8 are gcc 8.5, prea vechi pentru C++17 cerut de llama.cpp
    warn "build eșuat cu gcc $(g++ -dumpversion 2>/dev/null), incerc gcc-toolset"
    as_root dnf install -y gcc-toolset-13 >/dev/null 2>&1 \
      || as_root dnf install -y gcc-toolset-12 >/dev/null 2>&1 \
      || die "nu am putut instala un compilator mai nou (gcc-toolset-13)"
    TS="$(ls -d /opt/rh/gcc-toolset-1* 2>/dev/null | sort -r | head -1)"
    [ -n "$TS" ] || die "gcc-toolset instalat, dar nu il gasesc in /opt/rh/"
    rm -rf "$SRC/build"
    # shellcheck source=/dev/null
    source "$TS/enable"
    ok "folosesc gcc $(g++ -dumpversion) din $TS"
    build_llama || die "compilarea a esuat si cu gcc-toolset. Vezi mesajele de mai sus."
  fi
  LLAMA_BIN="$SRC/build/bin"
fi
[ -x "$LLAMA_BIN/llama-server" ] || die "nu gasesc $LLAMA_BIN/llama-server"
export LLAMA_BIN
ok "$LLAMA_BIN/llama-server"

# ---------------------------------------------------------------- 4. modele
say "4/7  Modele"
MODELS="$AGENT_HOME/models"

fetch() {  # fetch <destinatie> <url> [url-alternativ ...]
  local dest="$1"; shift
  [ -s "$dest" ] && { ok "$(basename "$dest") (exista deja)"; return 0; }
  local url
  for url in "$@"; do
    echo "    descarc: $url"
    if curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"; ok "$(basename "$dest")"; return 0
    fi
    warn "link indisponibil, incerc alternativa"
  done
  rm -f "$dest.part"
  return 1
}

# 4a. embeddings -- doar daca ai cerut cautare semantica (agent --semantic)
if [ "$USE_EMBEDDINGS" = 1 ]; then
  EMB_MODEL="$(ls -1 "$MODELS"/*bge-m3*.gguf 2>/dev/null | head -1)"
  if [ -z "$EMB_MODEL" ]; then
    fetch "$MODELS/bge-m3-Q8_0.gguf" "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf" "https://huggingface.co/lm-kit/bge-m3-gguf/resolve/main/bge-m3-Q8_0.gguf" || die "nu am putut descarca modelul de embeddings. Ia-l manual de pe huggingface (cauta: bge-m3 GGUF, fisierul Q8_0), pune-l in $MODELS/ si ruleaza din nou. Sau lasa cautarea pe cuvinte: agent --no-semantic"
    EMB_MODEL="$MODELS/bge-m3-Q8_0.gguf"
  fi
  export EMB_MODEL
  ok "embeddings: $(basename "$EMB_MODEL")"
else
  ok "embeddings: nefolosite (cautare pe cuvinte)"
fi

# 4b. LLM -- foloseste ce ai deja; descarca doar la cerere sau daca n-ai nimic
find_llm() {
  local pat found
  for pat in '*30B-A3B*' '*30b-a3b*' '*Qwen3*14B*' '*qwen*' '*'; do
    # shellcheck disable=SC2086
    found="$(ls -1S "$MODELS"/$pat.gguf /opt/models/$pat.gguf 2>/dev/null \
             | grep -vi 'bge\|embed\|e5-\|rerank' | head -1)"
    [ -n "$found" ] && { echo "$found"; return 0; }
  done
  return 1
}
LLM_MODEL="$(find_llm)" || LLM_MODEL=""

RAM_GB="$(free -g | awk '/^Mem:/{print $2}')"
if [ "$WANT_30B" = 1 ] || [ -z "$LLM_MODEL" ]; then
  if [ "${RAM_GB:-0}" -lt 24 ]; then
    warn "ai ${RAM_GB} GB RAM - sar peste modelul de 30B (are nevoie de ~24 GB)"
  else
    fetch "$MODELS/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" \
      "https://huggingface.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" \
      "https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" \
      && LLM_MODEL="$MODELS/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
  fi
fi
[ -n "$LLM_MODEL" ] || die "niciun model LLM gasit.
        Pune un fisier .gguf in $MODELS/ , sau ruleaza:
        sudo bash start.sh --model-30b"
export LLM_MODEL
ok "LLM: $(basename "$LLM_MODEL")  ($(du -h "$LLM_MODEL" | cut -f1))"
case "$LLM_MODEL" in
  *30B-A3B*|*30b-a3b*) ;;
  *) warn "pentru ~4x viteza pe CPU:  sudo bash start.sh --model-30b   (18 GB, MoE)" ;;
esac

# ---------------------------------------------------------------- 5. servere
# shellcheck source=/dev/null
source "$AGENT_HOME/config.env"
say "5/7  Pornesc serverele (CPU, $THREADS threads, RAM ${RAM_GB} GB)"
bash "$AGENT_HOME/bin/serve.sh" start \
  || die "serverele nu au pornit. Vezi:  tail -n 40 $AGENT_HOME/logs/llm.log"
# serve.sh poate schimba portul daca era ocupat de altceva -> recitim configuratia
source "$AGENT_HOME/config.env"

# ---------------------------------------------------------------- 6. documente
say "6/7  Documente"
NDOCS="$(find "$DOCS_DIR" -type f 2>/dev/null | wc -l)"
if [ "$NDOCS" -eq 0 ]; then
  cat <<TXT

    Nu am gasit niciun fisier in:  $DOCS_DIR

    Ori pui documentele acolo:

        cp -r /calea/ta/documente/*  $DOCS_DIR/

    ori imi arati direct mapa ta (o tin minte de atunci inainte):

        agent --docs /calea/ta/documente

    Citesc PDF, text, markdown, HTML, cod - practic orice fisier care are text
    in el, din toate subfolderele. Serverul ramane pornit in RAM.
TXT
  exit 0
fi
ok "$NDOCS fisiere gasite"

say "7/7  Indexare"
IDX="$AGENT_HOME/data/chunks.jsonl"
if [ "$REINGEST" = 1 ]; then
  rm -f "$IDX" "$AGENT_HOME/data/emb.npy"
fi
if [ ! -s "$IDX" ]; then
  "$PY" "$AGENT_HOME/bin/ingest.py" || die "indexarea a esuat"
elif [ -n "$(find "$DOCS_DIR" -type f -newer "$IDX" -print -quit 2>/dev/null)" ]; then
  ok "documente noi -> reindexez doar ce s-a schimbat"
  "$PY" "$AGENT_HOME/bin/ingest.py" || die "indexarea a esuat"
else
  ok "index la zi ($(grep -c . "$IDX" 2>/dev/null) fragmente)"
fi

# ---------------------------------------------------------------- gata
if [ -n "$ONCE" ]; then
  echo
  exec "$PY" "$AGENT_HOME/bin/agent.py" $SHOW --once "$ONCE"
elif [ "$RUN_AGENT" = 1 ] && [ -t 0 ]; then
  echo
  exec "$PY" "$AGENT_HOME/bin/agent.py" $SHOW
else
  say "Gata. Scrie:  agent"
fi
