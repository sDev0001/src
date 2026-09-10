#!/usr/bin/env bash
# Porneste/opreste cele doua servere llama.cpp.
# Modelul se incarca O SINGURA DATA in RAM si ramane acolo.
# Totul e headless: niciun program de aici nu are nevoie de interfata grafica.
# Porturile sunt doar pe 127.0.0.1 -- nu sunt expuse in retea.
set -uo pipefail

source "${AGENT_HOME:-/opt/agent}/config.env"

PID_LLM="$AGENT_HOME/logs/llm.pid"
PID_EMB="$AGENT_HOME/logs/emb.pid"

is_up() { curl -sf "$1/health" >/dev/null 2>&1; }

# Asteapta pornirea, dar renunta imediat daca procesul a murit.
wait_up() {
  local url="$1" name="$2" pid="$3" i
  for i in $(seq 1 300); do
    is_up "$url" && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      sleep 1; is_up "$url" && return 0
      return 1
    fi
    sleep 1
  done
  return 1
}

show_log() {
  echo "    ---- ultimele linii din $AGENT_HOME/logs/$1.log ----"
  tail -n 20 "$AGENT_HOME/logs/$1.log" 2>/dev/null | sed 's/^/    /'
  echo "    -------------------------------------------------"
}

# --mlock tine modelul fix in RAM (fara swap). Cere ulimit -l mare.
mlock_flag() {
  [ "${USE_MLOCK:-1}" = "1" ] || return 0
  ulimit -l unlimited 2>/dev/null || true
  [ "$(ulimit -l 2>/dev/null)" = "unlimited" ] && echo "--mlock"
}

# Lanseaza llama-server cu un set de flaguri; intoarce 0 daca a pornit.
try_launch() {   # try_launch <nume> <url> <pidfile> <flaguri...>
  local name="$1" url="$2" pidfile="$3"; shift 3
  # shellcheck disable=SC2086
  nohup setsid "$LLAMA_BIN/llama-server" "$@" \
    > "$AGENT_HOME/logs/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"
  if wait_up "$url" "$name" "$pid"; then
    echo "    $name: gata ($url)"
    return 0
  fi
  kill "$pid" 2>/dev/null
  rm -f "$pidfile"
  return 1
}

start_emb() {
  is_up "$EMB_URL" && { echo "==> emb: deja pornit"; return 0; }
  echo "==> Pornesc serverul de embeddings (port $EMB_PORT, CPU)"
  local base=(-m "$EMB_MODEL" --host 127.0.0.1 --port "$EMB_PORT"
              -c "$EMB_CTX" -b "$EMB_UBATCH" -ub "$EMB_UBATCH"
              -t "$THREADS" -ngl "$NGL")
  # Numele flagului difera intre versiunile de llama.cpp -> incercam pe rand.
  local v
  for v in "--embeddings --pooling cls" "--embeddings" \
           "--embedding --pooling cls" "--embedding"; do
    # shellcheck disable=SC2086
    if try_launch emb "$EMB_URL" "$PID_EMB" "${base[@]}" $v; then
      echo "    (flaguri: $v)"
      return 0
    fi
    echo "    varianta '$v' nu a mers, incerc alta"
  done
  show_log emb
  return 1
}

start_llm() {
  is_up "$LLM_URL" && { echo "==> llm: deja pornit"; return 0; }
  echo "==> Pornesc serverul LLM (port $LLM_PORT, CPU, $THREADS threads)"
  local base=(-m "$LLM_MODEL" --host 127.0.0.1 --port "$LLM_PORT"
              -c "$CTX" -t "$THREADS" -tb "$THREADS_BATCH" -ngl "$NGL")
  local ML; ML="$(mlock_flag)"
  local v
  for v in "$ML $EXTRA_LLM_FLAGS" "$EXTRA_LLM_FLAGS" "$ML" ""; do
    # shellcheck disable=SC2086
    if try_launch llm "$LLM_URL" "$PID_LLM" "${base[@]}" $v; then
      [ -n "$v" ] && echo "    (flaguri extra:$v)"
      return 0
    fi
    echo "    fara flagurile'$v', incerc mai simplu"
  done
  show_log llm
  return 1
}

start() {
  mkdir -p "$AGENT_HOME/logs"
  local bad=0
  [ -x "$LLAMA_BIN/llama-server" ] || { echo "! lipseste $LLAMA_BIN/llama-server"; bad=1; }
  [ -f "$LLM_MODEL" ] || { echo "! lipseste modelul: $LLM_MODEL"; bad=1; }
  [ -f "$EMB_MODEL" ] || { echo "! lipseste modelul: $EMB_MODEL"; bad=1; }
  [ "$bad" = 0 ] || return 1

  start_emb || { echo "! serverul de embeddings NU a pornit"; return 1; }
  start_llm || { echo "! serverul LLM NU a pornit"; return 1; }
  return 0
}

stop() {
  local f
  for f in "$PID_LLM" "$PID_EMB"; do
    [ -f "$f" ] && { kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }
  done
  pkill -f "llama-server.*--port $LLM_PORT" 2>/dev/null
  pkill -f "llama-server.*--port $EMB_PORT" 2>/dev/null
  echo "==> Oprit."
}

status() {
  if is_up "$LLM_URL"; then echo "llm: UP   $LLM_URL"; else echo "llm: DOWN"; fi
  if is_up "$EMB_URL"; then echo "emb: UP   $EMB_URL"; else echo "emb: DOWN"; fi
  echo
  echo "model LLM: $LLM_MODEL"
  echo "model emb: $EMB_MODEL"
  echo "index:     $(cat "$DATA_DIR/manifest.json" 2>/dev/null | tr -d '\n ' || echo 'inexistent')"
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
