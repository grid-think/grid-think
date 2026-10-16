#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from grid.planner import plan  # noqa: E402
from grid.schema import MODEL_BUDGET_MIB, NodeHeartbeat  # noqa: E402


def load_fleet(patterns: list[str]) -> list[dict]:
    nodes: list[dict] = []
    paths: list[str] = []
    for p in patterns:
        paths.extend(glob.glob(p) or [p])
    for path in paths:
        with open(path) as f:
            txt = f.read().strip()
            if not txt:
                continue
            try:
                obj = json.loads(txt)
                if isinstance(obj, list):
                    nodes.extend(obj)
                else:
                    nodes.append(obj)
                continue
            except json.JSONDecodeError:
                pass
            for line in txt.splitlines():
                line = line.strip()
                if line:
                    nodes.append(json.loads(line))
    return [NodeHeartbeat.from_dict(n).to_dict() for n in nodes]


def order_nodes(nodes: list[dict]) -> list[dict]:
    coord = [n for n in nodes if n.get("role") == "coordinator"]
    workers = [n for n in nodes if n.get("role") != "coordinator"]
    workers.sort(key=lambda n: int(n.get("free_mem_mib", 0)), reverse=True)
    if coord:
        return coord + workers
    return sorted(nodes, key=lambda n: int(n.get("free_mem_mib", 0)), reverse=True)


def main() -> None:
    ap = argparse.ArgumentParser(description="grid-think coordinator planner")
    ap.add_argument("--fleet", nargs="+", required=True, help="heartbeat JSON files/globs")
    ap.add_argument("--model-size-mib", type=int, default=0)
    ap.add_argument("--model-preset", default="", choices=[""] + list(MODEL_BUDGET_MIB.keys()))
    ap.add_argument("--model", default="model.gguf", help="GGUF path, only needed on coordinator")
    ap.add_argument("--reserve-mib", type=int, default=2048)
    ap.add_argument("--emit", default="run", choices=["run", "bench", "json"])
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    size = args.model_size_mib or MODEL_BUDGET_MIB.get(args.model_preset, 0)
    if not size:
        print("error: give --model-size-mib or --model-preset", file=sys.stderr)
        print(f"presets: {MODEL_BUDGET_MIB}", file=sys.stderr)
        sys.exit(2)

    nodes = load_fleet(args.fleet)
    if not nodes:
        print("error: no heartbeats loaded", file=sys.stderr)
        sys.exit(2)
    ordered = order_nodes(nodes)
    p = plan(ordered, size, reserve_mib=args.reserve_mib)

    if args.emit == "json":
        print(json.dumps({
            "model_size_mib": p.model_size_mib,
            "total_usable_mib": p.total_usable_mib,
            "fits": p.fits,
            "shortfall_mib": p.shortfall_mib,
            "device_order": p.device_order,
            "tensor_split": p.tensor_split,
            "rpc_endpoints": p.rpc_endpoints,
            "cmd": p.llama_server_cmd(args.model, port=args.port),
            "issues": [vars(i) for i in p.issues],
            "warnings": p.warnings,
        }, indent=2))
    else:
        print(f"fleet: {len(ordered)} seen, {len(p.device_order)} usable | need {p.model_size_mib} MiB, have {p.total_usable_mib} MiB")
        print(f"order (device0=local): {p.device_order}")
        print(f"split weights: {[f'{w:.1f}' for w in p.tensor_split]}")
        for w in p.warnings:
            print(f"WARN: {w}")
        for i in p.issues:
            print(f"SKIP {i.node_id}: {i.reason}")
        if not p.fits:
            print(f"DOES NOT FIT: short {p.shortfall_mib} MiB, add ~{(p.shortfall_mib + 5999) // 6000} more 8GB nodes or pick a smaller preset")
        cmd = p.llama_server_cmd(args.model, port=args.port)
        if args.emit == "bench":
            rpc = ",".join(p.rpc_endpoints)
            ts = ",".join(f"{w:.2f}" for w in p.tensor_split)
            rpc_flag = f" --rpc {rpc}" if rpc else ""
            print(f"llama-bench -m {args.model} -ngl 99{rpc_flag} --tensor-split {ts} -p 512 -n 128")
        else:
            print(cmd)
            print("# 1) on each worker: grid-agent --serve")
            print("# 2) on coordinator: run the llama-server line above")

    if not p.fits:
        sys.exit(2)


if __name__ == "__main__":
    main()
