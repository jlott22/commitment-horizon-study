#!/usr/bin/env python3
"""Validate published study structure and its SHA-256 release inventory."""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "RELEASE_SHA256.csv"
EXCLUDED_PARTS = {".git", "__pycache__", ".pytest_cache", "rerun_workspace", ".venv"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def release_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path == MANIFEST:
            continue
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDED_PARTS or part.endswith(".egg-info") for part in relative.parts):
            continue
        if path.suffix.lower() in {".pyc", ".pyo"}:
            continue
        files.append(path)
    return sorted(files, key=lambda item: item.relative_to(ROOT).as_posix())


def write_manifest() -> None:
    with MANIFEST.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["path", "size_bytes", "sha256"])
        writer.writeheader()
        for path in release_files():
            writer.writerow({
                "path": path.relative_to(ROOT).as_posix(),
                "size_bytes": path.stat().st_size,
                "sha256": digest(path),
            })


def rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def verify_inventory() -> None:
    require(MANIFEST.is_file(), f"Missing release inventory: {MANIFEST}")
    expected_rows = rows(MANIFEST)
    expected = {item["path"]: (int(item["size_bytes"]), item["sha256"]) for item in expected_rows}
    current_files = release_files()
    current_paths = {path.relative_to(ROOT).as_posix() for path in current_files}
    require(set(expected) == current_paths, "Release inventory file set does not match checkout")
    for path in current_files:
        relative = path.relative_to(ROOT).as_posix()
        size, sha = expected[relative]
        require(path.stat().st_size == size, f"Size mismatch: {relative}")
        require(digest(path) == sha, f"SHA-256 mismatch: {relative}")


def verify_study_data() -> None:
    pilot = ROOT / "results" / "combined"
    pilot_conditions = rows(pilot / "target_load_horizon_pilot_25_combined_condition_manifest.csv")
    pilot_system = rows(pilot / "target_load_horizon_pilot_25_combined_system_performance.csv")
    pilot_trials = rows(pilot / "target_load_horizon_pilot_25_combined_trial_summary.csv")
    require(len(pilot_conditions) == 120, f"Pilot condition count is {len(pilot_conditions)}, expected 120")
    require(len(pilot_system) == 3000, f"Pilot system rows are {len(pilot_system)}, expected 3000")
    require(len(pilot_trials) == 3000, f"Pilot trial rows are {len(pilot_trials)}, expected 3000")
    require(all(item.get("trial_status", "completed").lower() == "completed" for item in pilot_trials),
            "Pilot contains non-completed trial records")
    require({int(item["target_count"]) for item in pilot_system} == {5, 20},
            "Pilot target loads are not exactly 5 and 20")
    pilot_keys = {(item["run_id"], int(item["trial_id"])) for item in pilot_system}
    require(len(pilot_keys) == 3000, "Pilot contains duplicate run_id/trial_id rows")

    reference = ROOT / "reference_core_benchmark_pilot" / "combined"
    reference_conditions = rows(reference / "sensitivity_known_target_visit_horizon_300_combined_condition_manifest.csv")
    reference_system = rows(reference / "sensitivity_known_target_visit_horizon_300_combined_system_performance.csv")
    require(len(reference_conditions) == 60,
            f"Reference condition count is {len(reference_conditions)}, expected 60")
    require(len(reference_system) == 18000,
            f"Reference system rows are {len(reference_system)}, expected 18000")
    require(all(item.get("trial_status", "completed").lower() == "completed" for item in reference_system),
            "Reference campaign contains non-completed trials")
    reference_keys = {(item["run_id"], int(item["trial_id"])) for item in reference_system}
    require(len(reference_keys) == 18000, "Reference contains duplicate run_id/trial_id rows")

    validation = rows(ROOT / "analysis" / "tables" / "pilot_analysis_validation.csv")
    require(len(validation) == 26, f"MATLAB validation has {len(validation)} rows, expected 26")
    require(all(item["status"] == "PASS" for item in validation), "MATLAB analysis validation is not all PASS")
    report = (ROOT / "analysis" / "paper_figures" / "figure_generation_validation.txt").read_text(
        encoding="utf-8"
    )
    require("Warnings: none" in report, "Paper-figure validation contains warnings")
    require("core_rows=18000" in report and "target_load_penalty_rows=30" in report,
            "Paper-figure validation is incomplete")

    require(not (ROOT / "quarantine").exists(), "Quarantine directory remains after integration")
    integrated_pilot = [item for item in pilot_system
                        if item.get("algorithm") in {"ACBBA", "HIPC"}]
    integrated_reference = [item for item in reference_system
                            if item.get("algorithm") in {"ACBBA", "HIPC"}]
    require(len(integrated_pilot) == 1200 and all(
        item.get("stage") == "completion_retention_integrated" for item in integrated_pilot),
        "Integrated 5/20-target ACBBA/HIPC rows are incomplete")
    require(len(integrated_reference) == 7200 and all(
        item.get("stage") == "completion_retention_integrated" for item in integrated_reference),
        "Integrated 10-target ACBBA/HIPC rows are incomplete")

    integrated_raw = list((ROOT / "results" / "raw").rglob("config_used.json"))
    integrated_reference_raw = list((ROOT / "reference_core_benchmark_pilot" / "raw").rglob("config_used.json"))
    require(sum("acbba" in path.parent.name or "hipc" in path.parent.name
                for path in integrated_raw) == 48,
            "Integrated 5/20-target raw condition count is not 48")
    require(len(integrated_reference_raw) == 24,
            "Integrated 10-target raw condition count is not 24")

    archive = ROOT / "archive" / "pre_completion_retention_acbba_hipc"
    archive_inventory = rows(archive / "SHA256.csv")
    for item in archive_inventory:
        path = archive / item["path"]
        require(path.is_file(), f"Archived file missing: {item['path']}")
        require(path.stat().st_size == int(item["size_bytes"]),
                f"Archived size mismatch: {item['path']}")
        require(digest(path) == item["sha256"], f"Archived hash mismatch: {item['path']}")
    archive_pilot = rows(
        archive / "target_load_5_20" / "combined" /
        "target_load_horizon_pilot_25_combined_system_performance.csv")
    archive_reference = rows(
        archive / "reference_10" / "combined" /
        "sensitivity_known_target_visit_horizon_300_combined_system_performance.csv")
    require(len(archive_pilot) == 1200 and len(archive_reference) == 7200,
            "Archived pre-integration system rows are incomplete")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="Rebuild RELEASE_SHA256.csv")
    args = parser.parse_args()
    if args.write:
        write_manifest()
        print(f"Wrote {MANIFEST}")
    verify_study_data()
    verify_inventory()
    print("Release verification PASS: hashes, 120/3000 pilot, 60/18000 reference, MATLAB checks")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Release verification FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
