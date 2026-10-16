import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from grid.planner import plan

REV = "testrev"


def node(nid, free, ip="10.42.0.9", wired=True, role="worker", rev=REV, flags=("avx2",)):
    return {
        "node_id": nid, "ip": ip, "rpc_port": 50052,
        "free_mem_mib": free, "total_mem_mib": free + 2048,
        "cpu_cores": 4, "cpu_flags": list(flags), "backend": "cpu",
        "llama_rev": rev, "wired": wired, "role": role,
    }


def test_proportional_split():
    nodes = [
        node("coord", 12000, ip="10.42.0.1", role="coordinator"),
        node("w1", 8000, ip="10.42.0.11"),
        node("w2", 6000, ip="10.42.0.12"),
    ]
    p = plan(nodes, 18000, reserve_mib=2048)
    assert p.fits, p
    assert p.device_order[0] == "coord"
    assert p.tensor_split[0] > p.tensor_split[1] > p.tensor_split[2]
    assert len(p.rpc_endpoints) == 2
    cmd = p.llama_server_cmd("m.gguf")
    assert "--rpc 10.42.0.11:50052,10.42.0.12:50052" in cmd
    assert "--tensor-split" in cmd


def test_quarantine_and_shortfall():
    nodes = [
        node("coord", 10000, ip="10.42.0.1", role="coordinator"),
        node("tiny", 2000, ip="10.42.0.99"),
    ]
    p = plan(nodes, 40500, reserve_mib=2048)
    assert not p.fits
    assert p.shortfall_mib > 30000
    assert any(i.node_id == "tiny" for i in p.issues)


def test_rev_skew_warns():
    nodes = [
        node("coord", 12000, ip="10.42.0.1", role="coordinator", rev="aaa"),
        node("w1", 12000, ip="10.42.0.11", rev="bbb"),
    ]
    p = plan(nodes, 10000, reserve_mib=2048)
    assert any("skew" in w for w in p.warnings)


if __name__ == "__main__":
    test_proportional_split()
    test_quarantine_and_shortfall()
    test_rev_skew_warns()
    print("planner tests ok")
