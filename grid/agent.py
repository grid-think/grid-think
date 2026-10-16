#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from grid.schema import NodeHeartbeat  # noqa: E402


def sh(cmd: list[str], timeout: int = 5) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def mem_linux() -> tuple[int, int]:
    total = free_avail = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    free_avail = int(line.split()[1]) // 1024
    except FileNotFoundError:
        pass
    return total, free_avail


def mem_darwin() -> tuple[int, int]:
    total = 0
    out = sh(["sysctl", "-n", "hw.memsize"])
    try:
        total = int(out.strip()) // (1024 * 1024)
    except ValueError:
        pass
    vm = sh(["vm_stat"])
    free_pages = 0
    for key in ["Pages free:", "Pages inactive:", "Pages speculative:"]:
        m = re.search(rf"{re.escape(key)}\s+(\d+)", vm)
        if m:
            free_pages += int(m.group(1))
    page = 16384
    free = free_pages * page // (1024 * 1024) if free_pages else total // 4
    return total, free


def cpu_flags() -> list[str]:
    machine = platform.machine().lower()
    if machine in ("aarch64", "arm64", "armv7l", "armv8l"):
        flags = ["neon"]
        if sys.platform == "darwin":
            flags.append("apple-silicon")
        return flags
    flags = []
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/cpuinfo") as f:
                txt = f.read().lower()
            for fl in ["avx512f", "avx2", "avx", "vnni", "fma"]:
                if fl in txt and fl not in flags:
                    flags.append(fl)
        except FileNotFoundError:
            pass
    return flags


def has_vulkan() -> bool:
    if shutil.which("vulkaninfo"):
        return True
    for p in ("/dev/dri", "/usr/share/vulkan"):
        if os.path.exists(p):
            return True
    return False


def is_wired(ip: str) -> bool:
    out = sh(["ip", "-o", "route", "get", "10.42.0.1"])
    if re.search(r"dev\s+(en|eth|eno|enp|em)\S*", out):
        return True
    out2 = sh(["route", "-n", "get", "10.42.0.1"])
    if re.search(r"interface:\s+(en\d+)", out2):
        return True
    return False


def local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.42.0.1", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"


def llama_rev() -> str:
    for b in ["rpc-server", "llama-server"]:
        p = shutil.which(b)
        if p:
            revf = os.path.join(os.path.dirname(p), ".llama-rev")
            try:
                with open(revf) as f:
                    return f.read().strip()
            except OSError:
                pass
            out = sh([b, "--version"])
            m = re.search(r"\b(b\d{4,5}|[0-9a-f]{7,40})\b", out)
            if m:
                return m.group(1)
    return os.environ.get("GRID_LLAMA_REV", "unknown")


def build_heartbeat(args) -> NodeHeartbeat:
    if sys.platform.startswith("linux"):
        total, free = mem_linux()
    else:
        total, free = mem_darwin()
    backend = "cpu"
    if args.backend != "auto":
        backend = args.backend
    else:
        if platform.system() == "Darwin" and "arm" in platform.machine().lower():
            backend = "metal"
        elif has_vulkan():
            backend = "vulkan"
    wired = args.wired if args.wired is not None else is_wired(args.ip or "")
    return NodeHeartbeat(
        node_id=args.node_id or socket.gethostname(),
        ip=args.ip or local_ip(),
        rpc_port=args.port,
        free_mem_mib=min(free, args.mem) if args.mem else free,
        total_mem_mib=total,
        cpu_cores=os.cpu_count() or 4,
        cpu_flags=cpu_flags(),
        backend=backend,
        llama_rev=llama_rev(),
        wired=wired,
        role=args.role,
    )


def main() -> None:
    ap = argparse.ArgumentParser(description="grid-think worker agent")
    ap.add_argument("--once", action="store_true", help="print heartbeat JSON and exit")
    ap.add_argument("--check", action="store_true", help="preflight: binary, RAM, net")
    ap.add_argument("--serve", action="store_true", help="exec rpc-server")
    ap.add_argument("--node-id", default="")
    ap.add_argument("--ip", default="")
    ap.add_argument("--port", type=int, default=50052)
    ap.add_argument("--mem", type=int, default=0, help="cap advertised MiB")
    ap.add_argument("--backend", default="auto", choices=["auto", "cpu", "vulkan", "metal"])
    ap.add_argument("--role", default="worker", choices=["worker", "coordinator"])
    ap.add_argument("--wired", dest="wired", action="store_true", default=None)
    ap.add_argument("--wireless", dest="wired", action="store_false")
    args = ap.parse_args()

    if args.check:
        hb = build_heartbeat(args)
        ok = True
        print(f"node: {hb.node_id} {hb.ip}:{hb.rpc_port} backend={hb.backend} rev={hb.llama_rev}")
        print(f"ram:  total={hb.total_mem_mib} free={hb.free_mem_mib} MiB cores={hb.cpu_cores} {hb.cpu_flags}")
        if not shutil.which("rpc-server"):
            print("FAIL: rpc-server not in PATH, run `nix develop` first")
            ok = False
        if hb.total_mem_mib and hb.total_mem_mib < 4096:
            print("WARN: under 4GB total, small models only")
        if not hb.wired:
            print("WARN: no wired link found, expect slow RPC, use Ethernet")
        sys.exit(0 if ok else 1)

    if args.serve:
        hb = build_heartbeat(args)
        # Upstream dropped the -m flag, so --mem only caps the advertised number.
        print(f"serving on {hb.ip}:{hb.rpc_port} rev={hb.llama_rev} ({hb.free_mem_mib} MiB)", flush=True)
        os.execvp("rpc-server", ["rpc-server", "-H", "0.0.0.0", "-p", str(hb.rpc_port), "-c"])

    hb = build_heartbeat(args)
    print(json.dumps(hb.to_dict(), indent=2))


if __name__ == "__main__":
    main()
