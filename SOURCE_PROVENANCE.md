# Source and data provenance

The simulator source was copied from
[`jlott22/dcta_benchmark_sim`](https://github.com/jlott22/dcta_benchmark_sim).
The campaign manifest records source commit
`7e4cd8a3fef2fd815acfa9342f2ac0248a98fdd0`; the bundled `known_visit_sim/`
tree is byte-identical at later packaging commit
`5cac0ad0b30a8f2f5173ec8cbb7c5fb46bb77ff1`.

The 5- and 20-target outputs were generated as 25 paired trials per condition.
The 10-target reference contains the original 300 paired scenarios and is used
read-only by MATLAB. Its ACBBA and HIPC result cells were regenerated with the
completion-retention correction on 2026-08-22; PI retains its original rows.
Source files in `dcta_benchmark_sim` were copied,
not linked, so this repository has no runtime dependency on the parent project.

Historical `scenario_file`, `out_dir`, `source_command`, and absolute-path
fields are retained verbatim as provenance. They are not expected to resolve
inside a new clone. Live scripts resolve paths relative to their own files.

The initial five-algorithm launch completed 120 conditions and 3,000 trials
with zero failed records. This paper release intentionally retains only the
ACBBA, HIPC, and PI cells: 72 conditions and 1,800 trials at 5/20 targets, plus
36 conditions and 10,800 trials in the 10-target reference. The prior broader
state remains available in Git history.
