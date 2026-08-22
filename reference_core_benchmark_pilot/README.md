# Integrated 10-target benchmark

This directory contains the 10-target known-target horizon benchmark used by
the study. ACBBA and HIPC were rerun after the completion-retention correction;
DGA, DMCHBA, and PI retain their original results.

Contents:

- `known_visit_10target_300.csv` — the original 300-trial paired scenario.
- `raw/` — all 24 integrated ACBBA/HIPC condition outputs.
- `combined/` — the integrated 60-condition trial, system, robot, and target
  performance CSVs.

The MATLAB pilot analysis uses IDs 0–24. The prior ACBBA/HIPC combined rows are
preserved under `archive/pre_completion_retention_acbba_hipc/reference_10/`.
