from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass
class NodeHeartbeat:
    node_id: str
    ip: str
    rpc_port: int = 50052
    free_mem_mib: int = 0
    total_mem_mib: int = 0
    cpu_cores: int = 4
    cpu_flags: list[str] = field(default_factory=list)
    backend: str = "cpu"
    llama_rev: str = "unknown"
    wired: bool = False
    role: str = "worker"
    version: int = 1

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "NodeHeartbeat":
        return NodeHeartbeat(
            node_id=str(d["node_id"]),
            ip=str(d["ip"]),
            rpc_port=int(d.get("rpc_port", 50052)),
            free_mem_mib=int(d.get("free_mem_mib", 0)),
            total_mem_mib=int(d.get("total_mem_mib", 0)),
            cpu_cores=int(d.get("cpu_cores", 4)),
            cpu_flags=list(d.get("cpu_flags", [])),
            backend=str(d.get("backend", "cpu")),
            llama_rev=str(d.get("llama_rev", "unknown")),
            wired=bool(d.get("wired", False)),
            role=str(d.get("role", "worker")),
            version=int(d.get("version", 1)),
        )


# Q4_K_M GGUF sizes plus KV headroom.
MODEL_BUDGET_MIB = {
    "qwen2.5-7b-q4": 4700,
    "llama3.1-8b-q4": 5000,
    "qwen2.5-32b-q4": 19000,
    "llama3.3-70b-q4": 40500,
    "qwen3-235b-moE-q4": 135000,
    "llama3.1-405b-q4": 231000,
}

MIN_FREE_MIB_WORKER = 3000
RESERVE_MIB_PER_NODE = 2048
