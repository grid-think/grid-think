#!/usr/bin/env bash
# Real RPC grid on loopback, no QEMU needed.
# Usage: nix develop --command bash scripts/test-loopback.sh
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${MODEL:-models/tiny-qwen2.5-0.5b-q4_k_m.gguf}"
P1=50052; P2=50053

if [ ! -f "$MODEL" ]; then
  echo "==> downloading tiny test model (~400MB) to $MODEL"
  mkdir -p models
  curl -L -o "$MODEL" \
    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
fi

echo "==> 1. fake fleet heartbeats"
mkdir -p heartbeats
python3 grid/agent.py --once --node-id coord-loopback --ip 127.0.0.1 --port $P1 \
  --role coordinator --wired > heartbeats/coord.json
python3 grid/agent.py --once --node-id worker-loopback-1 --ip 127.0.0.1 --port $P2 \
  --role worker --wired > heartbeats/worker1.json
cat heartbeats/worker1.json | head -n 12

echo "==> 2. planner output"
python3 grid/control.py --fleet "heartbeats/coord.json" "heartbeats/worker1.json" \
  --model "$MODEL" --model-size-mib 800 || true
echo "--- and the honest 70B check:"
python3 grid/control.py --fleet "heartbeats/coord.json" "heartbeats/worker1.json" \
  --model "$MODEL" --model-preset llama3.3-70b-q4 || true

echo "==> 3. start 2x rpc-server in background"
pkill -f "rpc-server.*$P1" 2>/dev/null || true
pkill -f "rpc-server.*$P2" 2>/dev/null || true
rpc-server -H 127.0.0.1 -p $P1 -c > /tmp/rpc-$P1.log 2>&1 &
RPC1=$!
rpc-server -H 127.0.0.1 -p $P2 -c > /tmp/rpc-$P2.log 2>&1 &
RPC2=$!
trap "kill $RPC1 $RPC2 2>/dev/null || true" EXIT
sleep 2
echo "workers up (logs: /tmp/rpc-$P1.log /tmp/rpc-$P2.log)"
cat /tmp/rpc-$P1.log | head -n 5; cat /tmp/rpc-$P2.log | head -n 5

echo "==> 4. single-node baseline vs 2-node RPC (tiny model, pp512+tg32)"
echo "--- local only:"
llama-bench -m "$MODEL" -ngl 99 -p 512 -n 32 2>&1 | tail -n 8
echo "--- distributed (gen runs slower on loopback, that is the RPC tax):"
llama-bench -m "$MODEL" -ngl 99 --rpc 127.0.0.1:$P1,127.0.0.1:$P2 \
  --tensor-split 3,2 -p 512 -n 32 2>&1 | tail -n 12

echo "==> 5. serve + curl (OpenAI-compat through coordinator)"
llama-server -m "$MODEL" -ngl 99 --rpc 127.0.0.1:$P1,127.0.0.1:$P2 \
  --tensor-split 3,2 --host 127.0.0.1 --port 8080 > /tmp/llama-server.log 2>&1 &
SRV=$!
trap "kill $RPC1 $RPC2 $SRV 2>/dev/null || true" EXIT
for i in $(seq 1 30); do curl -sf http://127.0.0.1:8080/health >/dev/null && break; sleep 1; done
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say: grid alive"}],"max_tokens":20}' | head -c 600; echo
kill $SRV 2>/dev/null || true

echo "OK loopback grid works. Next: scripts/qemu-fleet.sh for true multi-machine."
