#!/usr/bin/env bash
# ============================================================================
#  Agent RAG local -- UN SINGUR SCRIPT.
#
#     sudo ./start.sh
#
#  Face tot: instaleaza pachetele, compileaza llama.cpp daca lipseste,
#  creeaza folderele, descarca modelul de embeddings, porneste serverele,
#  indexeaza documentele si te lasa in prompt.
#  Poate fi rulat de oricate ori: sare peste ce e deja facut.
#
#  Optiuni:
#     --model-30b   descarca Qwen3-30B-A3B (18 GB, de ~4x mai rapid pe CPU)
#     --reingest    forteaza reconstruirea completa a indexului
#     --no-agent    porneste doar serverele, fara promptul interactiv
#     --stop        opreste serverele
#     --status      arata ce ruleaza
# ============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="${AGENT_HOME:-/opt/agent}"

WANT_30B=0; REINGEST=0; RUN_AGENT=1; ACTION=start
for a in "$@"; do
  case "$a" in
    --model-30b) WANT_30B=1 ;;
    --reingest)  REINGEST=1 ;;
    --no-agent)  RUN_AGENT=0 ;;
    --stop)      ACTION=stop ;;
    --status)    ACTION=status ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Optiune necunoscuta: $a"; exit 1 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m   %s\n' "$*"; }
die()  { printf '\n\033[1;31mEROARE: %s\033[0m\n' "$*" >&2; exit 1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------- stop/status
if [ "$ACTION" != start ]; then
  # shellcheck source=/dev/null
  [ -f "$AGENT_HOME/config.env" ] && source "$AGENT_HOME/config.env"
  "$AGENT_HOME/bin/serve.sh" "$ACTION"
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

# Python >= 3.7 (subprocess capture_output). OL8 vine cu 3.6 -> instalam 3.11.
PY=""
for c in python3.12 python3.11 python3.10 python3.9 python3; do
  command -v "$c" >/dev/null || continue
  if "$c" -c 'import sys; sys.exit(0 if sys.version_info>=(3,7) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
[ -n "$PY" ] || NEED="$NEED python3.11 python3.11-pip"

if [ -n "$NEED" ]; then
  warn "lipsesc:$NEED"
  if command -v dnf >/dev/null; then
    # tesseract e in EPEL pe Oracle Linux / RHEL
    if echo "$NEED" | grep -q tesseract; then
      . /etc/os-release 2>/dev/null || true
      as_root dnf install -y "oracle-epel-release-el${VERSION_ID%%.*}" 2>/dev/null \
        || as_root dnf install -y epel-release 2>/dev/null \
        || warn "nu am putut activa EPEL - OCR-ul pentru PDF scanate va lipsi"
      as_root dnf config-manager --set-enabled ol"${VERSION_ID%%.*}"_developer_EPEL 2>/dev/null || true
    fi
    # shellcheck disable=SC2086
    as_root dnf install -y $NEED || warn "unele pachete nu s-au instalat (continui)"
    as_root dnf install -y tesseract-langpack-ron tesseract-langpack-rus 2>/dev/null \
      || warn "lipsesc pachetele de limba tesseract - OCR va merge doar pe engleza"
  else
    die "nu gasesc dnf. Instaleaza manual:$NEED"
  fi
  for c in python3.12 python3.11 python3.10 python3.9 python3; do
    command -v "$c" >/dev/null || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info>=(3,7) else 1)' 2>/dev/null; then
      PY="$c"; break
    fi
  done
fi
[ -n "$PY" ] || die "nu am Python 3.7+. Incearca: dnf install python3.11"
ok "python: $PY ($($PY -V 2>&1))"
ok "pdftotext: $(command -v pdftotext || echo LIPSA)"
ok "tesseract: $(command -v tesseract || echo 'LIPSA (doar PDF scanate afectate)')"

if ! "$PY" -c 'import numpy' 2>/dev/null; then
  say "     numpy"
  as_root dnf install -y python3-numpy 2>/dev/null
  "$PY" -c 'import numpy' 2>/dev/null || "$PY" -m pip install --quiet numpy \
    || die "nu am putut instala numpy ($PY -m pip install numpy)"
fi
ok "numpy: $("$PY" -c 'import numpy;print(numpy.__version__)')"

# ---------------------------------------------------------------- 2. foldere
say "2/7  Foldere in $AGENT_HOME"
as_root mkdir -p "$AGENT_HOME"/{models,data,logs,bin} "$AGENT_HOME"/docs/{pdf,repos,md}
if [ "$(id -u)" -ne 0 ]; then as_root chown -R "$(id -u):$(id -g)" "$AGENT_HOME"; fi
cp "$SELF_DIR/config.env" "$AGENT_HOME/config.env"
cp "$SELF_DIR"/bin/*.py "$SELF_DIR"/bin/*.sh "$AGENT_HOME/bin/"
chmod +x "$AGENT_HOME"/bin/*
sed -i "1s|.*|#!$(command -v "$PY")|" "$AGENT_HOME"/bin/*.py
ok "docs/pdf  docs/repos  docs/md  models  data  logs  bin"

# ---------------------------------------------------------------- 3. llama.cpp
say "3/7  llama.cpp (build CPU, fara GPU)"
LLAMA_BIN=""
for d in "$AGENT_HOME/llama.cpp/build/bin" "$HOME/llama.cpp/build/bin" \
         "/root/llama.cpp/build/bin" "/opt/llama.cpp/build/bin" \
         "/usr/local/bin" "/usr/bin"; do
  [ -x "$d/llama-server" ] && { LLAMA_BIN="$d"; break; }
done
if [ -z "$LLAMA_BIN" ]; then
  warn "nu gasesc llama-server, il compilez (5-15 min, o singura data)"
  SRC="$AGENT_HOME/llama.cpp"
  [ -d "$SRC/.git" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC" \
    || die "nu am putut clona llama.cpp (verifica internetul)"
  cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON \
        -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    || die "cmake a esuat"
  cmake --build "$SRC/build" --target llama-server -j "$(nproc)" || die "compilarea a esuat"
  LLAMA_BIN="$SRC/build/bin"
fi
export LLAMA_BIN
ok "$LLAMA_BIN/llama-server"

# ---------------------------------------------------------------- 4. modele
say "4/7  Modele"
MODELS="$AGENT_HOME/models"

fetch() {  # fetch <fisier-destinatie> <url> [url2 ...]
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

# 4a. embeddings -- OBLIGATORIU, dar mic (~600 MB)
EMB_MODEL="$(ls -1 "$MODELS"/*bge-m3*.gguf 2>/dev/null | head -1)"
if [ -z "$EMB_MODEL" ]; then
  fetch "$MODELS/bge-m3-Q8_0.gguf" \
    "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf" \
    "https://huggingface.co/lm-kit/bge-m3-gguf/resolve/main/bge-m3-Q8_0.gguf" \
    || die "nu am putut descarca modelul de embeddings.
        Cauta pe huggingface.co 'bge-m3 GGUF', descarca fisierul Q8_0
        si pune-l in $MODELS/ , apoi ruleaza din nou ./start.sh"
  EMB_MODEL="$MODELS/bge-m3-Q8_0.gguf"
fi
export EMB_MODEL
ok "embeddings: $(basename "$EMB_MODEL")"

# 4b. LLM -- folosim ce ai deja; descarcam doar la cerere
LLM_MODEL=""
for pat in '*30B-A3B*' '*30b-a3b*' '*Qwen3*14B*' '*qwen*' '*'; do
  # shellcheck disable=SC2086
  LLM_MODEL="$(ls -1S "$MODELS"/$pat.gguf /opt/models/$pat.gguf 2>/dev/null \
               | grep -vi 'bge\|embed\|e5-\|rerank' | head -1)"
  [ -n "$LLM_MODEL" ] && break
done

RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
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
        Pune un fisier .gguf in $MODELS/ sau ruleaza:  ./start.sh --model-30b"
export LLM_MODEL
ok "LLM: $(basename "$LLM_MODEL")  ($(du -h "$LLM_MODEL" | cut -f1))"
case "$LLM_MODEL" in
  *30B-A3B*|*30b-a3b*) ;;
  *) warn "pentru ~4x viteza pe CPU: ./start.sh --model-30b  (18 GB, MoE)" ;;
esac

# ---------------------------------------------------------------- 5. servere
# shellcheck source=/dev/null
source "$AGENT_HOME/config.env"
say "5/7  Pornesc serverele (CPU, $THREADS threads, RAM ${RAM_GB} GB)"
"$AGENT_HOME/bin/serve.sh" start || die "serverele nu au pornit. Vezi $AGENT_HOME/logs/"

# ---------------------------------------------------------------- 6. documente
say "6/7  Documente"
NDOCS=$(find "$AGENT_HOME/docs" -type f \
        \( -name '*.pdf' -o -name '*.md' -o -name '*.txt' -o -name '*.html' \
           -o -name '*.rst' -o -name '*.py' -o -name '*.yaml' \) 2>/dev/null | wc -l)
if [ "$NDOCS" -eq 0 ]; then
  cat <<TXT

    Nu ai inca niciun document. Pune-le si ruleaza din nou ./start.sh :

        cp /calea/ta/*.pdf            $AGENT_HOME/docs/pdf/
        cd $AGENT_HOME/docs/repos && git clone <url-documentatie>
        cp notite.md                  $AGENT_HOME/docs/md/

    Serverele raman pornite. Oprire:  ./start.sh --stop
TXT
  exit 0
fi
ok "$NDOCS fisiere gasite"

say "7/7  Indexare"
[ "$REINGEST" = 1 ] && rm -f "$AGENT_HOME/data/chunks.jsonl" "$AGENT_HOME/data/emb.npy"
"$AGENT_HOME/bin/ingest.py" || die "indexarea a esuat"

# ---------------------------------------------------------------- gata
if [ "$RUN_AGENT" = 1 ] && [ -t 0 ]; then
  echo
  exec "$AGENT_HOME/bin/agent.py"
else
  say "Gata. Porneste agentul cu:  $AGENT_HOME/bin/agent.py"
fi
