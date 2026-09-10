#!/usr/bin/env bash
# Porneste/opreste cele doua servere llama.cpp.
# Modelul se incarca O SINGURA DATA in RAM si ramane acolo.
# Totul e headless: niciun program de aici nu are nevoie de interfata grafica.
set -uo pipefail

source "${AGENT_HOME:-/opt/agent}/config.env"

PID_LLM="$AGENT_HOME/logs/llm.pid"
PID_EMB="$AGENT_HOME/logs/emb.pid"

is_up() { curl -sf "$1/health" >/dev/null 2>&1; }

check() {
  local ok=0
  [ -x "$LLAMA_BIN/llama-server" ] || {
    echo "! Lipseste $LLAMA_BIN/llama-server"
    echo "  Verifica LLAMA_BIN din config.env sau recompileaza llama.cpp."; ok=1; }
  [ -f "$LLM_MODEL" ] || { echo "! Lipseste modelul: $LLM_MODEL"; ok=1; }
  [ -f "$EMB_MODEL" ] || { echo "! Lipseste modelul: $EMB_MODEL"; ok=1; }
  return $ok
}

# --mlock tine modelul fix in RAM (fara swap). Are nevoie de ulimit -l mare.
mlock_flag() {
  [ "${USE_MLOCK:-1}" = "1" ] || return 0
  ulimit -l unlimited 2>/dev/null || true
  local lim; lim=$(ulimit -l 2>/dev/null)
  if [ "$lim" = "unlimited" ]; then
    echo "--mlock"
  else
    echo "" >&2
  fi
}

wait_up() {
  local url="$1" name="$2" i
  for i in $(seq 1 300); do
    is_up "$url" && { echo "    $name: gata ($url)"; return 0; }
    # daca procesul a murit, nu mai astepta 5 minute degeaba
    if ! pgrep -f "llama-server.*--port ${url##*:}" >/dev/null 2>&1; then
      sleep 2
      is_up "$url" && { echo "    $name: gata ($url)"; return 0; }
      echo "    $name: procesul a murit. Ultimele linii din log:"
      tail -n 15 "$AGENT_HOME/logs/$name.log" | sed 's/^/      /'
      return 1
    fi
    sleep 1
  done
  echo "    $name: timeout. Vezi $AGENT_HOME/logs/$name.log"; return 1
}

start() {
  mkdir -p "$AGENT_HOME/logs"
  check || return 1
  local ML; ML=$(mlock_flag)

  if is_up "$EMB_URL"; then
    echo "==> emb: deja pornit"
  else
    echo "==> Pornesc serverul de embeddings (port $EMB_PORT, CPU)"
    nohup setsid "$LLAMA_BIN/llama-server" \
      -m "$EMB_MODEL" \
      --host 127.0.0.1 --port "$EMB_PORT" \
      --embeddings --pooling cls \
      -c "$EMB_CTX" -b "$EMB_UBATCH" -ub "$EMB_UBATCH" \
      -t "$THREADS" -ngl "$NGL" \
      > "$AGENT_HOME/logs/emb.log" 2>&1 &
    echo $! > "$PID_EMB"
    wait_up "$EMB_URL" emb || return 1
  fi

  if is_up "$LLM_URL"; then
    echo "==> llm: deja pornit"
  else
    echo "==> Pornesc serverul LLM (port $LLM_PORT, CPU, $THREADS threads)"
    # shellcheck disable=SC2086
    nohup setsid "$LLAMA_BIN/llama-server" \
      -m "$LLM_MODEL" \
      --host 127.0.0.1 --port "$LLM_PORT" \
      -c "$CTX" \
      -t "$THREADS" -tb "$THREADS_BATCH" \
      -ngl "$NGL" \
      $ML $EXTRA_LLM_FLAGS \
      > "$AGENT_HOME/logs/llm.log" 2>&1 &
    echo $! > "$PID_LLM"
    wait_up "$LLM_URL" llm || return 1
  fi

  echo
  echo "==> Totul e sus. Ruleaza:  $AGENT_HOME/bin/agent.py"
  echo "    RAM folosita acum:"
  free -g | sed 's/^/      /'
}

stop() {
  for f in "$PID_LLM" "$PID_EMB"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null && rm -f "$f"
  done
  pkill -f "llama-server.*--port $LLM_PORT" 2>/dev/null
  pkill -f "llama-server.*--port $EMB_PORT" 2>/dev/null
  echo "==> Oprit."
}

status() {
  is_up "$LLM_URL" && echo "llm: UP   $LLM_URL" || echo "llm: DOWN"
  is_up "$EMB_URL" && echo "emb: UP   $EMB_URL" || echo "emb: DOWN"
  echo
  free -g
}

case "${1:-start}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 2; start ;;
  status)  status ;;
  *) echo "folosire: $0 {start|stop|restart|status}"; exit 1 ;;
esac
