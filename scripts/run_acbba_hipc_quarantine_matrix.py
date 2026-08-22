#!/usr/bin/env python3
"""Run the complete post-fix ACBBA/HIPC study matrix in quarantine."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUARANTINE = ROOT / "quarantine" / "acbba_hipc_completion_retention_full_matrix"
HORIZONS = (1, 2, 3, 5, 8, 12)
TARGETS = {
    5: (ROOT / "scenarios" / "known_visit_g19_t5_n25.csv", 25),
    10: (ROOT / "reference_core_benchmark_pilot" / "known_visit_10target_300.csv", 300),
    20: (ROOT / "scenarios" / "known_visit_g19_t20_n25.csv", 25),
}
ALGORITHMS = {
    "acbba": ("ACBBA", "known_visit_sim.algorithms.ACBBA:ACBBAAllocator"),
    "hipc": ("HIPC", "known_visit_sim.algorithms.HIPC:HIPCAllocator"),
}
COMMS = {
    "ideal": ("ideal", None),
    "bernoulli_025": ("bernoulli", "0.25"),
}
RAW_FILES = ("trial_summary.csv", "system_performance.csv", "robot_performance.csv", "target_performance.csv")
DEFAULT_WORKERS = 12  # 75% of the host's 16 physical cores.


@dataclass(frozen=True)
class Job:
    target_count: int
    trials: int
    algorithm_key: str
    algorithm: str
    allocator: str
    horizon: int
    comm_label: str
    comm_model: str
    comm_level: str | None
    scenario: Path
    condition_id: str
    out_dir: Path
    command: tuple[str, ...]


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def hash_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def write_rows(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def make_jobs() -> list[Job]:
    jobs: list[Job] = []
    for target_count, (scenario, trials) in TARGETS.items():
        if not scenario.is_file():
            raise RuntimeError(f"missing scenario: {scenario}")
        for algorithm_key, (algorithm, allocator) in ALGORITHMS.items():
            for horizon in HORIZONS:
                for comm_label, (comm_model, comm_level) in COMMS.items():
                    condition_id = (
                        f"{algorithm_key}_h{horizon}_{comm_label}" if target_count == 10
                        else f"targets_{target_count}_{algorithm_key}_h{horizon}_{comm_label}"
                    )
                    out_dir = (QUARANTINE / "results" / "raw" / f"targets_{target_count}" /
                               f"h{horizon}" / comm_model / condition_id)
                    command = [
                        sys.executable, "-m", "known_visit_sim.run_trials",
                        "--scenario-file", str(scenario), "--algorithm", allocator,
                        "--algorithm-name", algorithm, "--grid-size", "19",
                        "--num-robots", "4", "--robot-start-layout", "edge_even",
                        "--condition-id", condition_id, "--seed", "0",
                        "--out-dir", str(out_dir), "--max-trials", str(trials),
                        "--commitment-horizon", str(horizon), "--comm-model", comm_model,
                        "--debug-max-events", "5000",
                    ]
                    if comm_level is not None:
                        command.extend(["--comm-level", comm_level])
                    jobs.append(Job(target_count, trials, algorithm_key, algorithm, allocator,
                                    horizon, comm_label, comm_model, comm_level, scenario,
                                    condition_id, out_dir, tuple(command)))
    jobs.sort(key=lambda job: (-job.trials, job.comm_label, job.algorithm_key,
                               job.horizon, job.target_count))
    if len(jobs) != 72:
        raise RuntimeError(f"expected 72 conditions, constructed {len(jobs)}")
    return jobs


def state(job: Job) -> tuple[set[int], set[int], list[str]]:
    path = job.out_dir / "system_performance.csv"
    if not path.is_file():
        return set(), set(), []
    rows = read_rows(path)
    recorded: set[int] = set()
    completed: set[int] = set()
    issues: list[str] = []
    for row in rows:
        try:
            trial = int(row["trial_id"])
        except (KeyError, ValueError):
            issues.append("invalid trial ID")
            continue
        if trial in recorded:
            issues.append(f"duplicate trial {trial}")
        recorded.add(trial)
        if row.get("trial_status") == "completed":
            completed.add(trial)
        if row.get("condition_id") != job.condition_id:
            issues.append(f"condition mismatch in trial {trial}")
        if row.get("all_targets_visited", "").lower() != "true":
            issues.append(f"targets incomplete in trial {trial}")
    return recorded, completed, sorted(set(issues))


def write_manifest(jobs: list[Job]) -> None:
    rows: list[dict[str, object]] = []
    for job in jobs:
        rows.append({
            "stage": "completion_retention_full_matrix_quarantine",
            "condition_id": job.condition_id, "algorithm": job.algorithm,
            "algorithm_key": job.algorithm_key, "target_count": job.target_count,
            "commitment_horizon": job.horizon, "comm_label": job.comm_label,
            "comm_model": job.comm_model,
            "comm_level": "" if job.comm_level is None else job.comm_level,
            "expected_trials": job.trials, "trial_ids": f"0-{job.trials-1}",
            "scenario_file": job.scenario.relative_to(ROOT).as_posix(),
            "scenario_sha256": hash_file(job.scenario), "simulator_seed": 0,
            "trial_seed_rule": "simulator_seed + trial_id * 1009",
            "debug_max_events": 5000, "out_dir": job.out_dir.relative_to(ROOT).as_posix(),
            "command": " ".join(job.command),
        })
    write_rows(QUARANTINE / "manifests" / "condition_manifest.csv", rows, list(rows[0]))
    (QUARANTINE / "manifests" / "campaign_manifest.json").write_text(json.dumps({
        "created_utc": now(), "workers": DEFAULT_WORKERS,
        "physical_cores": 16, "worker_fraction_of_physical_cores": 0.75,
        "condition_count": 72, "expected_trials": 8400,
        "target_load_trials": {"5": 25, "10": 300, "20": 25},
        "algorithms": ["ACBBA", "HIPC"], "horizons": list(HORIZONS),
        "communication": ["ideal", "bernoulli_025"],
        "published_results_overwritten": False,
    }, indent=2) + "\n", encoding="utf-8")


def run_job(job: Job) -> tuple[Job, int, float]:
    job.out_dir.mkdir(parents=True, exist_ok=True)
    log_dir = QUARANTINE / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({"OMP_NUM_THREADS":"1", "OPENBLAS_NUM_THREADS":"1",
                        "MKL_NUM_THREADS":"1", "NUMEXPR_NUM_THREADS":"1"})
    started = time.monotonic()
    result = subprocess.run(job.command, cwd=ROOT, env=environment,
                            text=True, capture_output=True)
    elapsed = time.monotonic() - started
    (log_dir / f"targets_{job.target_count}_{job.condition_id}.log").write_text(
        f"finished_utc: {now()}\nelapsed_seconds: {elapsed:.3f}\n"
        f"return_code: {result.returncode}\ncommand: {' '.join(job.command)}\n\n"
        f"STDOUT\n{result.stdout}\n\nSTDERR\n{result.stderr}", encoding="utf-8")
    return job, result.returncode, elapsed


def validate_job(job: Job) -> list[str]:
    recorded, completed, issues = state(job)
    expected_ids = set(range(job.trials))
    if recorded != expected_ids:
        issues.append(f"recorded IDs incomplete: {len(recorded)}/{job.trials}")
    if completed != expected_ids:
        issues.append(f"completed IDs incomplete: {len(completed)}/{job.trials}")
    expected_rows = {
        "trial_summary.csv": job.trials,
        "system_performance.csv": job.trials,
        "robot_performance.csv": 4 * job.trials,
        "target_performance.csv": job.target_count * job.trials,
    }
    for filename, count in expected_rows.items():
        path = job.out_dir / filename
        if not path.is_file():
            issues.append(f"missing {filename}")
            continue
        rows = read_rows(path)
        if len(rows) != count:
            issues.append(f"{filename}: {len(rows)} rows, expected {count}")
        if any(row.get("trial_status") != "completed" for row in rows):
            issues.append(f"{filename}: non-completed rows")
        keys = [(r.get("trial_id"), r.get("robot_id", ""), r.get("target_index", "")) for r in rows]
        if len(keys) != len(set(keys)):
            issues.append(f"{filename}: duplicate keys")
    return sorted(set(issues))


def combine_and_validate(jobs: list[Job]) -> dict[str, object]:
    combined_dir = QUARANTINE / "results" / "combined"
    combined_dir.mkdir(parents=True, exist_ok=True)
    validations: list[dict[str, object]] = []
    for job in jobs:
        issues = validate_job(job)
        _, completed, _ = state(job)
        validations.append({"condition_id": job.condition_id,
                            "target_count": job.target_count,
                            "expected_trials": job.trials,
                            "completed_trials": len(completed),
                            "failed_trials": job.trials-len(completed),
                            "technical_status": "complete" if not issues else "issue",
                            "issues": "; ".join(issues)})
    for filename in RAW_FILES:
        combined: list[dict[str, str]] = []
        fields: list[str] = []
        for job in jobs:
            path = job.out_dir / filename
            if not path.is_file():
                continue
            rows = read_rows(path)
            metadata = {"quarantine_target_count": str(job.target_count),
                        "quarantine_horizon": str(job.horizon),
                        "quarantine_comm_label": job.comm_label,
                        "quarantine_algorithm_key": job.algorithm_key}
            for row in rows:
                row.update(metadata)
                combined.append(row)
                for field in row:
                    if field not in fields:
                        fields.append(field)
        combined.sort(key=lambda r: (int(r["target_count"]), r["condition_id"],
                                     int(r["trial_id"]), r.get("robot_id", ""),
                                     int(r.get("target_index", -1))))
        if fields:
            write_rows(combined_dir / f"acbba_hipc_full_matrix_{filename}", combined, fields)
    manifest = read_rows(QUARANTINE / "manifests" / "condition_manifest.csv")
    write_rows(combined_dir / "acbba_hipc_full_matrix_condition_manifest.csv",
               manifest, list(manifest[0]))
    write_rows(QUARANTINE / "validation" / "condition_validation.csv",
               validations, list(validations[0]))
    expected = {"trial_summary.csv":8400, "system_performance.csv":8400,
                "robot_performance.csv":33600, "target_performance.csv":87000}
    observed = {name: len(read_rows(combined_dir / f"acbba_hipc_full_matrix_{name}"))
                for name in RAW_FILES}
    complete = all(row["technical_status"] == "complete" for row in validations) and observed == expected
    summary = {"validated_utc":now(), "technical_complete":complete,
               "conditions":len(jobs), "completed_conditions":sum(
                   row["technical_status"] == "complete" for row in validations),
               "expected_trials":8400, "completed_trials":sum(
                   int(row["completed_trials"]) for row in validations),
               "failed_trials":sum(int(row["failed_trials"]) for row in validations),
               "expected_combined_rows":expected, "observed_combined_rows":observed}
    path = QUARANTINE / "validation" / "validation_summary.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2)+"\n", encoding="utf-8")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--plan-only", action="store_true")
    group.add_argument("--status", action="store_true")
    group.add_argument("--combine-only", action="store_true")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    args = parser.parse_args()
    if not 1 <= args.workers <= DEFAULT_WORKERS:
        parser.error("--workers must be between 1 and 12")
    jobs = make_jobs()
    if args.plan_only:
        print("72 conditions; 8,400 trials; 12 workers (75% of 16 physical cores)")
        for job in jobs:
            print(f"targets={job.target_count} trials={job.trials} {job.condition_id}")
        return 0
    if args.status:
        total=0
        for job in jobs:
            _, completed, issues=state(job); total+=len(completed)
            print(f"targets={job.target_count} {job.condition_id}: {len(completed)}/{job.trials}"
                  + (f" issues={issues}" if issues else ""))
        print(f"total completed: {total}/8400")
        return 0
    write_manifest(jobs)
    if not args.combine_only:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures={pool.submit(run_job,job):job for job in jobs}
            for future in as_completed(futures):
                job,code,elapsed=future.result(); _,completed,issues=state(job)
                print(f"targets={job.target_count} {job.condition_id}: return={code}, "
                      f"completed={len(completed)}/{job.trials}, elapsed={elapsed:.1f}s"
                      + (f", issues={issues}" if issues else ""), flush=True)
    summary=combine_and_validate(jobs)
    print(json.dumps(summary,indent=2))
    return 0 if summary["technical_complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
