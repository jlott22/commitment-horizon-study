#!/usr/bin/env python3
"""Run, resume, combine, and validate the target-load/horizon pilot.

This wrapper deliberately invokes ``known_visit_sim.run_trials`` rather than
copying simulator or allocator logic.  Each condition has its own output
directory, and the underlying runner checkpoints every completed *or failed*
trial ID.  Consequently a resume preserves the original trial seed rule and
never replaces a recorded failed trial with a new draw.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import platform
import subprocess
import sys
import threading
import time
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = EXPERIMENT_ROOT
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

CAMPAIGN_NAME = "horizon_tuning_conference"
SCENARIOS_DIR = EXPERIMENT_ROOT / "scenarios"
SCRIPTS_DIR = EXPERIMENT_ROOT / "scripts"
MANIFESTS_DIR = EXPERIMENT_ROOT / "manifests"
LOGS_DIR = EXPERIMENT_ROOT / "logs"
RAW_DIR = EXPERIMENT_ROOT / "results" / "raw"
COMBINED_DIR = EXPERIMENT_ROOT / "results" / "combined"


def configure_workspace(workspace: str | None) -> None:
    """Redirect all mutable campaign state to a repository-local workspace."""
    global MANIFESTS_DIR, LOGS_DIR, RAW_DIR, COMBINED_DIR
    if workspace is None:
        root = EXPERIMENT_ROOT
    else:
        candidate = Path(workspace)
        if not candidate.is_absolute():
            candidate = REPO_ROOT / candidate
        root = ensure_in_experiment(candidate)
    MANIFESTS_DIR = root / "manifests"
    LOGS_DIR = root / "logs"
    RAW_DIR = root / "results" / "raw"
    COMBINED_DIR = root / "results" / "combined"

GRID_SIZE = 19
NUM_ROBOTS = 4
TRIALS_PER_CONDITION = 25
SIMULATOR_SEED = 0
TRIAL_SEED_RULE = "simulator_seed + trial_id * 1009; simulator_seed=0"
HISTORICAL_EVENT_CAP = 5_000
HORIZONS = (1, 2, 3, 5, 8, 12)
TARGET_COUNTS = (5, 20)
SCENARIO_SEEDS = {5: 2026082105, 20: 2026082120}
DEFAULT_WORKERS = 12  # Existing campaign convention: 3/4 of 16 physical cores.
MAX_SAFE_WORKERS = 12
SYSTEMIC_FAILURE_THRESHOLD = 3

RAW_FILES = (
    "trial_summary.csv",
    "system_performance.csv",
    "robot_performance.csv",
    "target_performance.csv",
)

TRIAL_REQUIRED_COLUMNS = {
    "trial_id",
    "algorithm",
    "comm_model",
    "comm_level",
    "target_count",
    "condition_id",
    "scenario_file",
    "completed_target_count",
    "all_targets_visited",
    "trial_status",
}
SYSTEM_REQUIRED_COLUMNS = {
    "trial_id",
    "algorithm",
    "comm_model",
    "comm_level",
    "target_count",
    "condition_id",
    "scenario_file",
    "completed_target_count",
    "all_targets_visited",
    "total_team_steps",
    "max_robot_steps",
    "final_target_completion_sim_time_s",
    "workload_gini_targets_found",
    "workload_gini_unique_cells_contributed",
    "allocation_messages_sent_total",
    "messages_sent_total",
    "allocator_time_ms_team_total",
    "trial_status",
}
ROBOT_REQUIRED_COLUMNS = {"trial_id", "robot_id", "trial_status", "steps_total"}
TARGET_REQUIRED_COLUMNS = {"trial_id", "target_index", "completed", "trial_status"}


class CampaignError(RuntimeError):
    """A non-transient campaign integrity failure."""


class TransientOutputError(RuntimeError):
    """A raw CSV changed while it was being monitored."""


@dataclass(frozen=True)
class AlgorithmSpec:
    key: str
    canonical_name: str
    allocator_spec: str
    runner_name: str
    weight: int
    dga_iterations: int | None = None


@dataclass(frozen=True)
class CommSpec:
    label: str
    model: str
    level: str | None


@dataclass(frozen=True)
class Job:
    target_count: int
    algorithm: AlgorithmSpec
    horizon: int
    comm: CommSpec
    scenario_file: Path
    out_dir: Path
    condition_id: str
    command: tuple[str, ...]


@dataclass
class ConditionState:
    label: str
    recorded_trial_ids: set[int]
    completed_trial_ids: set[int]
    failed_trial_ids: set[int]
    issues: list[str]
    files_present: set[str]
    rows: dict[str, list[dict[str, str]]]
    headers: dict[str, list[str]]

    @property
    def recorded_count(self) -> int:
        return len(self.recorded_trial_ids)

    @property
    def is_terminal(self) -> bool:
        return self.recorded_trial_ids == set(range(TRIALS_PER_CONDITION)) and not self.issues

    @property
    def status(self) -> str:
        if not self.files_present:
            return "not_started"
        if self.issues:
            return "malformed"
        if self.recorded_trial_ids == set(range(TRIALS_PER_CONDITION)):
            return "finished_with_failed_trials" if self.failed_trial_ids else "complete"
        return "running" if self.recorded_trial_ids else "incomplete"


ALGORITHMS = (
    AlgorithmSpec(
        "acbba",
        "ACBBA",
        "known_visit_sim.algorithms.ACBBA:ACBBAAllocator",
        "ACBBA",
        2,
    ),
    AlgorithmSpec(
        "pi",
        "PI",
        "known_visit_sim.algorithms.PI:PIAllocator",
        "PI",
        2,
    ),
    AlgorithmSpec(
        "hipc",
        "HIPC",
        "known_visit_sim.algorithms.HIPC:HIPCAllocator",
        "HIPC",
        2,
    ),
    AlgorithmSpec(
        "dmchba",
        "DMCHBA",
        "known_visit_sim.algorithms.DMCHBA:DMCHBAAllocator",
        "DMCHBA",
        4,
    ),
    AlgorithmSpec(
        "dga",
        "DGA",
        "known_visit_sim.algorithms.dga_iter_wrappers.DGA_iter_25:DGAIter25Allocator",
        "DGA_iter_25",
        4,
        25,
    ),
)
COMMS = (
    CommSpec("ideal", "ideal", None),
    CommSpec("bernoulli_025", "bernoulli", "0.25"),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalized_absolute(path: Path | str) -> str:
    """Return a normal Windows/POSIX absolute path without an extended prefix.

    Concurrent ``Path.resolve()`` calls on this Windows host can inconsistently
    return ``\\\\?\\C:\\...`` paths.  Comparing normalized lexical absolute paths is
    sufficient here because all campaign destinations are constructed locally
    beneath the experiment root; it also avoids that platform-specific race.
    """
    value = os.path.normpath(os.path.abspath(os.fspath(path)))
    if value.startswith("\\\\?\\"):
        value = value[4:]
    return os.path.normcase(value)


def rel(path: Path) -> str:
    return Path(os.path.relpath(normalized_absolute(path), normalized_absolute(REPO_ROOT))).as_posix()


def ensure_in_experiment(path: Path) -> Path:
    candidate = normalized_absolute(path)
    root = normalized_absolute(EXPERIMENT_ROOT)
    try:
        common = os.path.commonpath([candidate, root])
    except ValueError as exc:
        raise CampaignError(f"Cannot compare campaign path {path}") from exc
    if common != root:
        raise CampaignError(f"Path escapes the experiment folder: {candidate}")
    return Path(candidate)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text_atomic(path: Path, text: str) -> None:
    ensure_in_experiment(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8", newline="")
    os.replace(temporary, path)


def write_json_atomic(path: Path, payload: Any) -> None:
    write_text_atomic(path, json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n")


def write_csv_atomic(path: Path, rows: Iterable[dict[str, Any]], fieldnames: list[str]) -> None:
    ensure_in_experiment(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    os.replace(temporary, path)


def git_text(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=REPO_ROOT, text=True).strip()


def file_signature(path: Path) -> tuple[int, int]:
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns


def read_csv_stable(path: Path, attempts: int = 4) -> tuple[list[dict[str, str]], list[str]]:
    """Read a CSV, tolerating a concurrently rewritten raw output file."""
    last_error: Exception | None = None
    for _ in range(attempts):
        try:
            before = file_signature(path)
            with path.open("r", newline="", encoding="utf-8-sig") as handle:
                reader = csv.DictReader(handle)
                headers = list(reader.fieldnames or [])
                if not headers:
                    raise ValueError("CSV has no header")
                rows = list(reader)
            after = file_signature(path)
            if before == after:
                return rows, headers
            last_error = TransientOutputError("file changed while read")
        except (OSError, UnicodeError, csv.Error, ValueError) as exc:
            last_error = exc
        time.sleep(0.15)
    raise TransientOutputError(f"Could not stably read {path}: {last_error}")


def parse_int(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def parse_float(value: Any) -> float | None:
    try:
        parsed = float(str(value).strip())
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def is_truthy(value: Any) -> bool:
    return str(value).strip().lower() in {"true", "1", "yes"}


def scenario_path(target_count: int) -> Path:
    return SCENARIOS_DIR / f"known_visit_g19_t{target_count}_n25.csv"


def load_scenario_csv(path: Path) -> list[dict[str, str]]:
    rows, _ = read_csv_stable(path)
    return rows


def validate_scenario_file(path: Path, target_count: int) -> dict[str, Any]:
    from known_visit_sim.config import edge_even_start_positions, generate_robot_ids
    from known_visit_sim.core.scenario_loader import load_scenarios

    starts = set(edge_even_start_positions(GRID_SIZE, generate_robot_ids(NUM_ROBOTS)).values())
    scenarios = load_scenarios(path, GRID_SIZE, starts)
    expected_ids = list(range(TRIALS_PER_CONDITION))
    ids = [int(item.trial_id) for item in scenarios]
    if ids != expected_ids:
        raise CampaignError(f"{path} trial IDs must be {expected_ids}, found {ids}")
    if len(scenarios) != TRIALS_PER_CONDITION:
        raise CampaignError(f"{path} must contain {TRIALS_PER_CONDITION} scenarios")
    if any(len(item.targets) != target_count for item in scenarios):
        counts = sorted({len(item.targets) for item in scenarios})
        raise CampaignError(f"{path} has target counts {counts}, expected {target_count}")
    return {
        "path": rel(path),
        "sha256": sha256(path),
        "trial_ids": ids,
        "target_count": target_count,
        "grid_size": GRID_SIZE,
        "robot_count": NUM_ROBOTS,
        "robot_start_layout": "edge_even",
        "generation_seed": SCENARIO_SEEDS[target_count],
    }


def ensure_scenarios() -> dict[int, dict[str, Any]]:
    """Generate the two immutable paired scenario files only when absent."""
    from known_visit_sim.generate_scenarios import generate

    metadata: dict[int, dict[str, Any]] = {}
    for target_count in TARGET_COUNTS:
        path = scenario_path(target_count)
        ensure_in_experiment(path)
        if not path.exists():
            targets_by_trial = generate(
                GRID_SIZE,
                TRIALS_PER_CONDITION,
                target_count,
                NUM_ROBOTS,
                SCENARIO_SEEDS[target_count],
            )
            fields = ["trial_id"]
            for index in range(1, target_count + 1):
                fields.extend([f"target{index}_x", f"target{index}_y"])
            lines = [
                "# "
                f"grid_size={GRID_SIZE}, num_targets={target_count}, num_robots={NUM_ROBOTS}, "
                f"layout=edge_even, seed={SCENARIO_SEEDS[target_count]}",
                ",".join(fields),
            ]
            for trial_id, targets in enumerate(targets_by_trial):
                values = [str(trial_id)] + [str(value) for cell in targets for value in cell]
                lines.append(",".join(values))
            write_text_atomic(path, "\n".join(lines) + "\n")
        metadata[target_count] = validate_scenario_file(path, target_count)
    write_json_atomic(MANIFESTS_DIR / "scenario_manifest.json", {
        "generated_or_verified_utc": utc_now(),
        "scenario_generator": "known_visit_sim.generate_scenarios.generate",
        "scenario_seed_convention": {
            "5_targets": SCENARIO_SEEDS[5],
            "20_targets": SCENARIO_SEEDS[20],
            "existing_10_target_campaign": 0,
        },
        "scenarios": metadata,
    })
    return metadata


def validate_existing_scenarios() -> dict[int, dict[str, Any]]:
    """Validate the committed scenario inputs without writing any files."""
    metadata: dict[int, dict[str, Any]] = {}
    for target_count in TARGET_COUNTS:
        path = scenario_path(target_count)
        if not path.is_file():
            raise CampaignError(f"Committed scenario file is missing: {path}")
        metadata[target_count] = validate_scenario_file(path, target_count)
    return metadata


def make_jobs() -> list[Job]:
    jobs: list[Job] = []
    for target_count in TARGET_COUNTS:
        scenario = scenario_path(target_count)
        for horizon in HORIZONS:
            for algorithm in ALGORITHMS:
                for comm in COMMS:
                    condition_id = f"targets_{target_count}_{algorithm.key}_h{horizon}_{comm.label}"
                    out_dir = RAW_DIR / f"targets_{target_count}" / f"h{horizon}" / comm.model / condition_id
                    ensure_in_experiment(out_dir)
                    command = [
                        sys.executable,
                        "-m",
                        "known_visit_sim.run_trials",
                        "--scenario-file",
                        rel(scenario),
                        "--algorithm",
                        algorithm.allocator_spec,
                        "--algorithm-name",
                        algorithm.runner_name,
                        "--grid-size",
                        str(GRID_SIZE),
                        "--num-robots",
                        str(NUM_ROBOTS),
                        "--robot-start-layout",
                        "edge_even",
                        "--condition-id",
                        condition_id,
                        "--seed",
                        str(SIMULATOR_SEED),
                        "--out-dir",
                        rel(out_dir),
                        "--max-trials",
                        str(TRIALS_PER_CONDITION),
                        "--commitment-horizon",
                        str(horizon),
                        "--comm-model",
                        comm.model,
                        # The historic 10-target campaign was run before the adaptive
                        # default was introduced, when 19x19/4 defaulted to 5,000.
                        "--debug-max-events",
                        str(HISTORICAL_EVENT_CAP),
                    ]
                    if comm.level is not None:
                        command.extend(["--comm-level", comm.level])
                    jobs.append(Job(
                        target_count=target_count,
                        algorithm=algorithm,
                        horizon=horizon,
                        comm=comm,
                        scenario_file=scenario,
                        out_dir=out_dir,
                        condition_id=condition_id,
                        command=tuple(command),
                    ))
    # Run heavier DGA/DMCHBA loss cases first to reduce end-of-campaign tail time.
    jobs.sort(key=lambda job: (-job.algorithm.weight, job.comm.label, job.target_count,
                               job.horizon, job.algorithm.key))
    if len(jobs) != 120:
        raise CampaignError(f"Expected 120 conditions, constructed {len(jobs)}")
    if len({job.condition_id for job in jobs}) != len(jobs):
        raise CampaignError("Condition IDs are not unique")
    return jobs


def required_columns_for(filename: str) -> set[str]:
    return {
        "trial_summary.csv": TRIAL_REQUIRED_COLUMNS,
        "system_performance.csv": SYSTEM_REQUIRED_COLUMNS,
        "robot_performance.csv": ROBOT_REQUIRED_COLUMNS,
        "target_performance.csv": TARGET_REQUIRED_COLUMNS,
    }[filename]


def inspect_condition(job: Job) -> ConditionState:
    """Read a raw condition directory without treating in-progress writes as corrupt."""
    files_present: set[str] = set()
    rows: dict[str, list[dict[str, str]]] = {}
    headers: dict[str, list[str]] = {}
    issues: list[str] = []
    for filename in RAW_FILES:
        path = job.out_dir / filename
        if not path.exists():
            continue
        files_present.add(filename)
        try:
            parsed_rows, parsed_headers = read_csv_stable(path)
            rows[filename] = parsed_rows
            headers[filename] = parsed_headers
        except TransientOutputError:
            # The generic runner rewrites CSVs after each trial.  Treat an
            # unstable read as temporary until the child process exits.
            continue

    trial_rows = rows.get("trial_summary.csv", [])
    system_rows = rows.get("system_performance.csv", [])
    trial_ids: list[int] = []
    system_ids: list[int] = []
    completed_ids: set[int] = set()
    failed_ids: set[int] = set()
    for row in trial_rows:
        trial_id = parse_int(row.get("trial_id"))
        if trial_id is None:
            issues.append("trial_summary.csv contains a non-integer trial_id")
            continue
        trial_ids.append(trial_id)
        status = str(row.get("trial_status", "")).strip().lower()
        if status in {"", "completed"}:
            completed_ids.add(trial_id)
        elif status == "failed":
            failed_ids.add(trial_id)
        else:
            issues.append(f"trial {trial_id} has unsupported trial_status={status!r}")
    for row in system_rows:
        trial_id = parse_int(row.get("trial_id"))
        if trial_id is None:
            issues.append("system_performance.csv contains a non-integer trial_id")
        else:
            system_ids.append(trial_id)
    if len(trial_ids) != len(set(trial_ids)):
        issues.append("duplicate trial IDs in trial_summary.csv")
    if len(system_ids) != len(set(system_ids)):
        issues.append("duplicate trial IDs in system_performance.csv")
    expected_ids = set(range(TRIALS_PER_CONDITION))
    if any(trial_id not in expected_ids for trial_id in trial_ids):
        issues.append("trial_summary.csv contains a trial ID outside 0..24")
    if any(trial_id not in expected_ids for trial_id in system_ids):
        issues.append("system_performance.csv contains a trial ID outside 0..24")
    if system_rows and set(system_ids) != set(trial_ids):
        issues.append("trial_summary.csv and system_performance.csv have different trial IDs")
    return ConditionState(
        label=job.condition_id,
        recorded_trial_ids=set(trial_ids),
        completed_trial_ids=completed_ids,
        failed_trial_ids=failed_ids,
        issues=issues,
        files_present=files_present,
        rows=rows,
        headers=headers,
    )


def expected_raw_comm_level(job: Job) -> str:
    return "1.0" if job.comm.model == "ideal" else "drop_0.25"


def validate_condition(job: Job, *, require_terminal: bool) -> list[str]:
    """Perform stable semantic validation of one raw condition."""
    state = inspect_condition(job)
    errors = list(state.issues)
    if require_terminal and state.recorded_trial_ids != set(range(TRIALS_PER_CONDITION)):
        errors.append(
            f"expected all 25 recorded trial IDs, found {sorted(state.recorded_trial_ids)}"
        )
    if not state.rows:
        if require_terminal:
            errors.append("condition has no readable raw output")
        return errors

    for filename in RAW_FILES:
        if filename not in state.rows:
            if require_terminal:
                errors.append(f"missing {filename}")
            continue
        missing = required_columns_for(filename) - set(state.headers.get(filename, []))
        if missing:
            errors.append(f"{filename} missing required columns: {sorted(missing)}")

    trial_rows = state.rows.get("trial_summary.csv", [])
    system_rows = state.rows.get("system_performance.csv", [])
    robot_rows = state.rows.get("robot_performance.csv", [])
    target_rows = state.rows.get("target_performance.csv", [])
    expected_runner_name = job.algorithm.runner_name
    for filename, data_rows in (("trial_summary.csv", trial_rows), ("system_performance.csv", system_rows)):
        for row in data_rows:
            trial_id = parse_int(row.get("trial_id"))
            if parse_int(row.get("target_count")) != job.target_count:
                errors.append(f"{filename} trial {trial_id}: target_count is not {job.target_count}")
            if str(row.get("algorithm", "")) != expected_runner_name:
                errors.append(f"{filename} trial {trial_id}: algorithm label is not {expected_runner_name}")
            if str(row.get("comm_model", "")) != job.comm.model:
                errors.append(f"{filename} trial {trial_id}: comm_model is not {job.comm.model}")
            if str(row.get("comm_level", "")) != expected_raw_comm_level(job):
                errors.append(
                    f"{filename} trial {trial_id}: comm_level is not {expected_raw_comm_level(job)}"
                )
            if str(row.get("condition_id", "")) != job.condition_id:
                errors.append(f"{filename} trial {trial_id}: condition_id is wrong")
            source = Path(str(row.get("scenario_file", "")))
            expected_source = rel(job.scenario_file)
            if source.as_posix() != expected_source:
                errors.append(f"{filename} trial {trial_id}: scenario_file is not {expected_source}")

    if require_terminal:
        expected_robot_rows = TRIALS_PER_CONDITION * NUM_ROBOTS
        expected_target_rows = TRIALS_PER_CONDITION * job.target_count
        if len(trial_rows) != TRIALS_PER_CONDITION:
            errors.append(f"trial_summary.csv has {len(trial_rows)} rows, expected 25")
        if len(system_rows) != TRIALS_PER_CONDITION:
            errors.append(f"system_performance.csv has {len(system_rows)} rows, expected 25")
        if len(robot_rows) != expected_robot_rows:
            errors.append(f"robot_performance.csv has {len(robot_rows)} rows, expected {expected_robot_rows}")
        if len(target_rows) != expected_target_rows:
            errors.append(f"target_performance.csv has {len(target_rows)} rows, expected {expected_target_rows}")
        robot_counts = Counter(parse_int(row.get("trial_id")) for row in robot_rows)
        target_counts = Counter(parse_int(row.get("trial_id")) for row in target_rows)
        for trial_id in range(TRIALS_PER_CONDITION):
            if robot_counts[trial_id] != NUM_ROBOTS:
                errors.append(f"trial {trial_id}: robot row count is {robot_counts[trial_id]}, expected 4")
            if target_counts[trial_id] != job.target_count:
                errors.append(
                    f"trial {trial_id}: target row count is {target_counts[trial_id]}, "
                    f"expected {job.target_count}"
                )

    numeric_metrics = (
        "total_team_steps",
        "max_robot_steps",
        "final_target_completion_sim_time_s",
        "workload_gini_targets_found",
        "workload_gini_unique_cells_contributed",
        "allocation_messages_sent_total",
        "messages_sent_total",
        "allocator_time_ms_team_total",
    )
    completed_ids = {
        parse_int(row.get("trial_id"))
        for row in trial_rows
        if str(row.get("trial_status", "")).strip().lower() in {"", "completed"}
    }
    for row in trial_rows:
        trial_id = parse_int(row.get("trial_id"))
        if trial_id in completed_ids:
            if parse_int(row.get("completed_target_count")) != job.target_count:
                errors.append(f"completed trial {trial_id}: completed_target_count is not target count")
            if not is_truthy(row.get("all_targets_visited")):
                errors.append(f"completed trial {trial_id}: all_targets_visited is not true")
    for row in system_rows:
        trial_id = parse_int(row.get("trial_id"))
        if trial_id in completed_ids:
            if parse_int(row.get("completed_target_count")) != job.target_count:
                errors.append(f"completed system trial {trial_id}: completed_target_count is wrong")
            if not is_truthy(row.get("all_targets_visited")):
                errors.append(f"completed system trial {trial_id}: all_targets_visited is not true")
            for metric in numeric_metrics:
                if parse_float(row.get(metric)) is None:
                    errors.append(f"completed system trial {trial_id}: {metric} is not finite")
    target_by_trial: dict[int, list[dict[str, str]]] = {}
    for row in target_rows:
        trial_id = parse_int(row.get("trial_id"))
        if trial_id is not None:
            target_by_trial.setdefault(trial_id, []).append(row)
    for trial_id in completed_ids:
        completed = [is_truthy(row.get("completed")) for row in target_by_trial.get(trial_id, [])]
        if completed and not all(completed):
            errors.append(f"completed trial {trial_id}: one or more targets are not marked complete")

    config_path = job.out_dir / "config_used.json"
    if state.recorded_trial_ids and not config_path.exists():
        errors.append("config_used.json missing despite recorded output")
    elif config_path.exists():
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
            sim_config = config.get("sim_config", {})
            if parse_int(sim_config.get("commitment_horizon")) != job.horizon:
                errors.append("config_used.json has wrong commitment horizon")
            if parse_int(sim_config.get("grid_size")) != GRID_SIZE:
                errors.append("config_used.json has wrong grid size")
            if len(sim_config.get("robot_ids", [])) != NUM_ROBOTS:
                errors.append("config_used.json has wrong robot count")
            if parse_int(sim_config.get("debug_max_events")) != HISTORICAL_EVENT_CAP:
                errors.append("config_used.json has wrong historical event cap")
            if str(config.get("algorithm", "")) != job.algorithm.allocator_spec:
                errors.append("config_used.json has wrong allocator specification")
            if str(config.get("algorithm_name", "")) != job.algorithm.runner_name:
                errors.append("config_used.json has wrong algorithm name")
            if parse_int(config.get("seed")) != SIMULATOR_SEED:
                errors.append("config_used.json has wrong simulator seed")
        except (OSError, json.JSONDecodeError, TypeError) as exc:
            errors.append(f"cannot parse config_used.json: {exc}")
    return sorted(set(errors))


def condition_manifest_rows(jobs: list[Job], scenarios: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    commit = git_text("rev-parse", "HEAD")
    for job in sorted(jobs, key=lambda item: (item.target_count, item.horizon, item.algorithm.key, item.comm.label)):
        state = inspect_condition(job)
        rows.append({
            "campaign": CAMPAIGN_NAME,
            "stage": "target_load_horizon_pilot",
            "environment": "known",
            "parameter": "commitment_horizon",
            "value": job.horizon,
            "setting": f"h{job.horizon}",
            "condition_id": job.condition_id,
            "run_id": job.condition_id,
            "algorithm_key": job.algorithm.key,
            "algorithm": job.algorithm.canonical_name,
            "runner_algorithm_name": job.algorithm.runner_name,
            "allocator_spec": job.algorithm.allocator_spec,
            "dga_iterations": job.algorithm.dga_iterations or "",
            "dga_population_size": 30 if job.algorithm.key == "dga" else "",
            "dga_mutation_rate": 0.3 if job.algorithm.key == "dga" else "",
            "dga_crossover_rate": 0.7 if job.algorithm.key == "dga" else "",
            "dga_elite_count": 2 if job.algorithm.key == "dga" else "",
            "max_candidate_cells": "all" if job.algorithm.key == "dga" else "",
            "comm_label": job.comm.label,
            "comm_model": job.comm.model,
            "comm_level_requested": job.comm.level or "",
            "comm_level_raw_expected": expected_raw_comm_level(job),
            "grid_size": GRID_SIZE,
            "robot_count": NUM_ROBOTS,
            "robot_start_layout": "edge_even",
            "target_count": job.target_count,
            "scenario_file": rel(job.scenario_file),
            "scenario_sha256": scenarios[job.target_count]["sha256"],
            "scenario_generation_seed": SCENARIO_SEEDS[job.target_count],
            "simulator_seed": SIMULATOR_SEED,
            "simulator_seed_convention": TRIAL_SEED_RULE,
            "debug_max_events": HISTORICAL_EVENT_CAP,
            "debug_max_stagnant_events": 2000,
            "trial_count": TRIALS_PER_CONDITION,
            "out_dir": rel(job.out_dir),
            "git_commit": commit,
            "run_command": json.dumps(list(job.command)),
            "status": state.status,
            "recorded_trials": state.recorded_count,
            "completed_trials": len(state.completed_trial_ids),
            "failed_trials": len(state.failed_trial_ids),
            "status_issues": " | ".join(state.issues),
        })
    return rows


def write_condition_manifest(jobs: list[Job], scenarios: dict[int, dict[str, Any]]) -> None:
    rows = condition_manifest_rows(jobs, scenarios)
    fieldnames = list(rows[0].keys()) if rows else []
    write_csv_atomic(MANIFESTS_DIR / "condition_manifest.csv", rows, fieldnames)


def snapshot_existing_results() -> None:
    """Record hashes of pre-existing repository results before the new campaign."""
    snapshot_path = MANIFESTS_DIR / "preexisting_results_sha256.csv"
    if snapshot_path.exists():
        return
    result_root = REPO_ROOT / "results"
    rows: list[dict[str, Any]] = []
    for path in sorted(result_root.rglob("*")):
        if path.is_file():
            rows.append({"path": rel(path), "size_bytes": path.stat().st_size, "sha256": sha256(path)})
    write_csv_atomic(snapshot_path, rows, ["path", "size_bytes", "sha256"])
    write_json_atomic(MANIFESTS_DIR / "preexisting_results_snapshot.json", {
        "created_utc": utc_now(),
        "file_count": len(rows),
        "scope": "All files under repository results/ before this pilot launched.",
    })


def verify_existing_results_snapshot() -> list[str]:
    snapshot_path = MANIFESTS_DIR / "preexisting_results_sha256.csv"
    if not snapshot_path.exists():
        return ["preexisting result snapshot does not exist"]
    baseline_rows, _ = read_csv_stable(snapshot_path)
    baseline = {row["path"]: (row["size_bytes"], row["sha256"]) for row in baseline_rows}
    current: dict[str, tuple[str, str]] = {}
    for path in sorted((REPO_ROOT / "results").rglob("*")):
        if path.is_file():
            current[rel(path)] = (str(path.stat().st_size), sha256(path))
    issues: list[str] = []
    if set(baseline) != set(current):
        issues.append("existing results file set changed after pilot launch")
    for path, signature in baseline.items():
        if current.get(path) != signature:
            issues.append(f"existing result changed: {path}")
    return issues


def make_campaign_manifest(jobs: list[Job], scenarios: dict[int, dict[str, Any]], workers: int) -> None:
    payload = {
        "campaign": CAMPAIGN_NAME,
        "created_or_updated_utc": utc_now(),
        "repository_root": str(REPO_ROOT),
        "experiment_root": str(EXPERIMENT_ROOT),
        "git_commit": git_text("rev-parse", "HEAD"),
        "git_status_porcelain_at_launch": git_text("status", "--porcelain"),
        "python_executable": sys.executable,
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "logical_processors": os.cpu_count(),
        "physical_cores_reported_by_existing_campaign_convention": 16,
        "worker_count": workers,
        "worker_policy": (
            "One sequential condition runner per worker; cap at 12 workers, "
            "matching three quarters of 16 physical cores in reruns/run_pi_core_matrix.py."
        ),
        "matrix": {
            "target_counts": list(TARGET_COUNTS),
            "algorithms": [item.canonical_name for item in ALGORITHMS],
            "horizons": list(HORIZONS),
            "communication": [item.label for item in COMMS],
            "trials_per_condition": TRIALS_PER_CONDITION,
            "condition_count": len(jobs),
            "expected_algorithm_runs": len(jobs) * TRIALS_PER_CONDITION,
        },
        "scenario_generation": scenarios,
        "simulator_seed": SIMULATOR_SEED,
        "simulator_seed_rule": TRIAL_SEED_RULE,
        "historical_settings_preserved": {
            "event_cap": HISTORICAL_EVENT_CAP,
            "event_cap_reason": (
                "Historic 10-target campaign used the pre-a00ef9b 19x19/4 default of 5000; "
                "passed explicitly because current auto-scaled default is 10000."
            ),
            "debug_max_stagnant_events": 2000,
            "dga": {
                "allocator_spec": ALGORITHMS[-1].allocator_spec,
                "population_size": 30,
                "iterations_per_trigger": 25,
                "mutation_rate": 0.3,
                "crossover_rate": 0.7,
                "elite_count": 2,
                "max_candidate_cells": None,
            },
        },
        "jobs": [
            {
                "condition_id": job.condition_id,
                "target_count": job.target_count,
                "algorithm": job.algorithm.canonical_name,
                "allocator_spec": job.algorithm.allocator_spec,
                "horizon": job.horizon,
                "comm_label": job.comm.label,
                "comm_model": job.comm.model,
                "comm_level": job.comm.level,
                "scenario_file": rel(job.scenario_file),
                "out_dir": rel(job.out_dir),
                "command": list(job.command),
            }
            for job in jobs
        ],
    }
    write_json_atomic(MANIFESTS_DIR / "campaign_manifest.json", payload)


def process_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        # Windows can return WinError 87 for ``os.kill(pid, 0)`` even when the
        # process exists.  Use tasklist as the platform fallback so --status
        # and the duplicate-launch guard remain reliable.
        if os.name == "nt":
            try:
                probe = subprocess.run(
                    ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                return f'"{pid}"' in probe.stdout
            except OSError:
                return False
        return False
    return True


class CampaignLock:
    def __init__(self) -> None:
        self.path = LOGS_DIR / "campaign.lock"
        self.held = False

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            try:
                existing = json.loads(self.path.read_text(encoding="utf-8"))
                pid = int(existing.get("pid", 0))
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                pid = 0
            if process_is_alive(pid):
                raise CampaignError(
                    f"A campaign process is already active (pid={pid}); use --status rather than starting another."
                )
            # A dead process cannot hold the lock.  Preserve its details in the log,
            # then recover only this experiment-local lock.
            stale = self.path.with_name(f"campaign.stale.{int(time.time())}.lock")
            os.replace(self.path, stale)
        try:
            descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError as exc:
            raise CampaignError("Campaign lock was concurrently acquired") from exc
        payload = {"pid": os.getpid(), "started_utc": utc_now(), "campaign": CAMPAIGN_NAME}
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
            handle.write("\n")
        self.held = True

    def release(self) -> None:
        if self.held:
            try:
                self.path.unlink(missing_ok=True)
            finally:
                self.held = False


class CampaignLogger:
    def __init__(self) -> None:
        self.path = LOGS_DIR / "campaign.log"
        self._lock = threading.Lock()

    def write(self, message: str) -> None:
        line = f"[{utc_now()}] {message}"
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8", buffering=1) as handle:
                handle.write(line + "\n")
            print(line, flush=True)


def write_completion_marker(job: Job, *, returncode: int, validation_errors: list[str]) -> None:
    state = inspect_condition(job)
    payload = {
        "condition_id": job.condition_id,
        "finished_utc": utc_now(),
        "returncode": returncode,
        "status": state.status,
        "recorded_trial_ids": sorted(state.recorded_trial_ids),
        "completed_trial_ids": sorted(state.completed_trial_ids),
        "failed_trial_ids": sorted(state.failed_trial_ids),
        "validation_errors": validation_errors,
    }
    write_json_atomic(job.out_dir / "_PILOT_CONDITION_STATUS.json", payload)


def condition_log_path(job: Job) -> Path:
    return LOGS_DIR / "conditions" / f"{job.condition_id}.log"


def run_job(
    job: Job,
    active: dict[str, subprocess.Popen[str]],
    active_lock: threading.Lock,
    stop_event: threading.Event,
    logger: CampaignLogger,
) -> dict[str, Any]:
    if stop_event.is_set():
        return {"condition_id": job.condition_id, "skipped": True, "reason": "systemic stop"}
    state = inspect_condition(job)
    if state.is_terminal:
        return {"condition_id": job.condition_id, "skipped": True, "reason": state.status}
    job.out_dir.mkdir(parents=True, exist_ok=True)
    log_path = condition_log_path(job)
    ensure_in_experiment(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        environment[name] = "1"
    started = utc_now()
    with log_path.open("a", encoding="utf-8", buffering=1) as handle:
        handle.write(f"\n[{started}] START {json.dumps(list(job.command))}\n")
        process = subprocess.Popen(
            list(job.command),
            cwd=REPO_ROOT,
            env=environment,
            stdout=handle,
            stderr=subprocess.STDOUT,
            text=True,
        )
        with active_lock:
            active[job.condition_id] = process
        try:
            returncode = process.wait()
        finally:
            with active_lock:
                active.pop(job.condition_id, None)
        handle.write(f"[{utc_now()}] EXIT {returncode}\n")
    logger.write(f"condition process exited {job.condition_id}: returncode={returncode}")
    return {
        "condition_id": job.condition_id,
        "started_utc": started,
        "finished_utc": utc_now(),
        "returncode": returncode,
        "skipped": False,
    }


def stop_active_processes(active: dict[str, subprocess.Popen[str]], active_lock: threading.Lock,
                          logger: CampaignLogger) -> None:
    with active_lock:
        processes = list(active.items())
    for condition_id, process in processes:
        if process.poll() is None:
            logger.write(f"terminating active condition after systemic stop: {condition_id}")
            process.terminate()
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if all(process.poll() is not None for _, process in processes):
            return
        time.sleep(0.2)
    for condition_id, process in processes:
        if process.poll() is None:
            logger.write(f"killing unresponsive condition after systemic stop: {condition_id}")
            process.kill()


def first_output_check(jobs: list[Job]) -> tuple[bool, list[str]]:
    """Minimal in-place smoke check after real campaign records first appear."""
    for job in jobs:
        state = inspect_condition(job)
        if state.recorded_count == 0:
            continue
        # ``run_trials`` rewrites the four CSVs and then config_used.json after
        # each record.  Wait until a complete stable set exists before judging
        # the first in-place check, rather than mistaking that short write window
        # for a malformed campaign.
        if set(RAW_FILES) - state.files_present or not (job.out_dir / "config_used.json").exists():
            continue
        errors = validate_condition(job, require_terminal=False)
        if errors:
            # A runner may be between rewriting output files.  Defer the check if
            # the condition's child has not finished; a later monitor pass retries.
            return False, [f"{job.condition_id}: {error}" for error in errors]
        return True, [
            f"condition={job.condition_id}",
            f"target_count={job.target_count}",
            f"algorithm={job.algorithm.canonical_name}",
            f"horizon={job.horizon}",
            f"communication={job.comm.label}",
            "required CSV columns present",
            f"output_dir={rel(job.out_dir)}",
        ]
    return False, []


def repeated_failure_signatures(jobs: list[Job]) -> Counter[tuple[str, str]]:
    counts: Counter[tuple[str, str]] = Counter()
    for job in jobs:
        state = inspect_condition(job)
        for row in state.rows.get("trial_summary.csv", []):
            if str(row.get("trial_status", "")).strip().lower() == "failed":
                counts[(str(row.get("failure_type", "")), str(row.get("failure_message", "")))] += 1
    return counts


def monitor_summary(jobs: list[Job]) -> dict[str, Any]:
    states = [inspect_condition(job) for job in jobs]
    total = sum(state.recorded_count for state in states)
    return {
        "recorded_trials": total,
        "expected_trials": len(jobs) * TRIALS_PER_CONDITION,
        "complete_conditions": sum(state.status == "complete" for state in states),
        "conditions_with_recorded_failures": sum(state.status == "finished_with_failed_trials" for state in states),
        "running_or_partial_conditions": sum(state.status in {"running", "incomplete"} for state in states),
        "malformed_conditions": sum(state.status == "malformed" for state in states),
        "not_started_conditions": sum(state.status == "not_started" for state in states),
        "failed_trial_records": sum(len(state.failed_trial_ids) for state in states),
    }


def combine_results(jobs: list[Job], scenarios: dict[int, dict[str, Any]]) -> dict[str, Any]:
    """Resumably rebuild canonical pilot combined files from raw condition CSVs."""
    ensure_in_experiment(COMBINED_DIR)
    summary: dict[str, Any] = {}
    metadata_fields = [
        "stage", "environment", "parameter", "value", "setting", "algorithm_key",
        "canonical_algorithm", "dga_iterations", "comm_label", "target_count_condition",
        "scenario_generation_seed", "scenario_sha256", "out_dir", "run_id",
    ]
    for filename in RAW_FILES:
        all_rows: list[dict[str, Any]] = []
        fieldnames: list[str] = []
        seen_fields: set[str] = set()
        for job in sorted(jobs, key=lambda item: (item.target_count, item.horizon, item.algorithm.key, item.comm.label)):
            source = job.out_dir / filename
            if not source.exists():
                continue
            try:
                rows, headers = read_csv_stable(source)
            except TransientOutputError as exc:
                raise CampaignError(f"Cannot combine unstable source {source}: {exc}") from exc
            for field in headers:
                if field not in seen_fields:
                    seen_fields.add(field)
                    fieldnames.append(field)
            for row in rows:
                row = dict(row)
                row.update({
                    "stage": "target_load_horizon_pilot",
                    "environment": "known",
                    "parameter": "commitment_horizon",
                    "value": str(job.horizon),
                    "setting": f"h{job.horizon}",
                    "algorithm_key": job.algorithm.key,
                    "canonical_algorithm": job.algorithm.canonical_name,
                    "dga_iterations": str(job.algorithm.dga_iterations or ""),
                    "comm_label": job.comm.label,
                    "target_count_condition": str(job.target_count),
                    "scenario_generation_seed": str(SCENARIO_SEEDS[job.target_count]),
                    "scenario_sha256": scenarios[job.target_count]["sha256"],
                    "out_dir": rel(job.out_dir),
                    "run_id": job.condition_id,
                })
                # Match the archival combined-file convention: canonicalize the
                # DGA iteration wrapper back to the comparison label DGA.
                row["algorithm"] = job.algorithm.canonical_name
                all_rows.append(row)
        for field in metadata_fields:
            if field not in seen_fields:
                seen_fields.add(field)
                fieldnames.append(field)
        stem = Path(filename).stem
        destination = COMBINED_DIR / f"target_load_horizon_pilot_25_combined_{stem}.csv"
        write_csv_atomic(destination, all_rows, fieldnames)
        summary[filename] = {
            "path": rel(destination),
            "rows": len(all_rows),
            "sha256": sha256(destination),
        }
    manifest_rows = condition_manifest_rows(jobs, scenarios)
    combined_manifest = COMBINED_DIR / "target_load_horizon_pilot_25_combined_condition_manifest.csv"
    write_csv_atomic(combined_manifest, manifest_rows, list(manifest_rows[0].keys()))
    summary["condition_manifest.csv"] = {
        "path": rel(combined_manifest),
        "rows": len(manifest_rows),
        "sha256": sha256(combined_manifest),
    }
    write_json_atomic(COMBINED_DIR / "combination_manifest.json", {
        "combined_utc": utc_now(),
        "files": summary,
        "note": "Files are rebuilt atomically from raw condition outputs; failed trials are retained.",
    })
    return summary


def validate_campaign(jobs: list[Job], scenarios: dict[int, dict[str, Any]]) -> tuple[list[dict[str, Any]], bool]:
    """Write machine-readable validation results and a compact text report."""
    checks: list[dict[str, Any]] = []

    def add(name: str, status: str, observed: Any, expected: Any, details: str = "") -> None:
        checks.append({
            "check_name": name,
            "status": status,
            "observed": observed,
            "expected": expected,
            "details": details,
        })

    add("condition_count", "PASS" if len(jobs) == 120 else "FAIL", len(jobs), 120)
    for target_count in TARGET_COUNTS:
        scenario_jobs = [job for job in jobs if job.target_count == target_count]
        unique_files = {rel(job.scenario_file) for job in scenario_jobs}
        add(
            f"paired_scenario_file_targets_{target_count}",
            "PASS" if len(unique_files) == 1 else "FAIL",
            ";".join(sorted(unique_files)),
            rel(scenario_path(target_count)),
        )
        try:
            verified = validate_scenario_file(scenario_path(target_count), target_count)
            add(f"scenario_validation_targets_{target_count}", "PASS", verified["sha256"], "valid 25-trial paired scenario")
        except CampaignError as exc:
            add(f"scenario_validation_targets_{target_count}", "FAIL", "invalid", "valid scenario", str(exc))

    completed_conditions = 0
    failed_trials_total = 0
    all_trial_ids_by_target: dict[int, list[set[int]]] = {count: [] for count in TARGET_COUNTS}
    for job in jobs:
        state = inspect_condition(job)
        errors = validate_condition(job, require_terminal=state.is_terminal)
        expected = set(range(TRIALS_PER_CONDITION))
        add(
            f"unique_trial_ids::{job.condition_id}",
            "PASS" if not state.issues else "FAIL",
            sorted(state.recorded_trial_ids),
            list(range(TRIALS_PER_CONDITION)),
            " | ".join(state.issues),
        )
        add(
            f"condition_integrity::{job.condition_id}",
            "PASS" if not errors else ("PENDING" if not state.is_terminal else "FAIL"),
            state.status,
            "complete or finished_with_failed_trials",
            " | ".join(errors),
        )
        if state.is_terminal:
            completed_conditions += 1
        failed_trials_total += len(state.failed_trial_ids)
        all_trial_ids_by_target[job.target_count].append(state.recorded_trial_ids)
    for target_count, id_sets in all_trial_ids_by_target.items():
        comparable = [ids for ids in id_sets if ids]
        paired = all(ids == comparable[0] for ids in comparable) if comparable else False
        add(
            f"paired_trial_ids_targets_{target_count}",
            "PASS" if paired and comparable and comparable[0] == set(range(TRIALS_PER_CONDITION)) else "PENDING",
            sorted(comparable[0]) if comparable else [],
            list(range(TRIALS_PER_CONDITION)),
            "Trial IDs must match across all algorithms, horizons, and communication conditions.",
        )

    expected_rows = {
        "trial_summary.csv": 3000,
        "system_performance.csv": 3000,
        "robot_performance.csv": 12000,
        "target_performance.csv": 37500,
    }
    combined_rows: dict[str, int] = {}
    for filename, expected in expected_rows.items():
        path = COMBINED_DIR / f"target_load_horizon_pilot_25_combined_{Path(filename).stem}.csv"
        observed = 0
        details = ""
        if path.exists():
            try:
                rows, _ = read_csv_stable(path)
                observed = len(rows)
            except TransientOutputError as exc:
                details = str(exc)
        combined_rows[filename] = observed
        status = "PASS" if observed == expected else ("PENDING" if completed_conditions < 120 else "FAIL")
        add(f"combined_row_count::{filename}", status, observed, expected, details)
    add("condition_manifest_rows", "PASS" if len(jobs) == 120 else "FAIL", len(jobs), 120)
    add("failed_trial_records", "WARN" if failed_trials_total else "PASS", failed_trials_total, 0,
        "Failed rows are retained and never rerun with a different seed.")

    try:
        existing_results_issues = verify_existing_results_snapshot()
        add(
            "preexisting_results_unchanged",
            "PASS" if not existing_results_issues else "FAIL",
            "unchanged" if not existing_results_issues else "changed",
            "unchanged",
            " | ".join(existing_results_issues),
        )
    except Exception as exc:  # Snapshot auditing must not hide other validation results.
        add("preexisting_results_unchanged", "WARN", "unverified", "unchanged", repr(exc))

    all_pass = all(item["status"] in {"PASS", "WARN", "PENDING"} for item in checks)
    write_csv_atomic(
        MANIFESTS_DIR / "validation_results.csv",
        checks,
        ["check_name", "status", "observed", "expected", "details"],
    )
    counts = Counter(item["status"] for item in checks)
    report_lines = [
        f"{CAMPAIGN_NAME} validation report",
        f"generated_utc: {utc_now()}",
        f"conditions_terminal: {completed_conditions}/120",
        f"failed_trial_records: {failed_trials_total}",
        f"combined_rows: {json.dumps(combined_rows, sort_keys=True)}",
        f"status_counts: {json.dumps(dict(counts), sort_keys=True)}",
        "",
    ]
    for item in checks:
        if item["status"] != "PASS":
            report_lines.append(
                f"[{item['status']}] {item['check_name']}: observed={item['observed']} "
                f"expected={item['expected']} {item['details']}"
            )
    write_text_atomic(MANIFESTS_DIR / "validation_report.txt", "\n".join(report_lines) + "\n")
    return checks, all_pass


def status_command(jobs: list[Job]) -> int:
    summary = monitor_summary(jobs)
    lock_path = LOGS_DIR / "campaign.lock"
    lock_state = "not present"
    if lock_path.exists():
        try:
            lock_payload = json.loads(lock_path.read_text(encoding="utf-8"))
            pid = int(lock_payload.get("pid", 0))
            lock_state = f"active pid={pid}" if process_is_alive(pid) else f"stale pid={pid}"
        except Exception:
            lock_state = "unreadable"
    print(f"Campaign lock: {lock_state}")
    print(
        "Progress: {recorded_trials}/{expected_trials} trials; "
        "complete={complete_conditions}; finished_with_failed_trials={conditions_with_recorded_failures}; "
        "partial={running_or_partial_conditions}; malformed={malformed_conditions}; "
        "not_started={not_started_conditions}; failed_trial_records={failed_trial_records}".format(**summary)
    )
    return 0


def plan_command(jobs: list[Job], scenarios: dict[int, dict[str, Any]]) -> int:
    """Print the validated deterministic campaign matrix without mutating state."""
    expected_conditions = len(TARGET_COUNTS) * len(ALGORITHMS) * len(HORIZONS) * len(COMMS)
    if len(jobs) != expected_conditions:
        raise CampaignError(f"Planned {len(jobs)} conditions; expected {expected_conditions}")
    print(
        f"Validated plan: {len(jobs)} conditions / "
        f"{len(jobs) * TRIALS_PER_CONDITION} algorithm runs"
    )
    for target_count in TARGET_COUNTS:
        item = scenarios[target_count]
        print(f"Scenario t={target_count}: {item['path']} sha256={item['sha256']}")
    for job in jobs:
        print(f"{job.condition_id}\t{' '.join(job.command)}")
    return 0


def run_campaign(jobs: list[Job], scenarios: dict[int, dict[str, Any]], workers: int) -> int:
    logger = CampaignLogger()
    lock = CampaignLock()
    lock.acquire()
    try:
        snapshot_existing_results()
        make_campaign_manifest(jobs, scenarios, workers)
        write_condition_manifest(jobs, scenarios)
        logger.write(
            f"starting {len(jobs)} conditions / {len(jobs) * TRIALS_PER_CONDITION} algorithm runs "
            f"with {workers} workers"
        )
        active: dict[str, subprocess.Popen[str]] = {}
        active_lock = threading.Lock()
        stop_event = threading.Event()
        systemic_reason: str | None = None
        first_check_written = (MANIFESTS_DIR / "first_output_check.json").exists()
        queued = [job for job in jobs if not inspect_condition(job).is_terminal]
        logger.write(f"queued {len(queued)} non-terminal conditions; terminal conditions will be preserved")
        futures: dict[Future[dict[str, Any]], Job] = {}
        last_monitor = 0.0
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="pilot-condition") as executor:
            for job in queued:
                futures[executor.submit(run_job, job, active, active_lock, stop_event, logger)] = job
            pending: set[Future[dict[str, Any]]] = set(futures)
            while pending:
                done, pending = wait(pending, timeout=1.0, return_when=FIRST_COMPLETED)
                now = time.monotonic()
                if not first_check_written:
                    passed, details = first_output_check(jobs)
                    if passed:
                        write_json_atomic(MANIFESTS_DIR / "first_output_check.json", {
                            "checked_utc": utc_now(), "status": "PASS", "checks": details,
                        })
                        logger.write("minimal in-place first-output check passed: " + "; ".join(details))
                        first_check_written = True
                    elif details:
                        systemic_reason = "first output check failed: " + " | ".join(details)
                if systemic_reason is None:
                    signatures = repeated_failure_signatures(jobs)
                    repeated = [
                        (signature, count) for signature, count in signatures.items()
                        if count >= SYSTEMIC_FAILURE_THRESHOLD
                    ]
                    if repeated:
                        systemic_reason = f"repeated identical trial exceptions: {repeated}"
                if now - last_monitor >= 15 or done:
                    summary = monitor_summary(jobs)
                    logger.write(
                        "monitor: {recorded_trials}/{expected_trials} trials, complete={complete_conditions}, "
                        "failed-condition-records={conditions_with_recorded_failures}, partial={running_or_partial_conditions}, "
                        "malformed={malformed_conditions}".format(**summary)
                    )
                    write_condition_manifest(jobs, scenarios)
                    last_monitor = now
                for future in done:
                    job = futures[future]
                    try:
                        result = future.result()
                    except Exception as exc:  # Unexpected wrapper fault is systemic.
                        systemic_reason = f"campaign worker exception for {job.condition_id}: {exc!r}"
                        continue
                    if result.get("skipped"):
                        continue
                    returncode = int(result.get("returncode", -1))
                    errors = validate_condition(job, require_terminal=returncode == 0)
                    write_completion_marker(job, returncode=returncode, validation_errors=errors)
                    if returncode != 0:
                        logger.write(f"condition process failure preserved for resume: {job.condition_id} exit={returncode}")
                    elif errors:
                        systemic_reason = f"completed condition validation failed for {job.condition_id}: {' | '.join(errors)}"
                if systemic_reason is not None:
                    logger.write("SYSTEMIC STOP: " + systemic_reason)
                    stop_event.set()
                    for future in pending:
                        future.cancel()
                    stop_active_processes(active, active_lock, logger)
                    break
        write_condition_manifest(jobs, scenarios)
        combination = combine_results(jobs, scenarios)
        checks, validation_ok = validate_campaign(jobs, scenarios)
        write_json_atomic(MANIFESTS_DIR / "completion_manifest.json", {
            "finished_utc": utc_now(),
            "systemic_reason": systemic_reason,
            "combination": combination,
            "validation_ok_or_pending": validation_ok,
            "status": monitor_summary(jobs),
        })
        if systemic_reason is not None:
            return 2
        logger.write("campaign workers settled; combined outputs and validation report were updated")
        return 0
    except KeyboardInterrupt:
        logger.write("campaign interrupted by user; partial condition outputs remain resumable")
        return 130
    finally:
        lock.release()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run/resume/status/combine the known-target target-load horizon pilot."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true", help="Report status without launching any condition.")
    mode.add_argument("--combine-only", action="store_true", help="Rebuild combined outputs and validation only.")
    mode.add_argument("--validate-only", action="store_true", help="Validate current raw/combined outputs only.")
    mode.add_argument("--plan-only", action="store_true",
                      help="Validate and print the full campaign matrix without writing or launching trials.")
    parser.add_argument("--resume", action="store_true", help="Documented no-op mode: normal launch is already resumable.")
    parser.add_argument("--workspace", metavar="PATH",
                        help="Repository-local workspace for mutable rerun results, manifests, and logs.")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"Condition workers (1-{MAX_SAFE_WORKERS}; default {DEFAULT_WORKERS}).")
    args = parser.parse_args(argv)
    if args.workers < 1 or args.workers > MAX_SAFE_WORKERS:
        parser.error(f"--workers must be between 1 and {MAX_SAFE_WORKERS}")
    configure_workspace(args.workspace)
    if not (REPO_ROOT / "known_visit_sim").is_dir():
        raise CampaignError(f"known_visit_sim not found under repository root {REPO_ROOT}")

    if args.plan_only:
        scenarios = validate_existing_scenarios()
        return plan_command(make_jobs(), scenarios)

    # Status must not generate scenarios or update manifests, so it cannot start
    # a duplicate process or mutate experiment state.
    if args.status:
        return status_command(make_jobs())
    scenarios = ensure_scenarios()
    jobs = make_jobs()
    if args.combine_only:
        combine_results(jobs, scenarios)
        validate_campaign(jobs, scenarios)
        return 0
    if args.validate_only:
        validate_campaign(jobs, scenarios)
        return 0
    return run_campaign(jobs, scenarios, args.workers)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CampaignError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
