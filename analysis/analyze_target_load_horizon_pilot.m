% ANALYZE_TARGET_LOAD_HORIZON_PILOT
% Exploratory 25-trial target-load pilot for known-target Collaborative Visit.
%
% This script is intentionally self-contained: it resolves every path from
% its own location, reads the existing 10-target campaign without modifying
% it, and writes every analysis artifact only beneath this pilot's analysis
% directory.  Run from any MATLAB working directory with, for example:
%
%   run(fullfile('<repo>', 'horizon tuning conference', ...
%       'analysis', 'analyze_target_load_horizon_pilot.m'))
%
% The analysis is exploratory.  The same paired scenarios are used to form
% response surfaces and choose horizons, so inferential output is labelled as
% pilot/exploratory rather than held-out confirmatory evidence.

%% Stage 0: paths, fixed design, and active-paper appearance
scriptDir = fileparts(mfilename('fullpath'));
experimentRoot = fileparts(scriptDir);
repoRoot = experimentRoot;
tablesDir = fullfile(scriptDir, 'tables');
figuresDir = fullfile(scriptDir, 'figures');
helpersDir = fullfile(scriptDir, 'helpers');
if ~isfolder(tablesDir), mkdir(tablesDir); end
if ~isfolder(figuresDir), mkdir(figuresDir); end
if ~isfolder(helpersDir)
    error('Pilot helper directory is missing: %s', helpersDir);
end
addpath(helpersDir);

assert(startsWith(string(tablesDir), string(experimentRoot)), ...
    'Refusing to write tables outside the pilot experiment folder.');
assert(startsWith(string(figuresDir), string(experimentRoot)), ...
    'Refusing to write figures outside the pilot experiment folder.');

style = loadPilotFigureStyle(repoRoot);
targetCounts = [5, 10, 20];
horizons = [1, 2, 3, 5, 8, 12];
nonOneHorizons = [2, 3, 5, 8, 12];
algorithms = ["ACBBA", "HIPC", "PI"];
commLabels = ["ideal", "bernoulli_025"];
bootstrapIterations = 10000;
bootstrapSeed = 20260821;
rng(bootstrapSeed, 'twister');

metricDefs = pilotMetricDefinitions();
validation = emptyValidationTable();
validation = addValidation(validation, "analysis_scope", true, ...
    "exploratory pilot", "exploratory pilot", ...
    "The same 25 paired scenarios estimate response surfaces and select horizons.");
validation = addValidation(validation, "bootstrap_configuration", true, ...
    "10,000 paired resamples; Twister seed 20260821", ...
    sprintf('%d paired resamples; Twister seed %d', bootstrapIterations, bootstrapSeed), ...
    "Matches the active DCTA 10,000-resample, reproducible-bootstrap convention.");

%% Stage 1: locate and normalize the two new pilot datasets
pilotCombinedDir = fullfile(experimentRoot, 'results', 'combined');
if ~isfolder(pilotCombinedDir)
    error(['Missing pilot combined-results directory: %s. Run the pilot combination ' ...
        'and validation step before executing this MATLAB analysis.'], pilotCombinedDir);
end

[pilotSystemRaw, pilotSystemFiles] = readPilotCombinedKind(pilotCombinedDir, 'system_performance');
[pilotRobotRaw, pilotRobotFiles] = readPilotCombinedKind(pilotCombinedDir, 'robot_performance');
[pilotTargetRaw, pilotTargetFiles] = readPilotCombinedKind(pilotCombinedDir, 'target_performance');

pilotSystem = normalizeSystemTable(pilotSystemRaw, "pilot combined system performance");
pilotRobot = normalizeRobotTable(pilotRobotRaw, "pilot combined robot performance");
pilotTarget = normalizeTargetTable(pilotTargetRaw, "pilot combined target performance");

%% Stage 2: load existing 10-target campaign read-only and retain 25 pairs
legacyCombinedDir = fullfile(experimentRoot, 'reference_core_benchmark_pilot', ...
    'combined');
legacySystemFile = resolveLegacyCombinedFile(legacyCombinedDir, ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv', ...
    'system_performance');
legacyRobotFile = resolveLegacyCombinedFile(legacyCombinedDir, ...
    'sensitivity_known_target_visit_horizon_300_combined_robot_performance.csv', ...
    'robot_performance');
legacyTargetFile = resolveLegacyCombinedFile(legacyCombinedDir, ...
    'sensitivity_known_target_visit_horizon_300_combined_target_performance.csv', ...
    'target_performance');

legacySystem = normalizeSystemTable(readCsvPreserve(legacySystemFile), ...
    "existing 10-target system performance");
legacyRobot = normalizeRobotTable(readCsvPreserve(legacyRobotFile), ...
    "existing 10-target robot performance");
legacyTarget = normalizeTargetTable(readCsvPreserve(legacyTargetFile), ...
    "existing 10-target target performance");

%% Stage 3: enforce complete paired blocks and derive robot-level mechanisms
datasets = struct('targetCount', {}, 'system', {}, 'robot', {}, 'target', {}, ...
    'retainedTrialIds', {}, 'sourceDescription', {});

[datasets(1), validation] = prepareDataset( ...
    pilotSystem, pilotRobot, pilotTarget, 5, false, horizons, algorithms, commLabels, validation, ...
    strjoin(pilotSystemFiles, '; '));
[datasets(2), validation] = prepareDataset( ...
    legacySystem, legacyRobot, legacyTarget, 10, true, horizons, algorithms, commLabels, validation, ...
    string(legacySystemFile));
[datasets(3), validation] = prepareDataset( ...
    pilotSystem, pilotRobot, pilotTarget, 20, false, horizons, algorithms, commLabels, validation, ...
    strjoin(pilotSystemFiles, '; '));

allSystem = vertcat(datasets.system);
allRobot = vertcat(datasets.robot);
allTarget = vertcat(datasets.target);

expectedSystemRows = numel(targetCounts) * numel(algorithms) * numel(commLabels) * numel(horizons) * 25;
validation = addValidation(validation, "retained_system_row_count", ...
    height(allSystem) == expectedSystemRows, string(expectedSystemRows), string(height(allSystem)), ...
    "Three target loads × three algorithms × two communications × six horizons × 25 paired trials.");
validation = addValidation(validation, "retained_robot_row_count", ...
    height(allRobot) == expectedSystemRows * 4, string(expectedSystemRows * 4), string(height(allRobot)), ...
    "Four robot rows are required for every retained system trial.");
validation = addValidation(validation, "retained_target_row_count", ...
    height(allTarget) == 25 * numel(algorithms) * numel(commLabels) * numel(horizons) * sum(targetCounts), ...
    string(25 * numel(algorithms) * numel(commLabels) * numel(horizons) * sum(targetCounts)), ...
    string(height(allTarget)), "Every retained system trial must include its declared target count.");

requiredFiniteFields = ["total_team_steps", "max_robot_steps", "final_completion_time"];
for field = requiredFiniteFields
    values = allSystem.(field);
    validation = addValidation(validation, "finite_required_metric_" + field, ...
        all(isfinite(values)), "all retained values finite", ...
        sprintf('%d/%d finite', sum(isfinite(values)), numel(values)), ...
        "Required primary metric values must be finite for all complete paired trials.");
end

if any(validation.status == "FAIL")
    writetable(validation, fullfile(tablesDir, 'pilot_analysis_validation.csv'));
    error('Pilot input validation failed. See %s for the recorded checks.', ...
        fullfile(tablesDir, 'pilot_analysis_validation.csv'));
end

%% Stage 4: transparent equal-communication horizon selection and stability
% For every trial and horizon, ideal and Bernoulli-0.25 outcomes are first
% averaged with equal weight.  Means over these balanced trial values select
% the horizon. This is the same normalization used by the existing transparent
% practical-sensitivity horizon analysis.
[selectionTable, stabilityTable] = makeHorizonSelections( ...
    allSystem, targetCounts, algorithms, horizons, nonOneHorizons, ...
    bootstrapIterations);
selectionTable.analysis_scope = repmat( ...
    "pilot/exploratory; selected on the same 25 paired scenarios summarized here", ...
    height(selectionTable), 1);
stabilityTable.analysis_scope = repmat( ...
    "pilot/exploratory bootstrap stability; not held-out selection validation", ...
    height(stabilityTable), 1);

%% Stage 5: objective-transfer effects, paired inference, and mechanisms
[transferTable, statisticalTable, transferSamples] = makeTransferAnalysis( ...
    allSystem, selectionTable, targetCounts, algorithms, commLabels, metricDefs, ...
    bootstrapIterations);
independentTable = makeIndependentTargetLoadComparisons( ...
    transferSamples, targetCounts, algorithms, commLabels, bootstrapIterations);
statisticalTable = [statisticalTable; independentTable];
statisticalTable.analysis_scope = repmat( ...
    "pilot/exploratory; no held-out confirmation because the response surface selected the horizons", ...
    height(statisticalTable), 1);
mechanismTable = makeMechanismTable(transferTable);
rankingTable = makeAlgorithmRankings(allSystem, selectionTable, ...
    targetCounts, algorithms, commLabels);
conditionSummary = makeConditionSummary(allSystem, targetCounts, algorithms, ...
    commLabels, horizons, metricDefs);

%% Stage 6: tabular outputs (all generated only inside this pilot folder)
writetable(conditionSummary, fullfile(tablesDir, 'pilot_condition_summary.csv'));
writetable(selectionTable, fullfile(tablesDir, 'pilot_horizon_selections.csv'));
writetable(stabilityTable, fullfile(tablesDir, 'pilot_horizon_selection_stability.csv'));
writetable(transferTable, fullfile(tablesDir, 'pilot_objective_transfer_penalties.csv'));
writetable(statisticalTable, fullfile(tablesDir, 'pilot_statistical_tests.csv'));
writetable(mechanismTable, fullfile(tablesDir, 'pilot_mechanism_metrics.csv'));
writetable(rankingTable, fullfile(tablesDir, 'pilot_algorithm_rankings.csv'));

validation = addValidation(validation, "pilot_source_system_files", true, ...
    ">= 1 pilot combined file", string(numel(pilotSystemFiles)), ...
    "Pilot source files were read only from this repository's results/combined directory.");
validation = addValidation(validation, "existing_10_target_source", isfile(legacySystemFile), ...
    string(legacySystemFile), string(legacySystemFile), ...
    "Existing 10-target horizon results were read only; this analysis never writes in their directory.");
validation = addValidation(validation, "table_output_location", true, ...
    string(tablesDir), string(tablesDir), "All CSV outputs are inside this pilot analysis directory.");
writetable(validation, fullfile(tablesDir, 'pilot_analysis_validation.csv'));

%% Stage 7: publication-style figures (600 dpi PNG plus editable FIG)
plotHorizonResponses(conditionSummary, targetCounts, algorithms, commLabels, horizons, ...
    "total_team_steps", "Total team steps", ...
    "Total team steps versus commitment horizon", ...
    fullfile(figuresDir, 'pilot_total_team_steps_by_horizon'), style);
plotHorizonResponses(conditionSummary, targetCounts, algorithms, commLabels, horizons, ...
    "max_robot_steps", "Makespan (maximum robot steps)", ...
    "Makespan versus commitment horizon", ...
    fullfile(figuresDir, 'pilot_makespan_by_horizon'), style);
plotMakespanPenalty(transferTable, targetCounts, algorithms, commLabels, ...
    fullfile(figuresDir, 'pilot_makespan_transfer_penalty'), style);
plotMechanismChanges(mechanismTable, targetCounts, algorithms, commLabels, ...
    fullfile(figuresDir, 'pilot_mechanism_changes'), style);
plotAlgorithmRankings(rankingTable, targetCounts, algorithms, commLabels, ...
    fullfile(figuresDir, 'pilot_algorithm_rankings'), style);

fprintf('\nPilot target-load horizon analysis complete.\n');
fprintf('  Tables:  %s\n', tablesDir);
fprintf('  Figures: %s\n', figuresDir);
fprintf(['  Interpretation: exploratory pilot only; horizon-selection and transfer ' ...
    'estimates use the same paired scenarios.\n']);

%% Local functions
function style = loadPilotFigureStyle(repoRoot)
    activeAnalysisDir = fullfile(repoRoot, 'results', 'analysis');
    if isfile(fullfile(activeAnalysisDir, 'final_figure_style.m'))
        addpath(activeAnalysisDir);
        style = final_figure_style();
    else
        % Fallback preserves the active paper's frozen numerical defaults.
        style.algorithmKeys = ["CBAA", "ACBBA", "PI", "HIPC", "DMCHBA", "DGA"];
        style.algorithmKeysLower = lower(style.algorithmKeys);
        style.algorithmLabels = style.algorithmKeys;
        style.colors = lines(6);
        style.markers = repmat({'o'}, 1, 6);
        style.publicationFontSize = 8.0;
        style.axesFontSize = 8.0;
        style.titleFontSize = 8.0;
        style.legendFontSize = 8.0;
        style.lineWidth = 0.95;
        style.axisLineWidth = 0.65;
        style.markerSize = 3.8;
        style.exportDpi = 600;
        style.zeroColor = [0.45, 0.45, 0.45];
        style.gridAlpha = 0.16;
    end
end

function metricDefs = pilotMetricDefinitions()
    metricDefs = struct( ...
        'key', { ...
            "total_team_steps", "max_robot_steps", "final_completion_time", ...
            "target_workload_gini", "movement_workload_gini", ...
            "active_robot_count", "max_target_workload", ...
            "max_individual_steps", "allocation_messages", "total_messages", ...
            "allocator_time_ms"}, ...
        'display', { ...
            "Total team steps", "Makespan (maximum robot steps)", ...
            "Final simulated mission-completion time (s)", ...
            "Target-workload Gini", "Movement-workload Gini", ...
            "Active robots completing at least one target", ...
            "Maximum target workload on one robot", ...
            "Maximum individual movement workload (steps)", ...
            "Allocation messages", "Total messages", ...
            "Allocator computation time (ms)"}, ...
        'required', {true, true, false, false, false, false, false, false, false, false, false});
end

function [raw, files] = readPilotCombinedKind(combinedDir, kind)
    if ~isfolder(combinedDir)
        error('Missing pilot combined directory: %s', combinedDir);
    end
    candidates = dir(fullfile(combinedDir, '**', ['*' kind '*.csv']));
    candidates = candidates(~[candidates.isdir]);
    if isempty(candidates)
        error(['Missing pilot %s CSV below %s. Expected a combined file whose name ' ...
            'contains "%s".'], kind, combinedDir, kind);
    end
    fullNames = string(fullfile({candidates.folder}, {candidates.name}));
    fullNames = sort(unique(fullNames));
    raw = table();
    for i = 1:numel(fullNames)
        next = readCsvPreserve(fullNames(i));
        if isempty(raw)
            raw = next;
        else
            try
                raw = [raw; next]; %#ok<AGROW>
            catch err
                error(['Pilot %s files have incompatible column sets. Combine them using ' ...
                    'one canonical schema before analysis. File %s caused: %s'], ...
                    kind, fullNames(i), err.message);
            end
        end
    end
    files = fullNames;
end

function file = resolveLegacyCombinedFile(combinedDir, expectedName, kind)
    expected = fullfile(combinedDir, expectedName);
    if isfile(expected)
        file = expected;
        return;
    end
    candidates = dir(fullfile(combinedDir, ['*' kind '*.csv']));
    candidates = candidates(~[candidates.isdir]);
    if numel(candidates) ~= 1
        error(['Could not resolve the existing 10-target %s combined CSV in %s. ' ...
            'Expected %s or exactly one matching fallback file.'], ...
            kind, combinedDir, expectedName);
    end
    file = fullfile(candidates(1).folder, candidates(1).name);
end

function T = readCsvPreserve(path)
    if ~isfile(path)
        error('Required input CSV is missing: %s', path);
    end
    options = detectImportOptions(path, 'Delimiter', ',', 'TextType', 'string', ...
        'VariableNamingRule', 'preserve', 'VariableNamesLine', 1);
    options.DataLines = [2, Inf];
    T = readtable(path, options);
    if isempty(T.Properties.VariableNames)
        error('Input CSV has no readable header: %s', path);
    end
end

function S = normalizeSystemTable(T, sourceLabel)
    sourceLabel = string(sourceLabel);
    requireColumns(T, ["trial_id", "algorithm", "comm_model"], sourceLabel);
    trialId = numericColumn(T, ["trial_id"], true, sourceLabel);
    algorithm = algorithmColumn(T, sourceLabel);
    communication = commColumn(T, sourceLabel);
    horizon = horizonColumn(T, sourceLabel);
    targetCount = numericColumn(T, ["target_count", "num_targets"], true, sourceLabel);
    completed = completedColumn(T, targetCount, sourceLabel);

    S = table(trialId, algorithm, communication, horizon, targetCount, completed, ...
        optionalStringColumn(T, ["condition_id"], height(T)), ...
        optionalStringColumn(T, ["scenario_file"], height(T)), ...
        numericColumn(T, ["total_team_steps"], true, sourceLabel), ...
        numericColumn(T, ["max_robot_steps", "max_steps_any_robot"], true, sourceLabel), ...
        numericColumn(T, ["final_target_completion_sim_time_s", "final_target_completion_time_s"], true, sourceLabel), ...
        numericColumn(T, ["workload_gini_targets_found"], false, sourceLabel), ...
        numericColumn(T, ["workload_gini_unique_cells_contributed"], false, sourceLabel), ...
        numericColumn(T, ["allocation_messages_sent_total"], false, sourceLabel), ...
        numericColumn(T, ["messages_sent_total"], false, sourceLabel), ...
        numericColumn(T, ["allocator_time_ms_team_total", "allocator_solve_time_ms_team_total"], false, sourceLabel), ...
        'VariableNames', { ...
        'trial_id', 'algorithm', 'comm_label', 'horizon', 'target_count', 'completed', ...
        'condition_id', 'scenario_file', 'total_team_steps', 'max_robot_steps', ...
        'final_completion_time', 'target_workload_gini', 'movement_workload_gini', ...
        'allocation_messages', 'total_messages', 'allocator_time_ms'});
end

function R = normalizeRobotTable(T, sourceLabel)
    sourceLabel = string(sourceLabel);
    requireColumns(T, ["trial_id", "algorithm", "comm_model", "robot_id"], sourceLabel);
    targetCount = numericColumn(T, ["target_count", "num_targets"], true, sourceLabel);
    R = table( ...
        numericColumn(T, ["trial_id"], true, sourceLabel), ...
        algorithmColumn(T, sourceLabel), commColumn(T, sourceLabel), horizonColumn(T, sourceLabel), ...
        targetCount, completedColumn(T, targetCount, sourceLabel), ...
        optionalStringColumn(T, ["robot_id"], height(T)), ...
        numericColumn(T, ["steps_total"], true, sourceLabel), ...
        numericColumn(T, ["targets_found"], true, sourceLabel), ...
        numericColumn(T, ["unique_cells_contributed"], false, sourceLabel), ...
        'VariableNames', {'trial_id', 'algorithm', 'comm_label', 'horizon', ...
        'target_count', 'completed', 'robot_id', 'steps_total', 'targets_found', ...
        'unique_cells_contributed'});
end

function Q = normalizeTargetTable(T, sourceLabel)
    sourceLabel = string(sourceLabel);
    requireColumns(T, ["trial_id", "algorithm", "comm_model", "target_index", "completed"], sourceLabel);
    targetCount = numericColumn(T, ["target_count", "num_targets"], true, sourceLabel);
    Q = table( ...
        numericColumn(T, ["trial_id"], true, sourceLabel), ...
        algorithmColumn(T, sourceLabel), commColumn(T, sourceLabel), horizonColumn(T, sourceLabel), ...
        targetCount, completedColumn(T, targetCount, sourceLabel), ...
        numericColumn(T, ["target_index"], true, sourceLabel), ...
        logicalColumn(T, ["completed"], false), ...
        'VariableNames', {'trial_id', 'algorithm', 'comm_label', 'horizon', ...
        'target_count', 'trial_completed', 'target_index', 'target_completed'});
end

function requireColumns(T, candidates, sourceLabel)
    present = lower(string(T.Properties.VariableNames));
    missing = candidates(~ismember(lower(candidates), present));
    if ~isempty(missing)
        error('Required columns missing from %s: %s. Available columns: %s', ...
            sourceLabel, strjoin(missing, ', '), strjoin(string(T.Properties.VariableNames), ', '));
    end
end

function value = numericColumn(T, candidates, required, sourceLabel)
    name = firstExistingColumn(T, candidates);
    if strlength(name) == 0
        if required
            error('Required numeric column missing from %s. Expected one of: %s', ...
                sourceLabel, strjoin(candidates, ', '));
        end
        value = nan(height(T), 1);
        return;
    end
    raw = T.(char(name));
    if isnumeric(raw) || islogical(raw)
        value = double(raw);
    else
        value = str2double(strtrim(string(raw)));
    end
    value = double(value(:));
end

function value = optionalStringColumn(T, candidates, rowCount)
    name = firstExistingColumn(T, candidates);
    if strlength(name) == 0
        value = repmat("", rowCount, 1);
    else
        value = string(T.(char(name)));
        value = value(:);
    end
end

function name = firstExistingColumn(T, candidates)
    present = lower(string(T.Properties.VariableNames));
    name = "";
    for i = 1:numel(candidates)
        index = find(present == lower(candidates(i)), 1, 'first');
        if ~isempty(index)
            name = string(T.Properties.VariableNames{index});
            return;
        end
    end
end

function value = algorithmColumn(T, sourceLabel)
    raw = optionalStringColumn(T, ["algorithm_key", "algorithm"], height(T));
    if all(strlength(strtrim(raw)) == 0)
        error('Algorithm label is missing from %s.', sourceLabel);
    end
    value = upper(strtrim(raw));
end

function value = commColumn(T, sourceLabel)
    rawLabel = optionalStringColumn(T, ["comm_label"], height(T));
    rawModel = lower(strtrim(optionalStringColumn(T, ["comm_model"], height(T))));
    rawLevel = optionalStringColumn(T, ["comm_level"], height(T));
    if all(strlength(rawLabel) == 0) && all(strlength(rawModel) == 0)
        error('Communication labels are missing from %s.', sourceLabel);
    end

    value = strings(height(T), 1);
    for i = 1:height(T)
        label = lower(strtrim(rawLabel(i)));
        model = rawModel(i);
        level = str2double(strtrim(rawLevel(i)));
        if label == "ideal" || model == "ideal"
            value(i) = "ideal";
        elseif contains(label, "bernoulli") && (contains(label, "025") || abs(level - 0.25) < 1e-12)
            value(i) = "bernoulli_025";
        elseif model == "bernoulli" && abs(level - 0.25) < 1e-12
            value(i) = "bernoulli_025";
        elseif strlength(label) > 0
            value(i) = label;
        elseif strlength(model) > 0
            value(i) = model + "_" + strtrim(rawLevel(i));
        else
            value(i) = "";
        end
    end
end

function value = horizonColumn(T, sourceLabel)
    candidates = ["commitment_horizon", "sensitivity_value", "value"];
    value = numericColumn(T, candidates, false, sourceLabel);
    setting = optionalStringColumn(T, ["setting", "sensitivity_label"], height(T));
    condition = optionalStringColumn(T, ["condition_id", "run_id"], height(T));
    for i = 1:height(T)
        if isfinite(value(i))
            continue;
        end
        parsed = str2double(erase(lower(setting(i)), "h"));
        if isfinite(parsed)
            value(i) = parsed;
            continue;
        end
        token = regexp(char(condition(i)), '(^|_)h(\d+)(_|$)', 'tokens', 'once');
        if ~isempty(token)
            value(i) = str2double(token{2});
        end
    end
    if any(~isfinite(value))
        bad = find(~isfinite(value), 1, 'first');
        error(['Could not determine a commitment horizon for row %d of %s. ' ...
            'Expected commitment_horizon, sensitivity_value/value, setting, or condition_id h# metadata.'], ...
            bad, sourceLabel);
    end
end

function value = completedColumn(T, targetCount, sourceLabel)
    trialStatus = optionalStringColumn(T, ["trial_status"], height(T));
    visited = logicalColumn(T, ["all_targets_visited"], false);
    completedCount = numericColumn(T, ["completed_target_count"], false, sourceLabel);
    value = true(height(T), 1);
    if any(strlength(trialStatus) > 0)
        value = value & lower(strtrim(trialStatus)) == "completed";
    end
    if any(~isnan(visited))
        known = ~isnan(visited);
        value(known) = value(known) & logical(visited(known));
    end
    if any(isfinite(completedCount))
        known = isfinite(completedCount) & isfinite(targetCount);
        value(known) = value(known) & completedCount(known) == targetCount(known);
    end
end

function value = logicalColumn(T, candidates, required)
    name = firstExistingColumn(T, candidates);
    if strlength(name) == 0
        if required
            error('Required logical column missing. Expected one of: %s', strjoin(candidates, ', '));
        end
        value = nan(height(T), 1);
        return;
    end
    raw = T.(char(name));
    if islogical(raw)
        value = double(raw(:));
    elseif isnumeric(raw)
        value = double(raw(:) ~= 0);
    else
        text = lower(strtrim(string(raw)));
        value = nan(height(T), 1);
        value(ismember(text, ["true", "1", "yes", "completed"])) = 1;
        value(ismember(text, ["false", "0", "no", "failed"])) = 0;
    end
end

function [dataset, validation] = prepareDataset(S, R, Q, targetCount, selectFirst25, ...
        horizons, algorithms, commLabels, validation, sourceDescription)
    expectedCombinations = numel(horizons) * numel(algorithms) * numel(commLabels);
    filterSystem = S.target_count == targetCount & ismember(S.algorithm, algorithms) & ...
        ismember(S.comm_label, commLabels) & ismember(S.horizon, horizons);
    S = S(filterSystem, :);
    if isempty(S)
        error('No target-count-%d system rows remain after filtering to the fixed pilot matrix.', targetCount);
    end
    if any(~isfinite(S.horizon))
        error('Target-count-%d data contain non-finite horizon values after normalization.', targetCount);
    end

    allIds = sort(unique(S.trial_id));
    completeIds = [];
    incompleteIds = [];
    duplicateIds = [];
    for i = 1:numel(allIds)
        block = S(S.trial_id == allIds(i), :);
        keys = trialConditionKey(block);
        blockIsComplete = height(block) == expectedCombinations && ...
            numel(unique(keys)) == expectedCombinations && ...
            all(block.completed) && all(isfinite(block.total_team_steps)) && ...
            all(isfinite(block.max_robot_steps)) && all(isfinite(block.final_completion_time));
        if blockIsComplete
            completeIds(end + 1) = allIds(i); %#ok<AGROW>
        else
            incompleteIds(end + 1) = allIds(i); %#ok<AGROW>
            if numel(unique(keys)) < height(block)
                duplicateIds(end + 1) = allIds(i); %#ok<AGROW>
            end
        end
    end

    if selectFirst25
        if numel(completeIds) < 25
            error(['Existing 10-target campaign has only %d fully paired trials for the ' ...
                'required three-algorithm, two-communication, six-horizon matrix; 25 are required.'], ...
                numel(completeIds));
        end
        retainedIds = completeIds(1:25);
        selectionNote = "first 25 sorted fully paired trial IDs";
    else
        if numel(allIds) ~= 25 || numel(completeIds) ~= 25
            error(['Target-count-%d pilot data are incomplete: expected exactly 25 fully paired ' ...
                'trial IDs, observed %d complete of %d present.'], ...
                targetCount, numel(completeIds), numel(allIds));
        end
        retainedIds = completeIds;
        selectionNote = "all 25 pilot trial IDs";
    end

    S = S(ismember(S.trial_id, retainedIds), :);
    if height(S) ~= 25 * expectedCombinations
        error('Target-count-%d retained system rows are not the expected complete paired matrix.', targetCount);
    end
    if numel(unique(trialConditionKey(S))) ~= height(S)
        error('Target-count-%d retained system rows contain duplicate condition/trial keys.', targetCount);
    end
    scenarioFiles = unique(strtrim(S.scenario_file));
    scenarioFiles = scenarioFiles(strlength(scenarioFiles) > 0);
    scenarioNames = unique(regexprep(scenarioFiles, '^.*[\\/]', ''));
    if numel(scenarioNames) ~= 1
        error(['Target-count-%d does not use exactly one common scenario file across ' ...
            'algorithms, horizons, and communication conditions. Observed: %s'], ...
            targetCount, strjoin(scenarioFiles, '; '));
    end

    filterRobot = R.target_count == targetCount & ismember(R.algorithm, algorithms) & ...
        ismember(R.comm_label, commLabels) & ismember(R.horizon, horizons) & ...
        ismember(R.trial_id, retainedIds);
    R = R(filterRobot, :);
    filterTarget = Q.target_count == targetCount & ismember(Q.algorithm, algorithms) & ...
        ismember(Q.comm_label, commLabels) & ismember(Q.horizon, horizons) & ...
        ismember(Q.trial_id, retainedIds);
    Q = Q(filterTarget, :);

    [S, robotOk, robotDetail] = attachRobotDerivedMetrics(S, R);
    [targetOk, targetDetail] = validateTargetRows(S, Q, targetCount);
    validation = addValidation(validation, sprintf('paired_system_blocks_t%d', targetCount), ...
        true, "25 complete blocks", sprintf('%d complete; %d incomplete', ...
        numel(retainedIds), numel(incompleteIds)), selectionNote);
    validation = addValidation(validation, sprintf('duplicate_system_keys_t%d', targetCount), ...
        isempty(duplicateIds), "0 duplicate trial blocks", string(numel(duplicateIds)), ...
        "Duplicate condition/trial records are not permitted in the retained paired analysis set.");
    validation = addValidation(validation, sprintf('common_scenario_file_t%d', targetCount), ...
        numel(scenarioNames) == 1, "one canonical scenario filename", strjoin(scenarioNames, '; '), ...
        "Historical launch prefixes may differ; every condition must use the same canonical scenario filename.");
    validation = addValidation(validation, sprintf('robot_row_completeness_t%d', targetCount), ...
        robotOk, "4 unique robot rows per system trial", robotDetail, ...
        "Active-robot and workload mechanism metrics are derived from robot-performance rows.");
    validation = addValidation(validation, sprintf('target_row_completeness_t%d', targetCount), ...
        targetOk, sprintf('%d complete target rows per system trial', targetCount), targetDetail, ...
        "All retained completed trials must report every target visited exactly once in target-performance data.");
    if ~robotOk || ~targetOk || ~isempty(duplicateIds)
        error('Target-count-%d pairing/robot/target validation failed; inspect pilot_analysis_validation.csv.', targetCount);
    end

    dataset.targetCount = targetCount;
    dataset.system = S;
    dataset.robot = R;
    dataset.target = Q;
    dataset.retainedTrialIds = retainedIds(:);
    dataset.sourceDescription = string(sourceDescription);
end

function keys = trialConditionKey(T)
    keys = T.algorithm + "|" + T.comm_label + "|h" + string(T.horizon) + ...
        "|trial" + string(T.trial_id);
end

function [S, ok, detail] = attachRobotDerivedMetrics(S, R)
    systemKeys = trialConditionKey(S);
    robotKeys = trialConditionKey(R);
    n = height(S);
    active = nan(n, 1);
    maxTargets = nan(n, 1);
    maxSteps = nan(n, 1);
    targetGini = S.target_workload_gini;
    movementGini = S.movement_workload_gini;
    bad = strings(0, 1);
    for i = 1:n
        rows = R(robotKeys == systemKeys(i), :);
        if height(rows) ~= 4 || numel(unique(rows.robot_id)) ~= 4
            bad(end + 1) = systemKeys(i); %#ok<AGROW>
            continue;
        end
        active(i) = sum(rows.targets_found > 0);
        maxTargets(i) = max(rows.targets_found);
        maxSteps(i) = max(rows.steps_total);
        if ~isfinite(targetGini(i))
            targetGini(i) = localGini(rows.targets_found);
        end
        if ~isfinite(movementGini(i)) && any(isfinite(rows.unique_cells_contributed))
            movementGini(i) = localGini(rows.unique_cells_contributed);
        end
    end
    S.active_robot_count = active;
    S.max_target_workload = maxTargets;
    S.max_individual_steps = maxSteps;
    S.target_workload_gini = targetGini;
    S.movement_workload_gini = movementGini;
    ok = isempty(bad) && all(isfinite(active)) && all(isfinite(maxTargets)) && all(isfinite(maxSteps));
    if isempty(bad)
        detail = sprintf('%d system trials checked', n);
    else
        detail = sprintf('%d malformed robot blocks; first=%s', numel(bad), bad(1));
    end
end

function [ok, detail] = validateTargetRows(S, Q, targetCount)
    systemKeys = trialConditionKey(S);
    targetKeys = trialConditionKey(Q);
    bad = strings(0, 1);
    for i = 1:height(S)
        rows = Q(targetKeys == systemKeys(i), :);
        if height(rows) ~= targetCount || numel(unique(rows.target_index)) ~= targetCount || ...
                ~all(rows.target_completed)
            bad(end + 1) = systemKeys(i); %#ok<AGROW>
        end
    end
    ok = isempty(bad);
    if ok
        detail = sprintf('%d system trials checked', height(S));
    else
        detail = sprintf('%d malformed target blocks; first=%s', numel(bad), bad(1));
    end
end

function value = localGini(values)
    values = sort(double(values(:)));
    values = values(isfinite(values) & values >= 0);
    if isempty(values) || sum(values) == 0
        value = 0;
        return;
    end
    count = numel(values);
    value = 2 * sum((1:count)' .* values) / (count * sum(values)) - (count + 1) / count;
end

function [selectionTable, stabilityTable] = makeHorizonSelections(S, targetCounts, algorithms, ...
        horizons, nonOneHorizons, bootstrapIterations)
    selectionCells = cell(0, 13);
    stabilityCells = cell(0, 11);
    row = 0;
    for tc = targetCounts
        for algorithm = algorithms
            for metric = ["total_team_steps", "max_robot_steps"]
                values = balancedTrialHorizonMatrix(S, tc, algorithm, metric, horizons);
                if any(~isfinite(values), 'all')
                    error(['Cannot select a %s horizon for target count %d / %s because ' ...
                        'the balanced complete trial matrix contains missing values.'], metric, tc, algorithm);
                end
                for setName = ["all_horizons", "exclude_horizon_1"]
                    if setName == "all_horizons"
                        candidates = horizons;
                    else
                        candidates = nonOneHorizons;
                    end
                    candidateIndex = ismember(horizons, candidates);
                    means = mean(values, 1);
                    ses = std(values, 0, 1) ./ sqrt(size(values, 1));
                    [selectedMean, selectedLocal] = min(means(candidateIndex));
                    candidateHorizons = horizons(candidateIndex);
                    selectedHorizon = candidateHorizons(selectedLocal);
                    selectedIndex = find(horizons == selectedHorizon, 1, 'first');
                    counts = bootstrapSelectionCounts(values(:, candidateIndex), candidateHorizons, bootstrapIterations);
                    for hi = 1:numel(horizons)
                        row = row + 1;
                        eligible = ismember(horizons(hi), candidates);
                        if eligible
                            candidatePos = find(candidateHorizons == horizons(hi), 1, 'first');
                            count = counts(candidatePos);
                            frequency = count / bootstrapIterations;
                        else
                            count = 0;
                            frequency = 0;
                        end
                        selectionCells(end + 1, :) = { ... %#ok<AGROW>
                            tc, algorithm, metric, setName, strjoin(string(candidates), ';'), ...
                            horizons(hi), eligible, means(hi), ses(hi), selectedHorizon, ...
                            horizons(hi) == selectedHorizon, size(values, 1), ...
                            "equal-weight ideal/Bernoulli mean within each paired trial"};
                        stabilityCells(end + 1, :) = { ... %#ok<AGROW>
                            tc, algorithm, metric, setName, horizons(hi), eligible, count, frequency, ...
                            bootstrapIterations, selectedHorizon, ...
                            "resample complete trial blocks; retain equal ideal/Bernoulli weighting"};
                    end
                    assert(isfinite(selectedMean) && isfinite(means(selectedIndex)));
                end
            end
        end
    end
    selectionTable = cell2table(selectionCells, 'VariableNames', { ...
        'target_count', 'algorithm', 'selection_metric', 'candidate_set', ...
        'candidate_horizons', 'horizon', 'eligible', 'mean_response', ...
        'standard_error', 'selected_horizon', 'selected', 'paired_trial_n', ...
        'normalization'});
    stabilityTable = cell2table(stabilityCells, 'VariableNames', { ...
        'target_count', 'algorithm', 'selection_metric', 'candidate_set', ...
        'horizon', 'eligible', 'selection_count', 'selection_frequency', ...
        'bootstrap_resamples', 'point_estimate_selected_horizon', 'resampling_unit'});
    selectionTable = normalizeOutputTable(selectionTable, ...
        ["target_count", "horizon", "mean_response", "standard_error", "selected_horizon", "paired_trial_n"], ...
        ["algorithm", "selection_metric", "candidate_set", "candidate_horizons", "normalization"], ...
        ["eligible", "selected"]);
    stabilityTable = normalizeOutputTable(stabilityTable, ...
        ["target_count", "horizon", "selection_count", "selection_frequency", ...
        "bootstrap_resamples", "point_estimate_selected_horizon"], ...
        ["algorithm", "selection_metric", "candidate_set", "resampling_unit"], ["eligible"]);
    selectionTable = sortrows(selectionTable, {'target_count', 'algorithm', 'selection_metric', 'candidate_set', 'horizon'});
    stabilityTable = sortrows(stabilityTable, {'target_count', 'algorithm', 'selection_metric', 'candidate_set', 'horizon'});
end

function X = balancedTrialHorizonMatrix(S, targetCount, algorithm, metric, horizons)
    G = S(S.target_count == targetCount & S.algorithm == algorithm, :);
    trialIds = sort(unique(G.trial_id));
    X = nan(numel(trialIds), numel(horizons));
    for ti = 1:numel(trialIds)
        for hi = 1:numel(horizons)
            rows = G(G.trial_id == trialIds(ti) & G.horizon == horizons(hi) & ...
                ismember(G.comm_label, ["ideal", "bernoulli_025"]), :);
            if height(rows) ~= 2 || ~all(ismember(rows.comm_label, ["ideal", "bernoulli_025"])) || ...
                    ~all(isfinite(rows.(char(metric))))
                error('Incomplete balanced matrix at target %d, %s, trial %g, horizon %g, metric %s.', ...
                    targetCount, algorithm, trialIds(ti), horizons(hi), metric);
            end
            X(ti, hi) = mean(rows.(char(metric)));
        end
    end
end

function counts = bootstrapSelectionCounts(values, candidateHorizons, bootstrapIterations)
    n = size(values, 1);
    if n < 2
        error('At least two paired trials are required for bootstrap horizon-selection stability.');
    end
    index = randi(n, n, bootstrapIterations);
    bootMeans = zeros(bootstrapIterations, size(values, 2));
    for hi = 1:size(values, 2)
        bootMeans(:, hi) = mean(values(index, hi), 1)';
    end
    [~, chosen] = min(bootMeans, [], 2); % first minimum gives deterministic lower-horizon tie-break.
    counts = zeros(1, numel(candidateHorizons));
    for hi = 1:numel(candidateHorizons)
        counts(hi) = sum(chosen == hi);
    end
end

function [transferTable, statisticalTable, transferSamples] = makeTransferAnalysis(S, selectionTable, ...
        targetCounts, algorithms, commLabels, metricDefs, bootstrapIterations)
    transferCells = cell(0, 23);
    statisticalCells = cell(0, 20);
    sampleCells = cell(0, 8);
    transferRowId = 0;
    for tc = targetCounts
        for algorithm = algorithms
            effortHorizon = selectedHorizon(selectionTable, tc, algorithm, ...
                "total_team_steps", "all_horizons");
            makespanHorizon = selectedHorizon(selectionTable, tc, algorithm, ...
                "max_robot_steps", "all_horizons");
            for comm = commLabels
                for mi = 1:numel(metricDefs)
                    metric = metricDefs(mi).key;
                    [effortValues, makespanValues, trialIds] = selectedMetricPairs( ...
                        S, tc, algorithm, comm, effortHorizon, makespanHorizon, metric);
                    valid = isfinite(effortValues) & isfinite(makespanValues);
                    effortValues = effortValues(valid);
                    makespanValues = makespanValues(valid);
                    trialIds = trialIds(valid);
                    if isempty(effortValues)
                        if metricDefs(mi).required
                            error('Required metric %s has no finite transfer pairs for target %d / %s / %s.', ...
                                metric, tc, algorithm, comm);
                        end
                        continue;
                    end
                    delta = effortValues - makespanValues;
                    [pRaw, rrb, wPlus, wMinus, nNonzero] = pairedWilcoxon(delta);
                    [diffLo, diffHi, pctLo, pctHi] = pairedBootstrapIntervals( ...
                        effortValues, makespanValues, bootstrapIterations);
                    effortMean = mean(effortValues);
                    makespanMean = mean(makespanValues);
                    percentChange = ratioPercentChange(effortMean, makespanMean);
                    transferRowId = transferRowId + 1;
                    makespanPenalty = NaN;
                    if metric == "max_robot_steps"
                        makespanPenalty = percentChange;
                    end
                    transferCells(end + 1, :) = { ... %#ok<AGROW>
                        transferRowId, tc, algorithm, comm, effortHorizon, makespanHorizon, ...
                        metric, metricDefs(mi).display, numel(delta), effortMean, makespanMean, ...
                        mean(delta), median(delta), percentChange, makespanPenalty, diffLo, diffHi, pctLo, pctHi, ...
                        pRaw, NaN, rrb, ...
                        "pilot/exploratory paired effort-selected minus makespan-selected contrast"};
                    statisticalCells(end + 1, :) = { ... %#ok<AGROW>
                        "paired_objective_transfer", tc, NaN, NaN, algorithm, comm, metric, ...
                        effortHorizon, makespanHorizon, numel(delta), NaN, NaN, ...
                        mean(delta), percentChange, diffLo, diffHi, pRaw, NaN, rrb, nNonzero};

                    if metric == "max_robot_steps"
                        trialPenalty = 100 * (effortValues ./ makespanValues - 1);
                        finitePenalty = isfinite(trialPenalty);
                        for si = find(finitePenalty)'
                            sampleCells(end + 1, :) = { ... %#ok<AGROW>
                                tc, algorithm, comm, trialIds(si), effortHorizon, makespanHorizon, ...
                                trialPenalty(si), delta(si)};
                        end
                    end
                end
            end
        end
    end
    transferTable = cell2table(transferCells, 'VariableNames', { ...
        'transfer_row_id', 'target_count', 'algorithm', 'comm_label', ...
        'effort_selected_horizon', 'makespan_selected_horizon', 'metric', 'metric_display', ...
        'paired_n', 'effort_selected_mean', 'makespan_selected_mean', ...
        'mean_paired_difference_effort_minus_makespan', ...
        'median_paired_difference_effort_minus_makespan', 'percent_change_effort_vs_makespan', ...
        'makespan_penalty_pct', ...
        'paired_bootstrap_difference_ci95_lower', 'paired_bootstrap_difference_ci95_upper', ...
        'paired_bootstrap_percent_change_ci95_lower', 'paired_bootstrap_percent_change_ci95_upper', ...
        'wilcoxon_raw_p_value', 'holm_p_value', 'rank_biserial_effort_minus_makespan', 'scope'});
    statisticalTable = cell2table(statisticalCells, 'VariableNames', { ...
        'analysis_type', 'target_count', 'target_count_a', 'target_count_b', ...
        'algorithm', 'comm_label', 'metric', 'effort_selected_horizon', ...
        'makespan_selected_horizon', 'paired_n', 'independent_n_a', 'independent_n_b', ...
        'mean_paired_difference', 'percent_change_effort_vs_makespan', ...
        'bootstrap_ci95_lower', 'bootstrap_ci95_upper', 'raw_p_value', ...
        'holm_p_value', 'rank_biserial_effort_minus_makespan', 'wilcoxon_nonzero_n'});
    transferSamples = cell2table(sampleCells, 'VariableNames', { ...
        'target_count', 'algorithm', 'comm_label', 'trial_id', ...
        'effort_selected_horizon', 'makespan_selected_horizon', ...
        'trial_makespan_penalty_pct', 'trial_makespan_difference'});
    transferTable = normalizeOutputTable(transferTable, ...
        ["transfer_row_id", "target_count", "effort_selected_horizon", "makespan_selected_horizon", ...
        "paired_n", "effort_selected_mean", "makespan_selected_mean", ...
        "mean_paired_difference_effort_minus_makespan", "median_paired_difference_effort_minus_makespan", ...
        "percent_change_effort_vs_makespan", "makespan_penalty_pct", ...
        "paired_bootstrap_difference_ci95_lower", "paired_bootstrap_difference_ci95_upper", ...
        "paired_bootstrap_percent_change_ci95_lower", "paired_bootstrap_percent_change_ci95_upper", ...
        "wilcoxon_raw_p_value", "holm_p_value", "rank_biserial_effort_minus_makespan"], ...
        ["algorithm", "comm_label", "metric", "metric_display", "scope"], strings(1, 0));
    statisticalTable = normalizeOutputTable(statisticalTable, ...
        ["target_count", "target_count_a", "target_count_b", "effort_selected_horizon", ...
        "makespan_selected_horizon", "paired_n", "independent_n_a", "independent_n_b", ...
        "mean_paired_difference", "percent_change_effort_vs_makespan", ...
        "bootstrap_ci95_lower", "bootstrap_ci95_upper", "raw_p_value", "holm_p_value", ...
        "rank_biserial_effort_minus_makespan", "wilcoxon_nonzero_n"], ...
        ["analysis_type", "algorithm", "comm_label", "metric"], strings(1, 0));
    transferSamples = normalizeOutputTable(transferSamples, ...
        ["target_count", "trial_id", "effort_selected_horizon", "makespan_selected_horizon", ...
        "trial_makespan_penalty_pct", "trial_makespan_difference"], ...
        ["algorithm", "comm_label"], strings(1, 0));

    % Holm families contain the three algorithm tests for one target count,
    % communication condition, and outcome metric.
    for tc = targetCounts
        for comm = commLabels
            for metric = unique(statisticalTable.metric(statisticalTable.analysis_type == "paired_objective_transfer"))'
                mask = statisticalTable.analysis_type == "paired_objective_transfer" & ...
                    statisticalTable.target_count == tc & statisticalTable.comm_label == comm & ...
                    statisticalTable.metric == metric;
                if ~any(mask), continue; end
                adjusted = pilot_horizon_holm_adjust(statisticalTable.raw_p_value(mask));
                statisticalTable.holm_p_value(mask) = adjusted;
                ids = find(mask);
                for ii = 1:numel(ids)
                    transferTable.holm_p_value(transferTable.transfer_row_id == ids(ii)) = adjusted(ii);
                end
            end
        end
    end
    transferTable = sortrows(transferTable, {'target_count', 'algorithm', 'comm_label', 'metric'});
    statisticalTable = sortrows(statisticalTable, {'analysis_type', 'target_count', 'comm_label', 'metric', 'algorithm'});
end

function horizon = selectedHorizon(selectionTable, targetCount, algorithm, metric, candidateSet)
    rows = selectionTable(selectionTable.target_count == targetCount & ...
        selectionTable.algorithm == algorithm & selectionTable.selection_metric == metric & ...
        selectionTable.candidate_set == candidateSet & selectionTable.selected, :);
    if height(rows) ~= 1
        error('Expected exactly one %s selection for target %d / %s / %s; found %d.', ...
            metric, targetCount, algorithm, candidateSet, height(rows));
    end
    horizon = rows.selected_horizon;
end

function [effortValues, makespanValues, trialIds] = selectedMetricPairs(S, targetCount, algorithm, ...
        comm, effortHorizon, makespanHorizon, metric)
    effort = S(S.target_count == targetCount & S.algorithm == algorithm & ...
        S.comm_label == comm & S.horizon == effortHorizon, :);
    makespan = S(S.target_count == targetCount & S.algorithm == algorithm & ...
        S.comm_label == comm & S.horizon == makespanHorizon, :);
    [effortIds, effortOrder] = sort(effort.trial_id);
    [makespanIds, makespanOrder] = sort(makespan.trial_id);
    if numel(effortIds) ~= 25 || numel(makespanIds) ~= 25 || ~isequal(effortIds, makespanIds)
        error(['Selected-horizon transfer comparison is not paired for target %d / %s / %s ' ...
            '(effort h=%g, makespan h=%g).'], targetCount, algorithm, comm, effortHorizon, makespanHorizon);
    end
    effortValues = effort.(char(metric))(effortOrder);
    makespanValues = makespan.(char(metric))(makespanOrder);
    trialIds = effortIds;
end

function [pValue, rrb, wPlus, wMinus, nonzeroCount] = pairedWilcoxon(delta)
    [rrb, wPlus, wMinus, nonzeroCount] = pilot_horizon_rank_biserial(delta);
    finite = double(delta(isfinite(delta)));
    if isempty(finite) || all(finite == 0)
        pValue = 1;
        return;
    end
    try
        pValue = signrank(finite, 'method', 'approximate');
    catch
        pValue = signrank(finite);
    end
    if isempty(pValue) || ~isfinite(pValue)
        pValue = 1;
    end
end

function [diffLo, diffHi, pctLo, pctHi] = pairedBootstrapIntervals(effort, makespan, bootstrapIterations)
    n = numel(effort);
    if n == 0
        diffLo = NaN; diffHi = NaN; pctLo = NaN; pctHi = NaN;
        return;
    end
    index = randi(n, n, bootstrapIterations);
    diffValues = effort - makespan;
    bootDiff = mean(diffValues(index), 1);
    bootEffort = mean(effort(index), 1);
    bootMakespan = mean(makespan(index), 1);
    bootPercent = 100 * (bootEffort ./ bootMakespan - 1);
    diffLo = pilot_horizon_percentile(bootDiff, 2.5);
    diffHi = pilot_horizon_percentile(bootDiff, 97.5);
    pctLo = pilot_horizon_percentile(bootPercent, 2.5);
    pctHi = pilot_horizon_percentile(bootPercent, 97.5);
end

function pct = ratioPercentChange(numerator, denominator)
    if ~isfinite(numerator) || ~isfinite(denominator) || denominator == 0
        pct = NaN;
    else
        pct = 100 * (numerator / denominator - 1);
    end
end

function independentTable = makeIndependentTargetLoadComparisons(samples, targetCounts, ...
        algorithms, commLabels, bootstrapIterations)
    cells = cell(0, 20);
    pairs = nchoosek(targetCounts, 2);
    for pi = 1:size(pairs, 1)
        countA = pairs(pi, 1);
        countB = pairs(pi, 2);
        for algorithm = algorithms
            for comm = commLabels
                a = samples.trial_makespan_penalty_pct(samples.target_count == countA & ...
                    samples.algorithm == algorithm & samples.comm_label == comm);
                b = samples.trial_makespan_penalty_pct(samples.target_count == countB & ...
                    samples.algorithm == algorithm & samples.comm_label == comm);
                if numel(a) ~= 25 || numel(b) ~= 25
                    error(['Independent target-load comparison needs 25 makespan-penalty values in both ' ...
                        'conditions; got %d for %d targets and %d for %d targets (%s / %s).'], ...
                        numel(a), countA, numel(b), countB, algorithm, comm);
                end
                [lo, hi] = independentBootstrapDifference(a, b, bootstrapIterations);
                cells(end + 1, :) = { ... %#ok<AGROW>
                    "independent_bootstrap_target_load_difference", NaN, countA, countB, ...
                    algorithm, comm, "max_robot_steps", NaN, NaN, NaN, numel(a), numel(b), ...
                    mean(b) - mean(a), NaN, lo, hi, NaN, NaN, NaN, NaN};
            end
        end
    end
    independentTable = cell2table(cells, 'VariableNames', { ...
        'analysis_type', 'target_count', 'target_count_a', 'target_count_b', ...
        'algorithm', 'comm_label', 'metric', 'effort_selected_horizon', ...
        'makespan_selected_horizon', 'paired_n', 'independent_n_a', 'independent_n_b', ...
        'mean_paired_difference', 'percent_change_effort_vs_makespan', ...
        'bootstrap_ci95_lower', 'bootstrap_ci95_upper', 'raw_p_value', ...
        'holm_p_value', 'rank_biserial_effort_minus_makespan', 'wilcoxon_nonzero_n'});
    independentTable = normalizeOutputTable(independentTable, ...
        ["target_count", "target_count_a", "target_count_b", "effort_selected_horizon", ...
        "makespan_selected_horizon", "paired_n", "independent_n_a", "independent_n_b", ...
        "mean_paired_difference", "percent_change_effort_vs_makespan", ...
        "bootstrap_ci95_lower", "bootstrap_ci95_upper", "raw_p_value", "holm_p_value", ...
        "rank_biserial_effort_minus_makespan", "wilcoxon_nonzero_n"], ...
        ["analysis_type", "algorithm", "comm_label", "metric"], strings(1, 0));
end

function [lo, hi] = independentBootstrapDifference(a, b, bootstrapIterations)
    a = double(a(:)); b = double(b(:));
    indexA = randi(numel(a), numel(a), bootstrapIterations);
    indexB = randi(numel(b), numel(b), bootstrapIterations);
    bootDifference = mean(b(indexB), 1) - mean(a(indexA), 1);
    lo = pilot_horizon_percentile(bootDifference, 2.5);
    hi = pilot_horizon_percentile(bootDifference, 97.5);
end

function M = makeMechanismTable(transferTable)
    mechanismMetrics = [ ...
        "total_team_steps", "max_robot_steps", "target_workload_gini", ...
        "movement_workload_gini", "active_robot_count", "max_target_workload", ...
        "max_individual_steps", "allocation_messages", "total_messages", "allocator_time_ms"];
    M = transferTable(ismember(transferTable.metric, mechanismMetrics), :);
    association = strings(height(M), 1);
    for i = 1:height(M)
        association(i) = mechanismInterpretation(M.metric(i), M.percent_change_effort_vs_makespan(i));
    end
    M.explanatory_association = association;
    M.interpretation_scope = repmat( ...
        "exploratory association; selected horizons and outcomes use the same paired pilot scenarios, not causal proof", ...
        height(M), 1);
end

function label = mechanismInterpretation(metric, percentage)
    if ~isfinite(percentage)
        label = "percentage unavailable because the makespan-selected denominator is zero or missing";
        return;
    end
    direction = "higher";
    if percentage < 0
        direction = "lower";
    elseif percentage == 0
        direction = "unchanged";
    end
    switch metric
        case "total_team_steps"
            label = direction + " total team movement under the effort-selected horizon";
        case "max_robot_steps"
            label = direction + " makespan under the effort-selected horizon";
        case {"target_workload_gini", "movement_workload_gini"}
            label = direction + " workload imbalance under the effort-selected horizon";
        case "active_robot_count"
            label = direction + " active-robot count under the effort-selected horizon";
        case {"max_target_workload", "max_individual_steps"}
            label = direction + " maximum individual workload under the effort-selected horizon";
        case {"allocation_messages", "total_messages"}
            label = direction + " communication traffic under the effort-selected horizon";
        case "allocator_time_ms"
            label = direction + " allocator computation time under the effort-selected horizon";
        otherwise
            label = direction + " value under the effort-selected horizon";
    end
end

function rankingTable = makeAlgorithmRankings(S, selectionTable, targetCounts, algorithms, commLabels)
    cells = cell(0, 12);
    for tc = targetCounts
        for comm = commLabels
            for objective = ["effort_selected", "makespan_selected"]
                if objective == "effort_selected"
                    selectionMetric = "total_team_steps";
                    rankingMetric = "total_team_steps";
                else
                    selectionMetric = "max_robot_steps";
                    rankingMetric = "max_robot_steps";
                end
                horizons = nan(numel(algorithms), 1);
                means = nan(numel(algorithms), 1);
                effortMeans = nan(numel(algorithms), 1);
                makespanMeans = nan(numel(algorithms), 1);
                for ai = 1:numel(algorithms)
                    horizons(ai) = selectedHorizon(selectionTable, tc, algorithms(ai), ...
                        selectionMetric, "all_horizons");
                    rows = S(S.target_count == tc & S.algorithm == algorithms(ai) & ...
                        S.comm_label == comm & S.horizon == horizons(ai), :);
                    if height(rows) ~= 25
                        error('Ranking input is incomplete for target %d / %s / %s / h%g.', ...
                            tc, algorithms(ai), comm, horizons(ai));
                    end
                    means(ai) = mean(rows.(char(rankingMetric)));
                    effortMeans(ai) = mean(rows.total_team_steps);
                    makespanMeans(ai) = mean(rows.max_robot_steps);
                end
                ranks = ascendingAverageRanks(means);
                for ai = 1:numel(algorithms)
                    cells(end + 1, :) = { ... %#ok<AGROW>
                        tc, comm, objective, rankingMetric, algorithms(ai), horizons(ai), ...
                        means(ai), ranks(ai), effortMeans(ai), makespanMeans(ai), ...
                        "lower mean response receives rank 1", ...
                        "pilot/exploratory ranking under within-algorithm selected horizons"};
                end
            end
        end
    end
    rankingTable = cell2table(cells, 'VariableNames', { ...
        'target_count', 'comm_label', 'tuning_objective', 'ranking_metric', ...
        'algorithm', 'selected_horizon', 'ranking_metric_mean', 'rank', ...
        'mean_total_team_steps', 'mean_makespan', 'rank_rule', 'scope'});
    rankingTable = normalizeOutputTable(rankingTable, ...
        ["target_count", "selected_horizon", "ranking_metric_mean", "rank", ...
        "mean_total_team_steps", "mean_makespan"], ...
        ["comm_label", "tuning_objective", "ranking_metric", "algorithm", "rank_rule", "scope"], ...
        strings(1, 0));
    rankingTable = sortrows(rankingTable, {'target_count', 'comm_label', 'tuning_objective', 'rank', 'algorithm'});
end

function ranks = ascendingAverageRanks(values)
    values = double(values(:));
    [sortedValues, order] = sort(values);
    sortedRanks = nan(size(sortedValues));
    first = 1;
    while first <= numel(sortedValues)
        last = first;
        while last < numel(sortedValues) && sortedValues(last + 1) == sortedValues(first)
            last = last + 1;
        end
        sortedRanks(first:last) = mean(first:last);
        first = last + 1;
    end
    ranks = nan(size(values));
    ranks(order) = sortedRanks;
end

function summary = makeConditionSummary(S, targetCounts, algorithms, commLabels, horizons, metricDefs)
    cells = cell(0, 15);
    for tc = targetCounts
        for algorithm = algorithms
            for comm = commLabels
                for horizon = horizons
                    rows = S(S.target_count == tc & S.algorithm == algorithm & ...
                        S.comm_label == comm & S.horizon == horizon, :);
                    if height(rows) ~= 25
                        error('Condition summary requires 25 rows at target %d / %s / %s / h%g.', ...
                            tc, algorithm, comm, horizon);
                    end
                    for mi = 1:numel(metricDefs)
                        metric = metricDefs(mi).key;
                        values = rows.(char(metric));
                        valid = values(isfinite(values));
                        available = ~isempty(valid);
                        if available
                            meanValue = mean(valid);
                            medianValue = median(valid);
                            sdValue = std(valid);
                            seValue = sdValue / sqrt(numel(valid));
                            minValue = min(valid);
                            maxValue = max(valid);
                        else
                            meanValue = NaN; medianValue = NaN; sdValue = NaN;
                            seValue = NaN; minValue = NaN; maxValue = NaN;
                        end
                        cells(end + 1, :) = { ... %#ok<AGROW>
                            tc, algorithm, comm, horizon, metric, metricDefs(mi).display, ...
                            available, numel(valid), meanValue, medianValue, sdValue, seValue, ...
                            minValue, maxValue, metricDefs(mi).required};
                    end
                end
            end
        end
    end
    summary = cell2table(cells, 'VariableNames', { ...
        'target_count', 'algorithm', 'comm_label', 'horizon', 'metric', ...
        'metric_display', 'available', 'n', 'mean', 'median', 'standard_deviation', ...
        'standard_error', 'minimum', 'maximum', 'required_metric'});
    summary = normalizeOutputTable(summary, ...
        ["target_count", "horizon", "n", "mean", "median", "standard_deviation", ...
        "standard_error", "minimum", "maximum"], ...
        ["algorithm", "comm_label", "metric", "metric_display"], ...
        ["available", "required_metric"]);
    summary = sortrows(summary, {'target_count', 'algorithm', 'comm_label', 'horizon', 'metric'});
end

function plotHorizonResponses(summary, targetCounts, algorithms, commLabels, horizons, ...
        metric, yLabel, figureTitle, outputStem, style)
    fig = figure('Name', figureTitle, 'Color', 'w', 'Units', 'inches', ...
        'Position', [1, 1, 7.16, 6.2], 'Visible', 'off');
    layout = tiledlayout(fig, numel(targetCounts), 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    axesList = gobjects(numel(targetCounts), 1);
    legendHandles = gobjects(numel(algorithms), 1);
    for ti = 1:numel(targetCounts)
        ax = nexttile(layout); axesList(ti) = ax; hold(ax, 'on');
        for ai = 1:numel(algorithms)
            color = algorithmColor(algorithms(ai), style);
            for ci = 1:numel(commLabels)
                rows = summary(summary.target_count == targetCounts(ti) & ...
                    summary.algorithm == algorithms(ai) & summary.comm_label == commLabels(ci) & ...
                    summary.metric == metric, :);
                rows = sortrows(rows, 'horizon');
                lineStyle = "-";
                if commLabels(ci) == "bernoulli_025", lineStyle = ":"; end
                handle = errorbar(ax, rows.horizon, rows.mean, rows.standard_error, ...
                    'LineStyle', lineStyle, 'Color', color, 'LineWidth', style.lineWidth, ...
                    'Marker', 'o', 'MarkerSize', 3.0, 'MarkerFaceColor', color, ...
                    'CapSize', 2.5);
                if ti == 1 && ci == 1, legendHandles(ai) = handle; end
            end
        end
        title(ax, sprintf('%d targets', targetCounts(ti)), 'FontWeight', 'normal');
        xticks(ax, horizons); xlim(ax, [0.5, 12.5]);
        if ti < numel(targetCounts), xticklabels(ax, []); end
        formatPilotAxes(ax, style);
        text(ax, 0.99, 0.94, 'solid=ideal; dotted=Bernoulli p=0.25; error bars=+/-1 SE', ...
            'Units', 'normalized', 'HorizontalAlignment', 'right', ...
            'VerticalAlignment', 'top', 'FontSize', style.publicationFontSize - 1);
    end
    xlabel(layout, 'Commitment horizon');
    ylabel(layout, yLabel);
    title(layout, figureTitle, 'FontWeight', 'normal');
    legendHandle = legend(axesList(1), legendHandles, cellstr(algorithms), ...
        'Orientation', 'horizontal', 'NumColumns', 5, 'Box', 'off');
    legendHandle.Layout.Tile = 'south';
    legendHandle.ItemTokenSize = [12, 7];
    exportPilotFigure(fig, outputStem, style);
end

function plotMakespanPenalty(transferTable, targetCounts, algorithms, commLabels, outputStem, style)
    rows = transferTable(transferTable.metric == "max_robot_steps", :);
    fig = figure('Name', 'Makespan penalty from effort tuning', 'Color', 'w', ...
        'Units', 'inches', 'Position', [1, 1, 7.16, 5.6], 'Visible', 'off');
    layout = tiledlayout(fig, numel(targetCounts), 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    for ti = 1:numel(targetCounts)
        ax = nexttile(layout); hold(ax, 'on');
        for ai = 1:numel(algorithms)
            for ci = 1:numel(commLabels)
                entry = rows(rows.target_count == targetCounts(ti) & ...
                    rows.algorithm == algorithms(ai) & rows.comm_label == commLabels(ci), :);
                if height(entry) ~= 1
                    error('Missing makespan transfer result for figure rendering.');
                end
                x = ai + (-0.19 + 0.38 * (ci - 1));
                alpha = 1.0;
                if ci == 2, alpha = 0.45; end
                bar(ax, x, entry.percent_change_effort_vs_makespan, 0.32, ...
                    'FaceColor', algorithmColor(algorithms(ai), style), ...
                    'FaceAlpha', alpha, 'EdgeColor', [0.15, 0.15, 0.15], 'LineWidth', 0.4);
            end
        end
        yline(ax, 0, '-', 'Color', style.zeroColor, 'LineWidth', 0.65);
        xlim(ax, [0.4, numel(algorithms) + 0.6]); xticks(ax, 1:numel(algorithms));
        xticklabels(ax, algorithms); title(ax, sprintf('%d targets', targetCounts(ti)), 'FontWeight', 'normal');
        if ti < numel(targetCounts), xticklabels(ax, []); end
        formatPilotAxes(ax, style);
        text(ax, 0.99, 0.94, 'opaque=ideal; transparent=Bernoulli p=0.25', ...
            'Units', 'normalized', 'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', ...
            'FontSize', style.publicationFontSize - 1);
    end
    xlabel(layout, 'Algorithm');
    ylabel(layout, 'Makespan penalty from effort tuning (%)');
    title(layout, {'Exploratory transfer penalty: effort-selected versus makespan-selected horizon', ...
        '100 x [mean makespan(effort horizon) / mean makespan(makespan horizon) - 1]'}, ...
        'FontWeight', 'normal');
    exportPilotFigure(fig, outputStem, style);
end

function plotMechanismChanges(mechanismTable, targetCounts, algorithms, commLabels, outputStem, style)
    metrics = ["target_workload_gini", "allocation_messages"];
    labels = ["Target-workload Gini change (%)", "Allocation-message change (%)"];
    fig = figure('Name', 'Mechanism associations', 'Color', 'w', 'Units', 'inches', ...
        'Position', [1, 1, 7.16, 4.8], 'Visible', 'off');
    layout = tiledlayout(fig, numel(metrics), numel(commLabels), 'TileSpacing', 'compact', 'Padding', 'compact');
    limit = max(abs(mechanismTable.percent_change_effort_vs_makespan( ...
        ismember(mechanismTable.metric, metrics) & isfinite(mechanismTable.percent_change_effort_vs_makespan))));
    if isempty(limit) || limit == 0, limit = 1; end
    for mi = 1:numel(metrics)
        for ci = 1:numel(commLabels)
            ax = nexttile(layout); matrix = nan(numel(targetCounts), numel(algorithms));
            for ti = 1:numel(targetCounts)
                for ai = 1:numel(algorithms)
                    entry = mechanismTable(mechanismTable.target_count == targetCounts(ti) & ...
                        mechanismTable.algorithm == algorithms(ai) & ...
                        mechanismTable.comm_label == commLabels(ci) & ...
                        mechanismTable.metric == metrics(mi), :);
                    if height(entry) == 1
                        matrix(ti, ai) = entry.percent_change_effort_vs_makespan;
                    end
                end
            end
            imagesc(ax, matrix); caxis(ax, [-limit, limit]); colormap(ax, pilotRedBlueMap(256));
            set(ax, 'XTick', 1:numel(algorithms), 'XTickLabel', algorithms, ...
                'YTick', 1:numel(targetCounts), 'YTickLabel', string(targetCounts) + " targets");
            for ti = 1:size(matrix, 1)
                for ai = 1:size(matrix, 2)
                    if isfinite(matrix(ti, ai))
                        text(ax, ai, ti, sprintf('%.1f', matrix(ti, ai)), ...
                            'HorizontalAlignment', 'center', 'FontSize', style.publicationFontSize - 1);
                    end
                end
            end
            formatPilotAxes(ax, style);
            title(ax, labels(mi) + " — " + commLabels(ci), 'FontWeight', 'normal');
        end
    end
    colorbarHandle = colorbar; colorbarHandle.Layout.Tile = 'east';
    colorbarHandle.Label.String = 'Effort-selected versus makespan-selected horizon (%)';
    title(layout, {'Mechanism associations (exploratory, not causal proof)', ...
        'Positive values mean greater Gini or message traffic at the effort-selected horizon'}, ...
        'FontWeight', 'normal');
    exportPilotFigure(fig, outputStem, style);
end

function plotAlgorithmRankings(rankingTable, targetCounts, algorithms, commLabels, outputStem, style)
    objectives = ["effort_selected", "makespan_selected"];
    fig = figure('Name', 'Algorithm rankings under tuning objectives', 'Color', 'w', ...
        'Units', 'inches', 'Position', [1, 1, 7.16, 7.0], 'Visible', 'off');
    layout = tiledlayout(fig, numel(targetCounts), numel(commLabels), 'TileSpacing', 'compact', 'Padding', 'compact');
    for ti = 1:numel(targetCounts)
        for ci = 1:numel(commLabels)
            ax = nexttile(layout); matrix = nan(numel(algorithms), numel(objectives));
            for ai = 1:numel(algorithms)
                for oi = 1:numel(objectives)
                    entry = rankingTable(rankingTable.target_count == targetCounts(ti) & ...
                        rankingTable.comm_label == commLabels(ci) & ...
                        rankingTable.algorithm == algorithms(ai) & ...
                        rankingTable.tuning_objective == objectives(oi), :);
                    if height(entry) == 1, matrix(ai, oi) = entry.rank; end
                end
            end
            imagesc(ax, matrix); colormap(ax, flipud(parula(5))); caxis(ax, [1, 5]);
            set(ax, 'XTick', 1:2, 'XTickLabel', {"Effort-tuned", "Makespan-tuned"}, ...
                'YTick', 1:numel(algorithms), 'YTickLabel', algorithms);
            for ai = 1:size(matrix, 1)
                for oi = 1:size(matrix, 2)
                    text(ax, oi, ai, sprintf('%.0f', matrix(ai, oi)), ...
                        'HorizontalAlignment', 'center', 'FontWeight', 'bold');
                end
            end
            title(ax, sprintf('%d targets — %s', targetCounts(ti), commLabels(ci)), ...
                'FontWeight', 'normal');
            formatPilotAxes(ax, style);
        end
    end
    colorbarHandle = colorbar; colorbarHandle.Layout.Tile = 'east';
    colorbarHandle.Label.String = 'Rank (1 = lowest mean selected objective)';
    title(layout, 'Algorithm rankings under effort-based and makespan-based tuning', ...
        'FontWeight', 'normal');
    exportPilotFigure(fig, outputStem, style);
end

function color = algorithmColor(algorithm, style)
    index = find(style.algorithmKeys == algorithm, 1, 'first');
    if isempty(index)
        error('Algorithm %s is missing from final_figure_style.', algorithm);
    end
    color = style.colors(index, :);
end

function formatPilotAxes(ax, style)
    grid(ax, 'on'); box(ax, 'on');
    set(ax, 'FontName', 'Arial', 'FontSize', style.axesFontSize, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, ...
        'LineWidth', style.axisLineWidth, 'GridAlpha', style.gridAlpha, ...
        'MinorGridAlpha', style.gridAlpha / 2, 'TickDir', 'out', 'Layer', 'top');
end

function exportPilotFigure(fig, outputStem, style)
    activeTypography = which('apply_publication_figure_typography');
    if ~isempty(activeTypography)
        apply_publication_figure_typography(fig, style);
    else
        fontObjects = findall(fig, '-property', 'FontSize');
        for i = 1:numel(fontObjects)
            try, fontObjects(i).FontSize = style.publicationFontSize; catch, end
        end
    end
    drawnow;
    pngPath = string(outputStem) + ".png";
    figPath = string(outputStem) + ".fig";
    print(fig, char(pngPath), '-dpng', sprintf('-r%d', style.exportDpi));
    savefig(fig, char(figPath));
    close(fig);
end

function cmap = pilotRedBlueMap(n)
    low = [0.20, 0.35, 0.85]; mid = [1.00, 1.00, 1.00]; high = [0.85, 0.20, 0.20];
    half = floor(n / 2);
    lower = [linspace(low(1), mid(1), half)', linspace(low(2), mid(2), half)', ...
        linspace(low(3), mid(3), half)'];
    upper = [linspace(mid(1), high(1), n - half)', linspace(mid(2), high(2), n - half)', ...
        linspace(mid(3), high(3), n - half)'];
    cmap = [lower; upper];
end

function V = emptyValidationTable()
    V = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
        'VariableNames', {'check_id', 'status', 'expected', 'observed', 'details'});
end

function V = addValidation(V, checkId, passed, expected, observed, details)
    status = "PASS";
    if ~passed, status = "FAIL"; end
    V = [V; table(string(checkId), status, string(expected), string(observed), string(details), ...
        'VariableNames', V.Properties.VariableNames)]; %#ok<AGROW>
end

function T = normalizeOutputTable(T, numericFields, stringFields, logicalFields)
    for name = numericFields
        raw = T.(char(name));
        if isnumeric(raw) || islogical(raw)
            value = double(raw);
        else
            value = str2double(string(raw));
        end
        T.(char(name)) = value(:);
    end
    for name = stringFields
        T.(char(name)) = string(T.(char(name)));
    end
    for name = logicalFields
        raw = T.(char(name));
        if islogical(raw)
            value = raw;
        elseif isnumeric(raw)
            value = raw ~= 0;
        else
            value = ismember(lower(strtrim(string(raw))), ["true", "1", "yes"]);
        end
        T.(char(name)) = logical(value(:));
    end
end
