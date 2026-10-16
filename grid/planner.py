from __future__ import annotations

from dataclasses import dataclass, field

from .schema import MIN_FREE_MIB_WORKER, RESERVE_MIB_PER_NODE


@dataclass
class PlanIssue:
    node_id: str
    reason: str


@dataclass
class GridPlan:
    rpc_endpoints: list[str]
    tensor_split: list[float]
    device_order: list[str]
    total_usable_mib: int
    model_size_mib: int
    fits: bool
    shortfall_mib: int = 0
    issues: list[PlanIssue] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def llama_server_cmd(
        self, model_path: str, host: str = "127.0.0.1", port: int = 8080, ngl: int = 99
    ) -> str:
        ts = ",".join(f"{w:.2f}" for w in self.tensor_split)
        rpc = ",".join(self.rpc_endpoints)
        rpc_flag = f" --rpc {rpc}" if rpc else ""
        return (
            f"llama-server -m {model_path} -ngl {ngl}"
            f"{rpc_flag} --tensor-split {ts}"
            f" --host {host} --port {port}"
        )


def plan(
    nodes_in_order: list[dict],
    model_size_mib: int,
    reserve_mib: int = RESERVE_MIB_PER_NODE,
) -> GridPlan:
    issues: list[PlanIssue] = []
    warnings: list[str] = []
    usable: list[tuple[str, str, int]] = []

    if not nodes_in_order:
        return GridPlan([], [], [], 0, model_size_mib, False, model_size_mib)

    revs = {n.get("llama_rev", "unknown") for n in nodes_in_order}
    if len(revs) > 1:
        # RPC hangs on version skew, so fail loud here instead.
        warnings.append(f"llama_rev skew {sorted(revs)} - rebuild all nodes from same flake.lock")

    for i, n in enumerate(nodes_in_order):
        nid = str(n.get("node_id", f"node{i}"))
        free = int(n.get("free_mem_mib", 0))
        u = max(0, free - reserve_mib)
        if u < MIN_FREE_MIB_WORKER and i != 0:
            issues.append(PlanIssue(nid, f"only {u} MiB usable, need {MIN_FREE_MIB_WORKER}"))
            continue
        if not bool(n.get("wired", False)):
            warnings.append(f"{nid} on WiFi: expect ~10x slower decode, use Ethernet")
        flags = list(n.get("cpu_flags", []))
        is_arm = "neon" in flags or "apple-silicon" in flags
        if "avx2" not in flags and str(n.get("backend", "cpu")) == "cpu" and not is_arm:
            warnings.append(f"{nid} lacks AVX2: 4-bit math runs ~2x slower")
        ep = f"{n['ip']}:{int(n.get('rpc_port', 50052))}" if i != 0 else "local"
        usable.append((nid, ep, u))

    total = sum(u for _, _, u in usable)
    fits = total >= model_size_mib
    shortfall = max(0, model_size_mib - total)

    if usable:
        weakest = min(usable, key=lambda t: t[2])
        if weakest[2] * len(usable) < model_size_mib * 1.5:
            warnings.append(f"weakest node is {weakest[0]} ({weakest[2]} MiB), it sets decode speed")

    device_order = [nid for nid, _, _ in usable]
    rpc_endpoints = [ep for _, ep, _ in usable[1:]]
    tensor_split = [float(u) for _, _, u in usable]

    return GridPlan(
        rpc_endpoints=rpc_endpoints,
        tensor_split=tensor_split,
        device_order=device_order,
        total_usable_mib=total,
        model_size_mib=model_size_mib,
        fits=fits,
        shortfall_mib=shortfall,
        issues=issues,
        warnings=warnings,
    )
