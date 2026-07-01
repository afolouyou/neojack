#!/bin/bash
set -e

echo "=== njackd benchmark ==="

./zig-out/bin/njackd -d dummy -v > /tmp/njackd_bench.log 2>&1 &
JPID=$!
sleep 2

cleanup() { kill $JPID 2>/dev/null; wait $JPID 2>/dev/null; }
trap cleanup EXIT

echo "--- CPU usage ---"
ps -p $JPID -o %cpu,rss,etime --no-headers

echo "--- Port count ---"
timeout 2 jack_lsp 2>/dev/null | wc -l | xargs echo "ports:"

echo "--- Round-trip latency (jack_iodelay) ---"
if command -v jack_iodelay &>/dev/null; then
    timeout 5 jack_iodelay 2>/dev/null || echo "(requires audio device)"
else
    echo "(jack_iodelay not installed)"
fi

echo "--- Done ---"
