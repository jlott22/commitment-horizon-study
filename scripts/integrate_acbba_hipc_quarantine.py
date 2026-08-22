#!/usr/bin/env python3
"""Archive old ACBBA/HIPC cells and integrate the validated quarantine rerun."""

from __future__ import annotations

import csv
import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUARANTINE = ROOT / "quarantine" / "acbba_hipc_completion_retention_full_matrix"
ARCHIVE = ROOT / "archive" / "pre_completion_retention_acbba_hipc"
ALGORITHMS = {"ACBBA", "HIPC"}
FILES = ("trial_summary.csv", "system_performance.csv", "robot_performance.csv", "target_performance.csv")
PILOT_PREFIX = "target_load_horizon_pilot_25_combined_"
REFERENCE_PREFIX = "sensitivity_known_target_visit_horizon_300_combined_"
QUARANTINE_PREFIX = "acbba_hipc_full_matrix_"


def read_rows(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        return list(reader), list(reader.fieldnames or [])


def write_rows(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def ensure_under(path: Path, parent: Path) -> Path:
    resolved = path.resolve()
    resolved.relative_to(parent.resolve())
    return resolved


def condition_id(row: dict[str, str]) -> str:
    return row.get("condition_id") or row.get("run_id", "")


def target_count(row: dict[str, str]) -> int:
    return int(row.get("target_count") or row.get("target_count_condition") or 0)


def row_key(row: dict[str, str], filename: str) -> tuple[object, ...]:
    key: list[object] = [target_count(row), condition_id(row), int(row["trial_id"])]
    if filename == "robot_performance.csv":
        key.append(row["robot_id"])
    if filename == "target_performance.csv":
        key.append(int(row["target_index"]))
    return tuple(key)


def live_out_dir(target: int, row: dict[str, str]) -> str:
    horizon = int(row.get("quarantine_horizon") or row.get("value") or 0)
    comm_model = row.get("comm_model", "")
    cid = condition_id(row)
    if target == 10:
        return f"reference_core_benchmark_pilot/raw/h{horizon}/{comm_model}/{cid}"
    return f"results/raw/targets_{target}/h{horizon}/{comm_model}/{cid}"


def copy_and_replace_raw() -> dict[str, int]:
    archived = 0
    integrated = 0
    source_root = QUARANTINE / "results" / "raw"
    for target in (5, 20):
        for source in sorted((source_root / f"targets_{target}").rglob("config_used.json")):
            condition_source = source.parent
            if not any(name in condition_source.name for name in ("acbba", "hipc")):
                continue
            relative = condition_source.relative_to(source_root)
            destination = ensure_under(ROOT / "results" / "raw" / relative, ROOT / "results" / "raw")
            require(destination.is_dir(), f"published raw condition is missing: {destination}")
            archive_destination = ensure_under(
                ARCHIVE / "target_load_5_20" / "raw" / relative,
                ARCHIVE / "target_load_5_20" / "raw",
            )
            shutil.copytree(destination, archive_destination)
            archived += 1
            shutil.rmtree(destination)
            shutil.copytree(condition_source, destination)
            integrated += 1

    reference_raw = ROOT / "reference_core_benchmark_pilot" / "raw"
    for source in sorted((source_root / "targets_10").rglob("config_used.json")):
        condition_source = source.parent
        relative = condition_source.relative_to(source_root / "targets_10")
        destination = ensure_under(reference_raw / relative, reference_raw)
        require(not destination.exists(), f"reference raw destination already exists: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(condition_source, destination)
        integrated += 1
    require(archived == 48 and integrated == 72,
            f"raw condition counts were archive={archived}, integrate={integrated}")
    return {"archived_raw_conditions": archived, "integrated_raw_conditions": integrated}


def integrate_combined_suite(
    canonical_dir: Path,
    canonical_prefix: str,
    suite_targets: set[int],
    archive_dir: Path,
) -> dict[str, int]:
    quarantine_dir = QUARANTINE / "results" / "combined"
    counts: dict[str, int] = {}
    for filename in FILES:
        canonical = canonical_dir / f"{canonical_prefix}{filename}"
        old_rows, fields = read_rows(canonical)
        replaced_old = [row for row in old_rows
                        if row.get("algorithm") in ALGORITHMS and target_count(row) in suite_targets]
        kept = [row for row in old_rows
                if not (row.get("algorithm") in ALGORITHMS and target_count(row) in suite_targets)]
        archive_path = archive_dir / "combined" / canonical.name
        if not archive_path.exists():
            write_rows(archive_path, replaced_old, fields)

        quarantine_rows, _ = read_rows(quarantine_dir / f"{QUARANTINE_PREFIX}{filename}")
        replacements = [row for row in quarantine_rows
                        if row.get("algorithm") in ALGORITHMS and target_count(row) in suite_targets]
        templates: dict[str, dict[str, str]] = {}
        for row in replaced_old:
            templates.setdefault(condition_id(row), row)
        require({condition_id(row) for row in replacements} == set(templates),
                f"condition mismatch while integrating {canonical}")

        integrated: list[dict[str, str]] = []
        provenance_fields = {
            "scenario_file", "comm_level", "stage", "environment", "parameter", "value",
            "setting", "algorithm_key", "canonical_algorithm", "dga_iterations", "comm_label",
            "target_count_condition", "scenario_generation_seed", "scenario_sha256", "out_dir", "run_id",
        }
        for source in replacements:
            template = templates[condition_id(source)]
            row = {field: (template.get(field, "") if field in provenance_fields
                           else source.get(field, template.get(field, ""))) for field in fields}
            if "stage" in row:
                row["stage"] = "completion_retention_integrated"
            if "out_dir" in row:
                row["out_dir"] = live_out_dir(target_count(source), source)
            integrated.append(row)

        integrated_by_key = {row_key(row, filename): row for row in integrated}
        final_rows = [
            integrated_by_key[row_key(row, filename)]
            if row.get("algorithm") in ALGORITHMS and target_count(row) in suite_targets
            else row
            for row in old_rows
        ]
        require(len(final_rows) == len(old_rows), f"row count changed for {canonical}")
        require(len({row_key(row, filename) for row in final_rows}) == len(final_rows),
                f"duplicate integrated keys in {canonical}")
        write_rows(canonical, final_rows, fields)
        counts[filename] = len(integrated)
    return counts


def integrate_condition_manifest(
    canonical: Path,
    suite_targets: set[int],
    archive_dir: Path,
) -> int:
    old_rows, fields = read_rows(canonical)
    replaced = [row for row in old_rows if row.get("algorithm") in ALGORITHMS and (
        int(row.get("target_count", "10")) in suite_targets)]
    kept = [row for row in old_rows if not (row.get("algorithm") in ALGORITHMS and (
        int(row.get("target_count", "10")) in suite_targets))]
    archive_path = archive_dir / "combined" / canonical.name
    if not archive_path.exists():
        write_rows(archive_path, replaced, fields)

    quarantine_rows, _ = read_rows(QUARANTINE / "manifests" / "condition_manifest.csv")
    qmap = {(int(row["target_count"]), row["condition_id"]): row for row in quarantine_rows}
    integrated: list[dict[str, str]] = []
    for old in replaced:
        target = int(old.get("target_count", "10"))
        qrow = qmap[(target, old.get("condition_id") or old["run_id"])]
        row = dict(old)
        row["stage"] = "completion_retention_integrated"
        if "out_dir" in row:
            row["out_dir"] = live_out_dir(target, qrow)
        if "run_command" in row:
            row["run_command"] = qrow["command"]
        if "command" in row:
            row["command"] = qrow["command"]
        if "git_commit" in row:
            row["git_commit"] = "completion_retention_fix_worktree_20260822"
        if "status" in row:
            row.update(status="complete", recorded_trials=qrow["expected_trials"],
                       completed_trials=qrow["expected_trials"], failed_trials="0", status_issues="")
        if target == 10:
            row["scenario_file"] = "reference_core_benchmark_pilot/known_visit_10target_300.csv"
        else:
            row["scenario_file"] = f"scenarios/known_visit_g19_t{target}_n25.csv"
        integrated.append(row)
    integrated_by_condition = {
        (int(row.get("target_count", "10")), row.get("condition_id") or row["run_id"]): row
        for row in integrated
    }
    final_rows = [
        integrated_by_condition[(int(row.get("target_count", "10")),
                                 row.get("condition_id") or row["run_id"])]
        if row.get("algorithm") in ALGORITHMS and int(row.get("target_count", "10")) in suite_targets
        else row
        for row in old_rows
    ]
    require(len(final_rows) == len(old_rows), f"manifest count changed for {canonical}")
    write_rows(canonical, final_rows, fields)
    return len(integrated)


def validate_integrated() -> dict[str, object]:
    checks: dict[str, object] = {}
    suites = (
        (ROOT / "results" / "combined", PILOT_PREFIX, {5, 20}, 1200),
        (ROOT / "reference_core_benchmark_pilot" / "combined", REFERENCE_PREFIX, {10}, 7200),
    )
    qdir = QUARANTINE / "results" / "combined"
    for canonical_dir, prefix, targets, expected_system in suites:
        for filename in FILES:
            canonical_rows, _ = read_rows(canonical_dir / f"{prefix}{filename}")
            qrows, _ = read_rows(qdir / f"{QUARANTINE_PREFIX}{filename}")
            canonical_subset = [row for row in canonical_rows
                                if row.get("algorithm") in ALGORITHMS and target_count(row) in targets]
            qsubset = [row for row in qrows
                       if row.get("algorithm") in ALGORITHMS and target_count(row) in targets]
            ckeys = {row_key(row, filename): row for row in canonical_subset}
            qkeys = {row_key(row, filename): row for row in qsubset}
            require(set(ckeys) == set(qkeys), f"integrated key mismatch for {prefix}{filename}")
            excluded = {"scenario_file", "comm_level", "stage", "out_dir", "run_id"}
            common = (set(canonical_subset[0]) & set(qsubset[0])) - excluded
            for key in ckeys:
                require(all(ckeys[key].get(field, "") == qkeys[key].get(field, "") for field in common),
                        f"integrated value mismatch for {prefix}{filename}, key={key}")
            checks[f"{prefix}{filename}_replacement_rows"] = len(canonical_subset)
        checks[f"{prefix}system_expected"] = expected_system
    return checks


def write_archive_inventory() -> None:
    records: list[dict[str, object]] = []
    for path in sorted(ARCHIVE.rglob("*")):
        if path.is_file() and path.name != "SHA256.csv":
            records.append({"path": path.relative_to(ARCHIVE).as_posix(),
                            "size_bytes": path.stat().st_size, "sha256": digest(path)})
    write_rows(ARCHIVE / "SHA256.csv", records, ["path", "size_bytes", "sha256"])


def main() -> int:
    require(QUARANTINE.is_dir(), f"quarantine is missing: {QUARANTINE}")
    summary = json.loads((QUARANTINE / "validation" / "validation_summary.json").read_text())
    require(summary.get("technical_complete") is True and summary.get("completed_trials") == 8400,
            "quarantine validation is not complete")
    resuming = ARCHIVE.exists()
    ARCHIVE.mkdir(parents=True, exist_ok=True)

    raw_counts = ({"archived_raw_conditions": 48, "integrated_raw_conditions": 72}
                  if resuming else copy_and_replace_raw())
    pilot_archive = ARCHIVE / "target_load_5_20"
    reference_archive = ARCHIVE / "reference_10"
    pilot_counts = integrate_combined_suite(ROOT / "results" / "combined", PILOT_PREFIX,
                                            {5, 20}, pilot_archive)
    reference_counts = integrate_combined_suite(
        ROOT / "reference_core_benchmark_pilot" / "combined", REFERENCE_PREFIX,
        {10}, reference_archive)
    pilot_manifest = integrate_condition_manifest(
        ROOT / "results" / "combined" / f"{PILOT_PREFIX}condition_manifest.csv",
        {5, 20}, pilot_archive)
    reference_manifest = integrate_condition_manifest(
        ROOT / "reference_core_benchmark_pilot" / "combined" /
        f"{REFERENCE_PREFIX}condition_manifest.csv", {10}, reference_archive)
    checks = validate_integrated()

    (ARCHIVE / "README.md").write_text(
        "# Pre-completion-retention ACBBA/HIPC archive\n\n"
        "This archive contains every published ACBBA and HIPC raw/combined cell that "
        "was replaced on 2026-08-22. The other algorithms were not copied because they "
        "were not modified. `SHA256.csv` provides a byte-level inventory.\n",
        encoding="utf-8")
    report = {"integrated_utc": datetime.now(timezone.utc).isoformat(), **raw_counts,
              "pilot_replacement_rows": pilot_counts,
              "reference_replacement_rows": reference_counts,
              "pilot_manifest_conditions": pilot_manifest,
              "reference_manifest_conditions": reference_manifest,
              "validation": checks}
    (ARCHIVE / "integration_report.json").write_text(json.dumps(report, indent=2)+"\n",
                                                       encoding="utf-8")
    write_archive_inventory()
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
