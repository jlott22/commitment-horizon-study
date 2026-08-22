# Duplicated 10-target reference benchmark

This directory is a read-only duplicate of the exact existing 10-target
known-target horizon benchmark used by the horizon-tuning conference pilot.
It is included so the MATLAB analysis can run without reading or changing the
main benchmark result tree.

Contents:

- `known_visit_10target_300.csv` — the original 300-trial paired scenario.
- `combined/` — the original condition manifest and trial, system, robot, and
  target performance CSVs from
  `results/sensitivity_known_target_visit_horizon_300/combined/`.

The pilot analysis uses IDs 0–24 from these duplicated files. The canonical
source files in the main benchmark repository have not been moved, removed,
or edited.
