#!/usr/bin/env bash
# Porneste/opreste cele doua servere llama.cpp.
# Modelul se incarca O SINGURA DATA in RAM si ramane acolo.
# Totul e headless. Porturile sunt doar pe 127.0.0.1, nu sunt expuse in retea.
set -uo pipefail

source "${AGENT_HOME:-/opt/agent}/config.env"

PID_LLM="$AGENT_HOME/logs/llm.pid"
PID_EMB="$AGENT_HOME/logs/emb.pid"
PORTS_F="$DATA_DIR/ports.env"

# ---------------------------------------------------------------- helpers HTTP
# 200 = gata de lucru;  503 = trait, dar inca incarca modelul;  000 = mort
http_code() {
  local c
  c="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null)"
  case "$c" in ''|*[!0-9]*) c=000 ;; esac
  echo "$c"
}
is_up() { [ "$(http_code "$1/health")" = "200" ]; }

# ---------------------------------------------------------------- helpers port
# Ocupat = ss vede un listener, SAU reusim sa ne conectam.
# (numai testul de conectare nu ajunge: daca coada procesului e plina,
#  conexiunea e refuzata desi portul e ocupat)
port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

port_pid() {
  local p="$1" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -ltnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" \
           | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
  fi
  if [ -z "$pid" ] && command -v fuser >/dev/null 2>&1; then
    pid="$(fuser -n tcp "$p" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1)"
  fi
  # ss/fuser nu arata pid-ul proceselor altui utilizator fara root;
  # ale noastre le gasim oricum dupa linia de comanda
  if [ -z "$pid" ] && command -v pgrep >/dev/null 2>&1; then
    pid="$(pgrep -f "llama-server.*--port[= ]$p" 2>/dev/null | head -1)"
  fi
  echo "$pid"
}

port_owner() {
  local pid; pid="$(port_pid "$1")"
  if [ -n "$pid" ]; then echo "$pid $(ps -o comm= -p "$pid" 2>/dev/null)"
  else echo "? necunoscut"; fi
}

# Asteapta pana portul chiar se elibereaza (un proces omorat nu moare instant).
wait_port_free() {           # wait_port_free <port> [secunde]
  local p="$1" n="${2:-20}" i
  for i in $(seq 1 "$n"); do
    port_busy "$p" || return 0
    sleep 1
  done
  port_busy "$p" && return 1
  return 0
}

# Elibereaza portul DOAR daca il tine un llama-server (al nostru).
# 0 = portul e liber acum;  1 = il tine altcineva, nu ne atingem de el.
kill_port() {                # kill_port <port>
  local p="$1" pid cmd
  port_busy "$p" || return 0
  pid="$(port_pid "$p")"
  [ -n "$pid" ] || return 1
  cmd="$(ps -o comm= -p "$pid" 2>/dev/null)"
  case "$cmd" in
    llama-server*)
      kill "$pid" 2>/dev/null
      wait_port_free "$p" 15 && return 0
      kill -9 "$pid" 2>/dev/null
      wait_port_free "$p" 10 && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

free_port_from() {           # primul port liber incepand de la $1
  local p="$1" i
  for i in $(seq 0 20); do
    p=$((${1} + i))
    port_busy "$p" || { echo "$p"; return 0; }
  done
  echo "$1"
}

show_log() {
  echo "    ---- ultimele linii din $AGENT_HOME/logs/$1.log ----"
  tail -n 20 "$AGENT_HOME/logs/$1.log" 2>/dev/null | sed 's/^/    /'
  echo "    ----------------------------------------------------"
}

# Logul spune ca n-a putut lua portul? (apostroful difera intre versiuni)
log_bind_error() {           # log_bind_error <nume>
  grep -qi "couldn.t bind\|address already in use\|bind.*failed" \
       "$AGENT_HOME/logs/$1.log" 2>/dev/null
}

# Asteapta ca un server sa termine de citit modelul de pe disc in RAM.
# Afiseaza progresul -- altfel pare ca s-a blocat si omul da Ctrl+C degeaba.
# 0 = gata;  1 = a murit intre timp;  2 = a trecut timpul maxim.
wait_loading() {             # wait_loading <nume> <url> [secunde]
  local name="$1" url="$2" max="${3:-${LOAD_TIMEOUT:-1800}}" i=0 c rc=2
  printf '    %s: citeste modelul de pe disc (poate dura, max %d min)'          "$name" $((max / 60)) >&2
  for i in $(seq 1 "$max"); do
    c="$(http_code "$url/health")"
    if [ "$c" = "200" ]; then rc=0; break; fi
    if [ "$c" = "000" ]; then rc=1; break; fi
    [ $((i % 10)) -eq 0 ] && printf '.' >&2
    sleep 1
  done
  printf ' %d:%02d' $((i / 60)) $((i % 60)) >&2
  echo >&2
  return $rc
}

# Decide pe ce port pornim. Ecou: portul de folosit. Cod 10 = deja e unul bun.
prepare_port() {             # prepare_port <nume> <port>
  local name="$1" port="$2" url="http://127.0.0.1:$2" code i w

  code="$(http_code "$url/health")"
  if [ "$code" = "200" ]; then echo "$port"; return 10; fi

  if [ "$code" = "503" ]; then
    # Exista deja un llama-server viu pe portul asta, dar inca isi urca modelul
    # in RAM. NU pornim altul (ar fi doua modele in RAM si s-ar bate pe port):
    # asteptam sa fie gata si il refolosim asa cum e.
    echo "    $name: exista deja un server pe $port care isi incarca modelul in RAM" >&2
    wait_loading "$name" "$url"
    w=$?
    case "$w" in
      0) echo "    $name: s-a incarcat, il refolosesc (nu mai pornesc altul)" >&2
         echo "$port"; return 10 ;;
      1) echo "    $name: a murit in timpul incarcarii, pornesc altul" >&2 ;;
      *) echo "    $name: nu s-a incarcat in $((${LOAD_TIMEOUT:-1800} / 60)) minute, il inlocuiesc" >&2 ;;
    esac
  fi

  if port_busy "$port"; then
    if kill_port "$port"; then
      echo "    $name: un llama-server vechi tinea portul $port, l-am oprit" >&2
    else
      local np; np="$(free_port_from $((port + 10)))"
      echo "    $name: portul $port e ocupat de $(port_owner "$port"), trec pe $np" >&2
      port="$np"
    fi
  fi
  echo "$port"
  return 0
}

# --mlock tine modelul fix in RAM (fara swap). Cere ulimit -l mare.
mlock_flag() {
  [ "${USE_MLOCK:-1}" = "1" ] || return 0
  ulimit -l unlimited 2>/dev/null || true
  [ "$(ulimit -l 2>/dev/null)" = "unlimited" ] && echo "--mlock"
}

# Numele flagului de embeddings difera intre versiunile de llama.cpp.
# Il citim O DATA din --help si il tinem minte.
# Inainte incercam sa pornim serverul de 4 ori la rand ca sa ghicim flagul --
# fiecare incercare esuata lasa procesul agatat de port, iar urmatoarele picau
# toate cu "couldn't bind". De aici venea eroarea.
emb_flags() {
  local cache="$DATA_DIR/.emb_flags" h f=""
  if [ -f "$cache" ] && [ "$cache" -nt "$LLAMA_BIN/llama-server" ] 2>/dev/null; then
    cat "$cache"; return 0
  fi
  h="$("$LLAMA_BIN/llama-server" --help 2>&1 || true)"
  case "$h" in
    *--embeddings*) f="--embeddings" ;;
    *--embedding*)  f="--embedding"  ;;
  esac
  case "$h" in *--pooling*) f="$f --pooling cls" ;; esac
  mkdir -p "$DATA_DIR"
  printf '%s' "$f" > "$cache" 2>/dev/null || true
  printf '%s' "$f"
}

wait_up() {                  # wait_up <url> <pid>
  local url="$1" pid="$2" p="${url##*:}" i
  for i in $(seq 1 600); do
    is_up "$url" && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      # pid-ul pornit de noi poate fi doar un invelis care a iesit; daca portul
      # raspunde 503, serverul real inca isi incarca modelul -> mai asteptam
      if [ "$(http_code "$url/health")" = "503" ]; then sleep 1; continue; fi
      sleep 1; is_up "$url" && return 0
      return 1
    fi
    sleep 1
  done
  return 1
}

try_launch() {               # try_launch <nume> <url> <pidfile> <flaguri...>
  local name="$1" url="$2" pidfile="$3"; shift 3
  local p="${url##*:}"
  nohup setsid "$LLAMA_BIN/llama-server" "$@" \
    > "$AGENT_HOME/logs/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"
  if wait_up "$url" "$pid"; then
    # in pidfile punem pid-ul care chiar asculta pe port, ca "stop" sa functioneze
    local rp; rp="$(port_pid "$p")"
    [ -n "$rp" ] && echo "$rp" > "$pidfile"
    echo "    $name: gata ($url)"
    return 0
  fi

  # Curatenie obligatorie: altfel procesul ramane agatat de port si toate
  # incercarile urmatoare pica pe bind.
  kill "$pid" 2>/dev/null
  sleep 1
  kill -9 "$pid" 2>/dev/null
  rm -f "$pidfile"
  local rc=1
  log_bind_error "$name" && rc=2
  kill_port "$p" >/dev/null 2>&1
  return $rc
}

# ---------------------------------------------------------------- servere
start_emb() {
  local port; port="$(prepare_port emb "$EMB_PORT")"; local rc=$?
  EMB_PORT="$port"; EMB_URL="http://127.0.0.1:$port"
  [ $rc -eq 10 ] && { echo "==> emb: deja pornit ($EMB_URL)"; return 0; }

  echo "==> Pornesc serverul de embeddings (port $EMB_PORT, CPU)"
  local F; F="$(emb_flags)"
  if [ -z "$F" ]; then
    echo "    ! llama-server din $LLAMA_BIN nu are flag de embeddings (build prea vechi)"
    return 1
  fi
  echo "    flaguri: $F"

  local base=(-m "$EMB_MODEL" --host 127.0.0.1 --port "$EMB_PORT"
              -c "$EMB_CTX" -b "$EMB_UBATCH" -ub "$EMB_UBATCH"
              -t "${EMB_THREADS:-$THREADS}" -ngl "$NGL")
  local r
  # shellcheck disable=SC2086
  try_launch emb "$EMB_URL" "$PID_EMB" "${base[@]}" $F; r=$?
  [ $r -eq 0 ] && return 0

  if [ $r -eq 2 ]; then
    echo "    portul $EMB_PORT era inca ocupat, il eliberez si mai incerc o data"
    kill_port "$EMB_PORT" >/dev/null 2>&1
    if ! wait_port_free "$EMB_PORT" 20; then
      echo "    ! portul $EMB_PORT e tinut de: $(port_owner "$EMB_PORT")"
      show_log emb
      return 1
    fi
    # shellcheck disable=SC2086
    try_launch emb "$EMB_URL" "$PID_EMB" "${base[@]}" $F; r=$?
    [ $r -eq 0 ] && return 0
  fi

  # Unele modele nu accepta pooling explicit -> o singura varianta de rezerva.
  case "$F" in
    *--pooling*)
      local F2="${F%% --pooling*}"
      echo "    incerc fara pooling explicit"
      rm -f "$DATA_DIR/.emb_flags"
      # shellcheck disable=SC2086
      try_launch emb "$EMB_URL" "$PID_EMB" "${base[@]}" $F2; r=$?
      if [ $r -eq 0 ]; then printf '%s' "$F2" > "$DATA_DIR/.emb_flags"; return 0; fi
      ;;
  esac

  show_log emb
  return 1
}

start_llm() {
  local port; port="$(prepare_port llm "$LLM_PORT")"; local rc=$?
  LLM_PORT="$port"; LLM_URL="http://127.0.0.1:$port"
  [ $rc -eq 10 ] && { echo "==> llm: deja pornit ($LLM_URL)"; return 0; }

  echo "==> Pornesc serverul LLM (port $LLM_PORT, CPU, $THREADS threads)"
  local base=(-m "$LLM_MODEL" --host 127.0.0.1 --port "$LLM_PORT"
              -c "$CTX" -t "$THREADS" -tb "$THREADS_BATCH" -ngl "$NGL")
  local ML; ML="$(mlock_flag)"
  local v r
  for v in "$ML $EXTRA_LLM_FLAGS" "$EXTRA_LLM_FLAGS" "$ML" ""; do
    # shellcheck disable=SC2086
    try_launch llm "$LLM_URL" "$PID_LLM" "${base[@]}" $v
    r=$?
    [ $r -eq 0 ] && { [ -n "$v" ] && echo "    (flaguri extra:$v)"; return 0; }
    if [ $r -eq 2 ]; then
      echo "    portul $LLM_PORT era inca ocupat, il eliberez si mai incerc o data"
      kill_port "$LLM_PORT" >/dev/null 2>&1
      if ! wait_port_free "$LLM_PORT" 20; then
        echo "    ! portul $LLM_PORT e tinut de: $(port_owner "$LLM_PORT")"
        show_log llm
        return 1
      fi
      # shellcheck disable=SC2086
      try_launch llm "$LLM_URL" "$PID_LLM" "${base[@]}" $v; r=$?
      [ $r -eq 0 ] && return 0
    fi
    echo "    incerc cu mai putine flaguri"
  done
  show_log llm
  return 1
}

save_ports() {
  mkdir -p "$DATA_DIR"
  cat > "$PORTS_F" <<EOF
export LLM_PORT=$LLM_PORT
export EMB_PORT=$EMB_PORT
export LLM_URL="http://127.0.0.1:$LLM_PORT"
export EMB_URL="http://127.0.0.1:$EMB_PORT"
EOF
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
  save_ports
  return 0
}

stop() {
  local f p
  for f in "$PID_LLM" "$PID_EMB"; do
    [ -f "$f" ] && { kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; }
  done
  # si orice llama-server ramas pe porturile noastre
  for p in "$LLM_PORT" "$EMB_PORT"; do
    kill_port "$p" >/dev/null 2>&1
  done
  pkill -f "llama-server.*--port $LLM_PORT" 2>/dev/null
  pkill -f "llama-server.*--port $EMB_PORT" 2>/dev/null
  rm -f "$PORTS_F"
  echo "==> Oprit."
}

# Ultima solutie: opreste ORICE llama-server de pe masina si elibereaza porturile.
kill_all() {
  pkill -f llama-server 2>/dev/null
  sleep 2
  pkill -9 -f llama-server 2>/dev/null
  rm -f "$PID_LLM" "$PID_EMB" "$PORTS_F"
  echo "==> Toate procesele llama-server au fost oprite."
  local p
  for p in "$LLM_PORT" "$EMB_PORT"; do
    if port_busy "$p"; then
      echo "    atentie: portul $p e inca ocupat de: $(port_owner "$p")"
    else
      echo "    portul $p: liber"
    fi
  done
}

status() {
  local c n rest u p pair
  for pair in "llm:$LLM_URL:$LLM_PORT" "emb:$EMB_URL:$EMB_PORT"; do
    n="${pair%%:*}"; rest="${pair#*:}"; u="${rest%:*}"; p="${rest##*:}"
    c="$(http_code "$u/health")"
    case "$c" in
      200) echo "$n: UP        $u" ;;
      503) echo "$n: SE INCARCA $u" ;;
      *)   if port_busy "$p"; then
             echo "$n: DOWN, dar portul $p e ocupat de: $(port_owner "$p")"
           else echo "$n: DOWN      (port $p liber)"; fi ;;
    esac
  done
  echo
  echo "procese llama-server: $(pgrep -c -f llama-server 2>/dev/null || echo 0)"
  echo "model LLM: $LLM_MODEL"
  echo "model emb: $EMB_MODEL"
  echo "index:     $(tr -d '\n ' < "$DATA_DIR/manifest.json" 2>/dev/null || echo inexistent)"
  echo
  free -g
}

case "${1:-start}" in
  start)    start ;;
  stop)     stop ;;
  kill-all) kill_all ;;
  restart)  stop; sleep 2; start ;;
  status)   status ;;
  *) echo "folosire: $0 {start|stop|restart|status|kill-all}"; exit 1 ;;
esac
