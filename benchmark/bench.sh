#!/usr/bin/env bash
#
# Compares tup and glisten running the minimal HTTP server.
#
# Usage: ./bench.sh [workload...]     (default: all)
#
#   keepalive  h2load with CONNECTIONS connections. Each sends one request at a
#              time over a connection it keeps open
#   many       the same with MANY connections
#   split      keepalive but every response is written in two sends
#   churn      wrk against a server that closes after every response
#   uploads    STREAMS connections each send MIB MiB that the server discards
#   memory     IDLE idle connections: server memory growth per connection
#
# uploads and memory also run tup with buffer_size(BUFFER).
#
# Environment: REPEATS=3 DURATION=10 CONNECTIONS=50 MANY=1000 STREAMS=8
#              MIB=1024 IDLE=10000 BUFFER=131072 POOL=10 PORT=4000

set -u
cd "$(dirname "$0")"

WORKLOADS="${*:-keepalive many split churn uploads memory}"
REPEATS="${REPEATS:-3}"
DURATION="${DURATION:-10}"
CONNECTIONS="${CONNECTIONS:-50}"
MANY="${MANY:-1000}"
STREAMS="${STREAMS:-8}"
MIB="${MIB:-1024}"
IDLE="${IDLE:-10000}"
BUFFER="${BUFFER:-131072}"
POOL="${POOL:-10}"
PORT="${PORT:-4000}"
URL="http://127.0.0.1:$PORT/"

fail() { echo "$*" >&2; exit 1; }

for workload in $WORKLOADS; do
  case "$workload" in
    keepalive | many | split | churn | uploads | memory) ;;
    *) fail "unknown workload: $workload" ;;
  esac
done
for tool in gleam erl escript h2load wrk taskset dd; do
  command -v "$tool" > /dev/null || fail "missing tool: $tool"
done

# The server gets the first half of the cores and the load the second half so 
# the two would never compete for a CPU.
CORES="$(nproc)"
[ "$CORES" -ge 2 ] || fail "needs at least 2 cores"
SERVER_CPUS="0-$((CORES / 2 - 1))"
LOAD_CPUS="$((CORES / 2))-$((CORES - 1))"
load() { taskset -c "$LOAD_CPUS" "$@"; }

port_open() { (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null; }
port_open && fail "port $PORT is already in use"

# The server and the idle client each need a descriptor per connection.
if [ "$(ulimit -n)" -lt $((IDLE + 1024)) ]; then
  ulimit -n $((IDLE + 1024)) 2> /dev/null || fail "could not raise the open file limit to $((IDLE + 1024))"
fi

gleam build --no-print-progress || exit 1

# start <tup|tup+buffer|glisten> <mode>
# A fresh VM on the server cores.
start() {
  local buffer=0
  [ "$1" = "tup+buffer" ] && buffer="$BUFFER"
  BENCH_MODE="$2" BENCH_PORT="$PORT" BENCH_POOL="$POOL" BENCH_BUFFER="$buffer" \
    taskset -c "$SERVER_CPUS" erl -noshell -pa build/dev/erlang/*/ebin \
    -eval "'benchmark@@main':run(${1%+buffer}_server)" > build/server.log 2>&1 &
  SERVER=$!
  until port_open; do
    kill -0 "$SERVER" 2> /dev/null || fail "the server stopped, see build/server.log"
    sleep 0.1
  done
}

stop() {
  for pid in ${HOLDER:-} ${SERVER:-}; do
    kill -KILL "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
  done
  HOLDER=""
  SERVER=""
}
trap stop EXIT
trap 'exit 1' INT TERM

# h2load <connections>
run_h2load() {
  local out
  out=$(load h2load --h1 -c "$1" -t 4 -D "$DURATION" --warm-up-time 3 "$URL" 2>&1)
  printf '%10s req/s   p50 %-7s p99 %-7s failed %s\n' \
    "$(grep -oP 'finished in [0-9.]+s, \K[0-9.]+' <<< "$out")" \
    "$(awk '/^request +:/ { print $5 }' <<< "$out")" \
    "$(awk '/^request +:/ { print $7 }' <<< "$out")" \
    "$(grep -oP '[0-9]+(?= failed)' <<< "$out" | head -1)"
}

run_wrk() {
  local out
  load wrk -t 4 -c "$CONNECTIONS" -d 3s "$URL" > /dev/null 2>&1 # warmup
  out=$(load wrk -t 4 -c "$CONNECTIONS" -d "${DURATION}s" --latency "$URL" 2>&1)
  printf '%10s conn/s  p50 %-7s p99 %-7s errors %s\n' \
    "$(grep -oP 'Requests/sec:\s+\K[0-9.]+' <<< "$out")" \
    "$(awk '/^ +50%/ { print $2 }' <<< "$out")" \
    "$(awk '/^ +99%/ { print $2 }' <<< "$out")" \
    "$(grep -oP 'Socket errors: \K.*' <<< "$out" || echo 0)"
}

run_uploads() {
  local started milliseconds streams=()
  started=$(date +%s%N)
  for _stream in $(seq "$STREAMS"); do
    load bash -c "dd if=/dev/zero bs=1M count=$MIB 2> /dev/null > /dev/tcp/127.0.0.1/$PORT" &
    streams+=($!)
  done
  wait "${streams[@]}"
  milliseconds=$((($(date +%s%N) - started) / 1000000))
  printf '%10s MiB/s   %s MiB in %s ms\n' \
    $((STREAMS * MIB * 1000 / milliseconds)) $((STREAMS * MIB)) "$milliseconds"
}

rss_kib() { awk '/^VmRSS/ { print $2 }' "/proc/$SERVER/status"; }

run_memory() {
  local before after held
  sleep 1
  before=$(rss_kib)
  coproc HOLD { exec taskset -c "$LOAD_CPUS" escript hold_connections.erl "$PORT" "$IDLE"; }
  HOLDER="$HOLD_PID"
  read -r held <&"${HOLD[0]}"
  [ "$held" = "held" ] || fail "could not open $IDLE connections"
  sleep 2
  after=$(rss_kib)
  printf '%10s bytes per idle connection\n' $(((after - before) * 1024 / IDLE))
}

echo "server on cpus $SERVER_CPUS, load on $LOAD_CPUS, $POOL acceptors, $REPEATS repeats"
for workload in $WORKLOADS; do
  case "$workload" in
    uploads | memory) servers="tup tup+buffer glisten" ;;
    *) servers="tup glisten" ;;
  esac
  for repeat in $(seq "$REPEATS"); do
    for server in $servers; do
      printf '%-9s  %-10s  %s  ' "$workload" "$server" "$repeat"
      case "$workload" in
        keepalive) start "$server" keepalive && run_h2load "$CONNECTIONS" ;;
        many) start "$server" keepalive && run_h2load "$MANY" ;;
        split) start "$server" split && run_h2load "$CONNECTIONS" ;;
        churn) start "$server" close && run_wrk ;;
        uploads) start "$server" sink && run_uploads ;;
        memory) start "$server" keepalive && run_memory ;;
      esac
      stop
    done
  done
done
