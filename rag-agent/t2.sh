set -uo pipefail
warn() { printf '    !   %s\n' "$*"; }
ok()   { printf '    ok  %s\n' "$*"; }
port_taken() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}
for p in 8099 8098; do
  for i in $(seq 1 3); do port_taken "$p" || break; sleep 1; done
  if port_taken "$p"; then warn "portul $p e ocupat de altceva - agentul va folosi automat alt port"
  else ok "portul $p: liber"; fi
done
