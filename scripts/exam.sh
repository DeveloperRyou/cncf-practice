#!/usr/bin/env bash
# Serve the killer.sh-style exam UI: pick a round, prepare the cluster, then
# solve it with the questions on the left and a browser terminal (ttyd) on
# the right. Both servers bind to 127.0.0.1 only, so they're reachable from
# this machine (and Windows via WSL localhost forwarding) but not the network.
#   ./scripts/exam.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_PORT="${WEB_PORT:-8000}"
TERM_PORT="${TERM_PORT:-7681}"

command -v ttyd >/dev/null || { echo "ttyd not found -- run ./scripts/install.sh" >&2; exit 1; }

pids=()
trap 'kill "${pids[@]}" 2>/dev/null' EXIT INT TERM

# -W: writable terminal, -O: reject websocket connections from other origins
# (so other web pages open in the browser can't drive the shell).
ttyd -i 127.0.0.1 -p "$TERM_PORT" -W -O -w "$ROOT" \
  -t fontSize=14 -t 'theme={"background":"#0d1117"}' -t titleFixed=exam \
  -- bash --rcfile "$ROOT/exam/bashrc" -i >/dev/null 2>&1 &
pids+=($!)
python3 "$ROOT/exam/server.py" --port "$WEB_PORT" --term-port "$TERM_PORT" &
pids+=($!)

sleep 1
for pid in "${pids[@]}"; do
  kill -0 "$pid" 2>/dev/null || { echo "a server failed to start (ports $WEB_PORT/$TERM_PORT in use?)" >&2; exit 1; }
done

echo "exam UI: http://localhost:$WEB_PORT/"
echo "Ctrl-C to stop"
wait
