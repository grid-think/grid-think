#!/usr/bin/env bash
# Boot real VMs as fleet nodes: up [N] | status | ssh <i> | collect | serve | stop-workers | down | clean
set -euo pipefail
cd "$(dirname "$0")/.."

IMGDIR="$PWD/.qemu-images"
BASE_IMG="$IMGDIR/noble-server-cloudimg-arm64.img"
BASE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
KEY="$IMGDIR/grid-key"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

N_DEFAULT=3
SSH_BASE=2222
RPC_BASE=50052

mem_for() {
  if [ "$1" -lt 2 ]; then echo 8192; else echo 4096; fi
}

firmware_path() {
  local fw
  fw=$(ls -t /nix/store/*qemu*/share/qemu/edk2-aarch64-code.fd 2>/dev/null | head -n 1)
  if [ -n "${fw:-}" ]; then echo "$fw"; return 0; fi
  local qbindir
  qbindir=$(dirname "$(command -v qemu-system-aarch64)")
  for c in "$qbindir/../share/qemu/edk2-aarch64-code.fd" "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"; do
    if [ -f "$c" ]; then echo "$c"; return 0; fi
  done
  echo "ERROR: edk2-aarch64-code.fd not found" >&2
  return 1
}

ensure_key() {
  mkdir -p "$IMGDIR"
  if [ ! -f "$KEY" ]; then
    echo "==> generating ssh key $KEY"
    ssh-keygen -t ed25519 -N "" -f "$KEY" -C "grid-think-qemu" >/dev/null
  fi
}

ensure_base() {
  mkdir -p "$IMGDIR"
  if [ -f "$BASE_IMG" ]; then echo "==> base image cached ($BASE_IMG)"; return 0; fi
  echo "==> downloading Ubuntu noble arm64 cloud image (~590MB, once, resumable)"
  curl -L -C - --progress-bar -o "$BASE_IMG.tmp" "$BASE_URL"
  mv "$BASE_IMG.tmp" "$BASE_IMG"
}

gen_seed_iso() { # $1 = index
  local i="$1" sdir="$IMGDIR/seed-$i" iso="$IMGDIR/seed-$i.iso"
  mkdir -p "$sdir"
  cat > "$sdir/user-data" <<EOF
#cloud-config
hostname: node-$i
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
packages: [python3, iperf3]
runcmd: [touch /var/tmp/grid-ready]
EOF
  printf 'instance-id: node-%s\nlocal-hostname: node-%s\n' "$i" "$i" > "$sdir/meta-data"
  rm -f "$iso"
  if command -v mkisofs >/dev/null 2>&1; then
    mkisofs -output "$iso" -volid cidata -joliet -rock "$sdir/user-data" "$sdir/meta-data" >/dev/null
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$iso" -volid cidata -joliet -rock "$sdir/user-data" "$sdir/meta-data" >/dev/null
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#cdrtools --command mkisofs -output "$iso" -volid cidata -joliet -rock "$sdir/user-data" "$sdir/meta-data" >/dev/null
  else
    hdiutil makehybrid -iso -joliet -iso-volume-name cidata -o "$iso" "$sdir" >/dev/null
  fi
  echo "$iso"
}

vm_running() { # $1 = index -> 0/1
  local pidf="/tmp/qemu-node-$1.pid"
  [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null
}

wait_ssh() { # $1 = index
  local i="$1" port=$((SSH_BASE + i))
  echo "==> waiting ssh 127.0.0.1:$port (first boot takes a minute)"
  for _ in $(seq 1 90); do
    if ssh -i "$KEY" $SSH_OPTS -p "$port" ubuntu@127.0.0.1 true 2>/dev/null; then
      echo "    vm $i ssh ready"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: vm $i ssh never came up; see /tmp/qemu-node-$i.log" >&2
  return 1
}

cmd_up() {
  local n="${1:-$N_DEFAULT}"
  ensure_key; ensure_base
  local fw; fw=$(firmware_path)
  echo "==> firmware: $fw"
  for i in $(seq 0 $((n - 1))); do
    local mem ssh_port rpc_port ovf iso
    mem=$(mem_for "$i"); ssh_port=$((SSH_BASE + i)); rpc_port=$((RPC_BASE + i))
    ovf="$IMGDIR/node-$i.qcow2"
    [ -f "$ovf" ] || { echo "==> creating overlay $ovf (${mem}MB max)"; qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$ovf" 20G >/dev/null; }
    iso=$(gen_seed_iso "$i")
    if vm_running "$i"; then echo "==> vm $i already running (pid $(cat /tmp/qemu-node-$i.pid))"; continue; fi
    echo "==> booting vm $i (mem ${mem}MB, ssh $ssh_port, rpc $rpc_port)"
    # shellcheck disable=SC2086
    nohup qemu-system-aarch64 -M virt -accel hvf -cpu host \
      -smp 4 -m "$mem" -nographic \
      -bios "$fw" \
      -drive "file=$ovf,format=qcow2,if=virtio" \
      -cdrom "$iso" \
      -nic "user,model=virtio-net-pci,hostfwd=tcp::$ssh_port-:22,hostfwd=tcp::$rpc_port-:50052" \
      > "/tmp/qemu-node-$i.log" 2>&1 &
    echo $! > "/tmp/qemu-node-$i.pid"
  done
  for i in $(seq 0 $((n - 1))); do wait_ssh "$i"; done
  echo "OK: $n VMs up. Next: scripts/qemu-fleet.sh collect"
}

cmd_status() {
  local n="${1:-$N_DEFAULT}"
  for i in $(seq 0 $((n - 1))); do
    local ssh_port=$((SSH_BASE + i)) rpc_port=$((RPC_BASE + i))
    if vm_running "$i"; then
      if ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 true 2>/dev/null; then s="ssh OK"; else s="ssh PENDING"; fi
      echo "vm $i: pid $(cat /tmp/qemu-node-$i.pid) ssh 127.0.0.1:$ssh_port rpc 127.0.0.1:$rpc_port - $s"
    else
      echo "vm $i: DOWN"
    fi
  done
}

cmd_ssh() {
  local i="${1:-0}" ssh_port=$((SSH_BASE + i))
  exec ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$ssh_port" ubuntu@127.0.0.1
}

cmd_collect() {
  local n="${1:-$N_DEFAULT}"
  ensure_key
  mkdir -p heartbeats
  local count=0
  for i in $(seq 0 $((n - 1))); do
    local ssh_port=$((SSH_BASE + i)) rpc_port=$((RPC_BASE + i))
    if ! ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 true 2>/dev/null; then
      echo "WARN: vm $i not reachable, skipping"; continue
    fi
    echo "==> vm $i: copying grid/ + running agent over real TCP"
    ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 'rm -rf /tmp/gridtest && mkdir -p /tmp/gridtest' >/dev/null
    scp -i "$KEY" $SSH_OPTS -P "$ssh_port" -r grid ubuntu@127.0.0.1:/tmp/gridtest/ >/dev/null
    ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 \
      "python3 /tmp/gridtest/grid/agent.py --once --node-id qemu-node-$i --wired --role worker" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); d['ip']='127.0.0.1'; d['rpc_port']=$rpc_port; print(json.dumps(d,indent=2))" \
      > "heartbeats/qemu-$i.json"
    echo "    saved heartbeats/qemu-$i.json (via 127.0.0.1:$rpc_port)"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { echo "ERROR: no VMs reachable; run: $0 up / status" >&2; exit 1; }
  echo "==> planning with $count real VM heartbeats (32B demo; 70B needs ~6 nodes)"
  python3 grid/control.py --fleet 'heartbeats/qemu-*.json' --model-preset qwen2.5-32b-q4 --model models/qwen-32b.gguf || true
  echo "--- honest 70B check:"
  python3 grid/control.py --fleet 'heartbeats/qemu-*.json' --model-preset llama3.3-70b-q4 --model models/llama.gguf || true
}

cmd_serve() {
  local n="${1:-$N_DEFAULT}"
  for i in $(seq 0 $((n - 1))); do
    local ssh_port=$((SSH_BASE + i)) rpc_port=$((RPC_BASE + i))
    if ! ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 true 2>/dev/null; then
      echo "WARN: vm $i not reachable, skipping"; continue
    fi
    if ! ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 'test -x ~/grid-think/result/bin/rpc-server' 2>/dev/null; then
      echo "WARN: vm $i has no ~/grid-think/result/bin/rpc-server, build it there first"; continue
    fi
    echo "==> vm $i: starting rpc-server (host 127.0.0.1:$rpc_port -> guest :50052)"
    ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 \
      'nohup ~/grid-think/result/bin/rpc-server -H 0.0.0.0 -p 50052 -c </dev/null >/tmp/rpc-guest.log 2>&1 & sleep 2; head -n 12 /tmp/rpc-guest.log'
  done
  echo "Workers up. From the Mac: llama-bench -m <model> -ngl 99 --rpc 127.0.0.1:50052,127.0.0.1:50053,..."
}

cmd_stop_workers() {
  local n="${1:-$N_DEFAULT}"
  for i in $(seq 0 $((n - 1))); do
    local ssh_port=$((SSH_BASE + i))
    ssh -i "$KEY" $SSH_OPTS -p "$ssh_port" ubuntu@127.0.0.1 'pkill -f rpc-server; echo "vm '"$i"' workers stopped"' 2>/dev/null || echo "WARN: vm $i not reachable"
  done
}

cmd_down() {
  local n="${1:-$N_DEFAULT}"
  for i in $(seq 0 $((n - 1))); do
    if vm_running "$i"; then kill "$(cat /tmp/qemu-node-$i.pid)" && echo "vm $i stopped"; rm -f "/tmp/qemu-node-$i.pid"; fi
  done
}

cmd_clean() {
  cmd_down "$@"
  rm -f "$IMGDIR"/node-*.qcow2 "$IMGDIR"/seed-*.iso
  rm -rf "$IMGDIR"/seed-*
  echo "cleaned overlays/seeds; kept $BASE_IMG + key"
}

case "${1:-help}" in
  up) shift; cmd_up "${1:-$N_DEFAULT}";;
  status) shift; cmd_status "${1:-$N_DEFAULT}";;
  ssh) shift; cmd_ssh "${1:-0}";;
  collect) shift; cmd_collect "${1:-$N_DEFAULT}";;
  serve) shift; cmd_serve "${1:-$N_DEFAULT}";;
  stop-workers) shift; cmd_stop_workers "${1:-$N_DEFAULT}";;
  down) shift; cmd_down "${1:-$N_DEFAULT}";;
  clean) shift; cmd_clean "${1:-$N_DEFAULT}";;
  *) echo "usage: $0 {up [N]|status [N]|ssh <i>|collect [N]|serve [N]|stop-workers [N]|down [N]|clean}"; exit 1;;
esac
