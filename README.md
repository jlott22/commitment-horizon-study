# Commitment-Horizon Tuning Study

This standalone repository contains the simulator, allocator implementations,
scenarios, raw and combined results, statistical analysis, and publication
figures for the Collaborative Visit commitment-horizon target-load study.

The study evaluates ACBBA, DGA, DMCHBA, HIPC, and PI at commitment horizons
`1, 2, 3, 5, 8, 12`, under ideal communication and independent 25% packet
loss. New 25-trial campaigns at 5 and 20 targets are compared with the first
25 paired trials of the existing 300-trial, 10-target horizon campaign.

## Repository layout

```text
known_visit_sim/                complete CV simulator and allocators
scenarios/                      paired 5- and 20-target scenario inputs
scripts/                        campaign, smoke, and release validation tools
results/raw/                    all 120 published condition outputs
results/combined/               canonical 3,000-trial pilot outputs
reference_core_benchmark_pilot/ 10-target scenario, integrated results, and raw reruns
analysis/                       MATLAB analysis, tables, and figures
archive/                        pre-fix ACBBA/HIPC rollback data and hashes
manifests/                      historical campaign and validation provenance
logs/                           original per-condition execution logs
SOURCE_PROVENANCE.md            source and historical-path explanation
RELEASE_SHA256.csv              byte-level release inventory
```

Historical absolute paths in CSVs and manifests are provenance strings from
the original machine. They are not runtime dependencies. The historical
`preexisting_results_unchanged` failure records unrelated files changing in
the parent benchmark while this campaign ran; all 253 pilot-specific checks
passed and all 3,000 study trials completed successfully.

## Install

Python 3.10 or newer is supported. The simulator uses only the standard
library.

```bash
git clone https://github.com/jlott22/commitment-horizon-study.git
cd commitment-horizon-study
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# Windows PowerShell: .venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -e .
```

MATLAB R2025b with Statistics and Machine Learning Toolbox is recommended for
exact statistical regeneration because the analysis uses `signrank`.

## Verify the release

```bash
python scripts/verify_release.py
python -m unittest discover -s known_visit_sim/tests -v
python scripts/smoke_study.py
```

`verify_release.py` checks the SHA-256 inventory, condition counts, row counts,
trial completion, and reference-campaign structure. `smoke_study.py` executes
one temporary trial for every study allocator under both communication modes;
it does not write into the published results.

## Plan or rerun the 5/20-target study

Inspect the exact 120-condition, 3,000-run matrix without writing files:

```bash
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --plan-only
```

Run into an isolated workspace so the published results remain immutable:

```bash
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --workers 12
```

The command is resumable. Monitor, resume, combine, or validate with:

```bash
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --status
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --resume --workers 12
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --combine-only
python scripts/run_target_load_horizon_pilot.py --workspace rerun_workspace --validate-only
```

The 10-target suite supplies all 300 trials used by the paper analysis. Its
ACBBA and HIPC cells contain the completion-retention rerun; DGA, DMCHBA, and
PI retain their original results. The exact scenario, raw replacement outputs,
60-condition manifest, communication settings, and seed rule are included.

The previous ACBBA/HIPC cells are preserved under
`archive/pre_completion_retention_acbba_hipc/` with a separate SHA-256
inventory, so the pre-fix state can be reconstructed without affecting the
canonical integrated results.

## Regenerate MATLAB analysis and paper figures

These scripts resolve paths from their own locations and may be invoked from
any MATLAB working directory:

```matlab
run(fullfile('<clone>', 'analysis', 'analyze_target_load_horizon_pilot.m'))
run(fullfile('<clone>', 'analysis', 'build_commitment_tuning_paper_figures.m'))
```

The primary analysis writes eight CSV tables and five PNG/FIG figure pairs.
The paper builder writes the two IEEE single-column figures as editable FIG,
300-dpi PNG, and vector PDF files under `analysis/paper_figures/`.

## Reproducibility design

- Grid: 19 x 19; robots: 4; deterministic `edge_even` starts.
- Scenario IDs are paired across every algorithm, horizon, and communication
  cell within each target load.
- Simulator seed is `0 + trial_id * 1009` in every cell.
- DGA uses population 30 and 25 iterations per trigger.
- The historical event cap is explicitly fixed at 5,000.
- Failed trial records are retained and never silently redrawn on resume.

This project is released under the MIT License.
