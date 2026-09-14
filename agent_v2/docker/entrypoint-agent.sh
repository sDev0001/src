#!/usr/bin/env bash
# Pornirea agentului in container: asteapta serverul cu modelul, indexeaza ce e
# nou, apoi te lasa in prompt.
set -uo pipefail

mkdir -p "$DATA_DIR"

LLM_HOST="$(echo "$LLM_URL" | sed 's|.*//||; s|[:/].*||')"

code() {
  curl -s -o /dev/null -m 5 -w '%{http_code}' "$LLM_URL/health" 2>/dev/null
}

# ---------------------------------------------------------------- 1. reteaua
# Daca numele celuilalt container nu se rezolva, nu are rost sa asteptam o
# jumatate de ora: nu e o problema de incarcare, e o problema de retea.
resolves() { getent hosts "$LLM_HOST" >/dev/null 2>&1; }

if ! resolves; then
  printf '==> astept sa apara containerul cu modelul (%s)' "$LLM_HOST"
  for i in $(seq 1 60); do
    resolves && break
    [ $((i % 5)) -eq 0 ] && printf '.'
    sleep 1
  done
  echo
fi

if ! resolves; then
  cat >&2 <<TXT

! Nu gasesc containerul cu modelul: numele "$LLM_HOST" nu se rezolva.

  Asta NU inseamna ca modelul se incarca greu. Inseamna ca cele doua
  containere nu sunt pe aceeasi retea, sau cel cu modelul nu a pornit deloc.

  Verifica:
      podman ps -a
      podman logs --tail 40 rag-agent_llm_1

  Varianta care nu depinde de compose:
      ./run-plain.sh

TXT
  exit 1
fi

# ---------------------------------------------------------------- 2. modelul
c="$(code)"
if [ "$c" != "200" ]; then
  MAXW="${LLM_WAIT:-1800}"
  printf '==> containerul cu modelul e acolo, astept sa-l incarce in RAM'
  printf ' (max %d min)' $((MAXW / 60))
  LAST="$c"
  for i in $(seq 1 "$MAXW"); do
    c="$(code)"
    [ "$c" = "200" ] && break
    LAST="$c"
    [ $((i % 10)) -eq 0 ] && printf '.'
    sleep 1
  done
  echo
  if [ "$c" != "200" ]; then
    echo >&2
    if [ "$LAST" = "503" ]; then
      echo "! Modelul inca se incarca dupa $((MAXW / 60)) minute." >&2
      echo "  Daca discul e lent si modelul mare, mareste asteptarea:" >&2
      echo "      adauga in .env:   LLM_WAIT=5400" >&2
    else
      echo "! Serverul cu modelul nu raspunde (cod HTTP: $LAST)." >&2
      echo "  Cel mai probabil a picat la pornire. Vezi de ce:" >&2
      echo "      podman logs --tail 40 rag-agent_llm_1" >&2
      echo "  Cauze frecvente: numele modelului din .env nu e exact cel al" >&2
      echo "  fisierului de pe disc, sau nu e destula memorie libera." >&2
    fi
    exit 1
  fi
fi

# ---------------------------------------------------------------- 3. documente
NDOCS="$(find /docs -type f 2>/dev/null | wc -l)"
if [ "$NDOCS" -eq 0 ]; then
  cat >&2 <<'TXT'

! Mapa cu documente e goala.
  Pune fisierele in mapa legata la /docs, sau schimba DOCS_DIR in .env.

TXT
  exit 1
fi

IDX="$DATA_DIR/chunks.jsonl"
NEW=""
if [ -s "$IDX" ]; then
  NEW="$(find /docs -type f -newer "$IDX" -print -quit 2>/dev/null)"
fi
if [ ! -s "$IDX" ] || [ -n "$NEW" ]; then
  echo "==> indexez documentele din /docs ($NDOCS fisiere)"
  python3 /app/ingest.py || exit 1
else
  echo "==> index la zi ($(grep -c . "$IDX" 2>/dev/null) fragmente)"
fi

exec python3 /app/agent.py "$@"
