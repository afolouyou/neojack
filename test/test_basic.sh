#!/bin/bash
set -e

echo "=== njackd test suite ==="

# Start server
./zig-out/bin/njackd -d dummy -v > /tmp/njackd_test.log 2>&1 &
JPID=$!
sleep 2

cleanup() { kill $JPID 2>/dev/null; wait $JPID 2>/dev/null; }
trap cleanup EXIT

# Test 1: jack_lsp lists ports
echo -n "Test 1: jack_lsp ... "
PORTS=$(timeout 2 jack_lsp 2>/dev/null)
echo "$PORTS" | grep -q "system:capture_1" && echo "PASS" || { echo "FAIL"; exit 1; }

# Test 2: jack_lsp shows MIDI ports
echo -n "Test 2: MIDI ports ... "
echo "$PORTS" | grep -q "system:midi_in" && echo "PASS" || { echo "FAIL"; exit 1; }

# Test 3: jack_connect (timeout esperado)
echo -n "Test 3: jack_connect ... "
timeout 2 jack_connect system:capture_1 system:playback_1 2>/dev/null
timeout 2 jack_lsp -c 2>/dev/null | grep -q "capture_1.*playback_1" && echo "PASS" || { echo "FAIL"; exit 1; }

# Test 4: jack_disconnect (timeout esperado)
echo -n "Test 4: jack_disconnect ... "
timeout 2 jack_disconnect system:capture_1 system:playback_1 2>/dev/null
timeout 2 jack_lsp -c 2>/dev/null | grep -q "capture_1.*playback_1" && { echo "FAIL (still connected)"; exit 1; } || echo "PASS"

echo "=== All tests passed ==="
