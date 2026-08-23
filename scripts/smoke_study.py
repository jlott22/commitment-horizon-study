#!/usr/bin/env python3
"""Run one temporary trial for every study allocator and communication mode."""

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENARIO = ROOT / "scenarios" / "known_visit_g19_t5_n25.csv"
ALGORITHMS = (
    ("ACBBA", "known_visit_sim.algorithms.ACBBA:ACBBAAllocator"),
    ("HIPC", "known_visit_sim.algorithms.HIPC:HIPCAllocator"),
    ("PI", "known_visit_sim.algorithms.PI:PIAllocator"),
)
COMMS = (("ideal", None), ("bernoulli", "0.25"))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="commitment_horizon_smoke_") as temporary:
        root = Path(temporary)
        for algorithm_name, allocator in ALGORITHMS:
            for comm_model, comm_level in COMMS:
                condition = f"smoke_{algorithm_name.lower()}_{comm_model}"
                out_dir = root / condition
                command = [
                    sys.executable, "-m", "known_visit_sim.run_trials",
                    "--scenario-file", str(SCENARIO),
                    "--algorithm", allocator,
                    "--algorithm-name", algorithm_name,
                    "--grid-size", "19", "--num-robots", "4",
                    "--robot-start-layout", "edge_even",
                    "--condition-id", condition, "--seed", "0",
                    "--out-dir", str(out_dir), "--max-trials", "1",
                    "--commitment-horizon", "3", "--comm-model", comm_model,
                    "--debug-max-events", "5000",
                ]
                if comm_level is not None:
                    command.extend(["--comm-level", comm_level])
                result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
                if result.returncode != 0:
                    raise RuntimeError(f"{condition} exited {result.returncode}: {result.stderr}")
                with (out_dir / "system_performance.csv").open("r", newline="", encoding="utf-8-sig") as handle:
                    records = list(csv.DictReader(handle))
                if len(records) != 1 or records[0].get("trial_status") != "completed":
                    raise RuntimeError(f"{condition} did not produce one completed trial")
                if records[0].get("all_targets_visited", "").lower() != "true":
                    raise RuntimeError(f"{condition} did not visit every target")
                print(f"PASS {condition}")
    print("Smoke verification PASS: 3 allocators x 2 communication modes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
