#!/usr/bin/env bash
# Varianta FARA "docker compose" -- doar "docker run".
# Pentru servere unde pluginul compose lipseste sau docker e de fapt podman.
# Face exact acelasi lucru ca docker-compose.yml.
#
#     ./run-plain.sh                    porneste si te lasa in prompt
#     ./run-plain.sh --once "intrebare" un singur raspuns
#     ./run-plain.sh --stop             opreste serverul cu modelul
set -uo pipefail
cd "$(dirname "$0")"

# Fisierele venite de pe Windows au terminatii de linie CRLF. Pe Linux asta
# strica shebang-ul si lasa un caracter invizibil la capatul fiecarei valori din
# .env -- numele modelului devine "model.gguf" plus un caracter fantoma si nu se
# mai gaseste, desi pe ecran arata identic. Ne reparam singuri, o singura data.
CR="$(awk 'BEGIN{printf "%c", 13}')"
if LC_ALL=C grep -q "$CR" "$0" .env 2>/dev/null; then
  echo "==> repar terminatiile de linie Windows (CRLF)"
  for f in "$0" .env docker-compose.yml; do
    [ -f "$f" ] || continue
    tr -d "$CR" < "$f" > "$f.crfix" && mv "$f.crfix" "$f"
  done
  exec bash "$0" "$@"
fi

# Pe Oracle Linux "docker" e adesea podman. Folosim ce exista.
DK="${DK:-}"
if [ -z "$DK" ]; then
  if command -v docker >/dev/null 2>&1; then DK=docker
  elif command -v podman >/dev/null 2>&1; then DK=podman
  else echo "! nu gasesc nici docker, nici podman" >&2; exit 1; fi
fi
echo "==> folosesc: $DK"

IMG="${IMG:-rag-agent:latest}"
NET=rag-agent
LLM=rag-llm

# shellcheck source=/dev/null
[ -f .env ] && . ./.env

MODELS_DIR="${MODELS_DIR:-./models}"
DOCS_DIR="${DOCS_DIR:-./docs}"
THREADS="${THREADS:-8}"
CTX="${CTX:-16384}"

if [ "${1:-}" = "--stop" ]; then
  if "$DK" rm -f "$LLM" >/dev/null 2>&1; then echo "==> oprit"; else echo "==> nu rula nimic"; fi
  exit 0
fi

# ---------------------------------------------------------------- verificari
if ! "$DK" image inspect "$IMG" >/dev/null 2>&1; then
  echo "! imaginea $IMG nu e incarcata. Ruleaza intai:" >&2
  echo "    $DK load < rag-agent-image.tar.gz" >&2
  exit 1
fi

for d in "$MODELS_DIR" "$DOCS_DIR"; do
  [ -d "$d" ] || { echo "! mapa nu exista: $d   (verifica .env)" >&2; exit 1; }
done

[ -n "${LLM_MODEL_FILE:-}" ] || { echo "! LLM_MODEL_FILE lipseste din .env" >&2; exit 1; }
if [ ! -f "$MODELS_DIR/$LLM_MODEL_FILE" ]; then
  echo "! nu gasesc modelul: $MODELS_DIR/$LLM_MODEL_FILE" >&2
  echo "  ce fisiere .gguf ai acolo:" >&2
  ls -1sh "$MODELS_DIR" 2>/dev/null | sed 's/^/    /' >&2
  echo "  pune numele corect in .env, la LLM_MODEL_FILE" >&2
  exit 1
fi

NDOCS="$(find "$DOCS_DIR" -type f 2>/dev/null | wc -l)"
if [ "$NDOCS" -eq 0 ]; then
  echo "! mapa cu documente e goala: $DOCS_DIR" >&2
  echo "  pune fisierele acolo, sau schimba DOCS_DIR in .env" >&2
  exit 1
fi

mkdir -p ./data
"$DK" network inspect "$NET" >/dev/null 2>&1 || "$DK" network create "$NET" >/dev/null

# ---------------------------------------------------------------- serverul LLM
if [ "$("$DK" inspect -f '{{.State.Running}}' "$LLM" 2>/dev/null)" != "true" ]; then
  "$DK" rm -f "$LLM" >/dev/null 2>&1 || true
  echo "==> pornesc serverul cu modelul"
  echo "    model:   $LLM_MODEL_FILE"
  echo "    threads: $THREADS (CPU, fara GPU)"
  "$DK" run -d --name "$LLM" --network "$NET" --restart unless-stopped \
    -v "$MODELS_DIR:/models:ro" "$IMG" \
    llama-server -m "/models/$LLM_MODEL_FILE" \
      --host 0.0.0.0 --port 8080 \
      -c "$CTX" -t "$THREADS" -tb "$THREADS" -ngl 0 >/dev/null || {
        echo "! nu am putut porni containerul cu modelul" >&2; exit 1; }
else
  echo "==> serverul cu modelul ruleaza deja (modelul e in RAM)"
fi

# ---------------------------------------------------------------- agentul
"$DK" run --rm -it --network "$NET" \
  -v "$DOCS_DIR:/docs:ro" \
  -v "$PWD/data:/agent/data" \
  -e "LLM_URL=http://$LLM:8080" \
  -e "USE_EMBEDDINGS=${USE_EMBEDDINGS:-0}" \
  -e "DOC_MIN_SCORE=${DOC_MIN_SCORE:-0.5}" \
  -e "TOP_K=${TOP_K:-8}" \
  -e "MAX_TOKENS=${MAX_TOKENS:-1024}" \
  -e "OCR_LANGS=${OCR_LANGS:-ron+eng+rus}" \
  "$IMG" "$@"
