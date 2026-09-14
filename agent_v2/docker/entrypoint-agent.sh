#!/usr/bin/env bash
# Pornirea agentului in container: asteapta serverul LLM, indexeaza ce e nou,
# apoi te lasa in prompt. Nimic de configurat, nimic de pornit manual.
set -uo pipefail

mkdir -p "$DATA_DIR"

# ---------------------------------------------------------------- server LLM
# docker compose ne porneste doar dupa ce serverul e "healthy", dar daca cineva
# ruleaza containerul de unul singur, asteptam si aici.
health() {
  curl -s -o /dev/null -m 3 -w '%{http_code}' "$LLM_URL/health" 2>/dev/null
}

if [ "$(health)" != "200" ]; then
  printf '==> astept serverul LLM (%s), isi incarca modelul in RAM' "$LLM_URL"
  for i in $(seq 1 1800); do
    [ "$(health)" = "200" ] && break
    [ $((i % 10)) -eq 0 ] && printf '.'
    sleep 1
  done
  echo
  if [ "$(health)" != "200" ]; then
    echo "! serverul LLM nu a pornit. Vezi:  docker compose logs llm" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- documente
NDOCS="$(find /docs -type f 2>/dev/null | wc -l)"
if [ "$NDOCS" -eq 0 ]; then
  cat <<'TXT'

    Mapa cu documente e goala.

    Pune-le in mapa pe care ai legat-o la /docs si porneste din nou.
    Se configureaza in fisierul .env, randul DOCS_DIR.

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
