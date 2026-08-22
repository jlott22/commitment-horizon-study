# Source and data provenance

The simulator source was copied from
[`jlott22/dcta_benchmark_sim`](https://github.com/jlott22/dcta_benchmark_sim).
The campaign manifest records source commit
`7e4cd8a3fef2fd815acfa9342f2ac0248a98fdd0`; the bundled `known_visit_sim/`
tree is byte-identical at later packaging commit
`5cac0ad0b30a8f2f5173ec8cbb7c5fb46bb77ff1`.

The 5- and 20-target outputs were generated as 25 paired trials per condition.
The duplicated 10-target reference contains the original 300 paired trials and
is used read-only by MATLAB. Source files in `dcta_benchmark_sim` were copied,
not linked, so this repository has no runtime dependency on the parent project.

Historical `scenario_file`, `out_dir`, `source_command`, and absolute-path
fields are retained verbatim as provenance. They are not expected to resolve
inside a new clone. Live scripts resolve paths relative to their own files.

The historical validation report has one external audit failure because files
elsewhere in the dirty parent repository changed while the pilot ran. That
audit is unrelated to campaign output integrity: the pilot completed 120/120
conditions, 3,000/3,000 trials, with zero failed trial records.
