#!/usr/bin/env bash
# Reconstruieste agent-bundle.sh din fisierele curente (start.sh, config.env, bin/).
# Ruleaza-l dupa ORICE modificare, apoi copiaza doar agent-bundle.sh pe server.
#
#     bash make-bundle.sh
#
# Pastreaza neschimbat antetul si subsolul bundle-ului existent; inlocuieste
# doar arhiva din mijloc.
set -euo pipefail

cd "$(dirname "$0")"
B=agent-bundle.sh
[ -f "$B" ] || { echo "nu gasesc $B in $(pwd)" >&2; exit 1; }

FILES="start.sh config.env bin/serve.sh bin/ingest.py bin/agent.py"
for f in $FILES; do
  [ -s "$f" ] || { echo "lipseste $f" >&2; exit 1; }
done

# Verificare de sanatate inainte de impachetare
bash -n start.sh
bash -n bin/serve.sh
python -c "import ast,io,sys
for f in ['bin/ingest.py','bin/agent.py']:
    ast.parse(io.open(f,encoding='utf-8').read())
" 2>/dev/null || python3 -c "import ast,io
for f in ['bin/ingest.py','bin/agent.py']:
    ast.parse(io.open(f,encoding='utf-8').read())
"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# CRLF-ul de pe Windows strica shebang-ul pe Linux -> il scoatem in copie
mkdir -p "$TMP/src/bin"
for f in $FILES; do
  sed 's/\r$//' "$f" > "$TMP/src/$f"
done

# tar reproductibil (fara timestamp/owner variabil)
tar --format=ustar --numeric-owner --owner=0 --group=0 --mtime='2020-01-01' \
    -czf "$TMP/payload.tgz" -C "$TMP/src" $FILES

awk '/^base64 -d <</{print; exit} {print}'  "$B" > "$TMP/head"
awk 'f{print} /^__B64__$/{f=1}'            "$B" > "$TMP/tail"

{
  cat "$TMP/head"
  base64 -w 76 "$TMP/payload.tgz" 2>/dev/null || base64 "$TMP/payload.tgz"
  echo "__B64__"
  cat "$TMP/tail"
} > "$TMP/new"

mv "$TMP/new" "$B"
chmod +x "$B" 2>/dev/null || true
echo "ok  $B reconstruit ($(wc -c < "$B") octeti, $(echo $FILES | wc -w) fisiere)"

# Proba: se despacheteaza corect?
AGENT_SRC="$TMP/check" AGENT_EXTRACT_ONLY=1 bash "$B" >/dev/null
for f in $FILES; do
  [ -s "$TMP/check/$f" ] || { echo "PROBA A ESUAT: lipseste $f" >&2; exit 1; }
done
echo "ok  proba de despachetare a trecut"
