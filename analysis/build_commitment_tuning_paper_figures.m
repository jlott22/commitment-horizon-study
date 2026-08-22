% BUILD_COMMITMENT_TUNING_PAPER_FIGURES
% Build the two IEEE single-column commitment-horizon manuscript figures.
% This MATLAB-only workflow reads immutable CSV inputs and writes only to
% analysis/paper_figures. It can be run from any MATLAB working directory.

scriptDir = fileparts(mfilename('fullpath'));
experimentRoot = fileparts(scriptDir);
repoRoot = experimentRoot;
outputDir = fullfile(scriptDir, 'paper_figures');
if ~isfolder(outputDir), mkdir(outputDir); end

coreFile = fullfile(repoRoot, 'reference_core_benchmark_pilot', 'combined', ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv');
penaltyFile = fullfile(scriptDir, 'tables', 'pilot_objective_transfer_penalties.csv');
mustExist(coreFile, 'Primary 300-trial CV system-performance CSV');
mustExist(penaltyFile, 'Target-load transfer-penalty CSV');

algorithms = ["ACBBA", "DGA", "DMCHBA", "HIPC", "PI"];
horizons = [1, 2, 3, 5, 8, 12];
comms = ["ideal", "bernoulli_025"];
colors = [0.000 0.447 0.741; 0.850 0.325 0.098; 0.466 0.674 0.188; ...
          0.494 0.184 0.556; 0.301 0.745 0.933];
markers = {'o', 's', '^', 'd', 'v'};
publicationFontSize = 8.0;
validation = strings(0, 1);
warnings = strings(0, 1);

%% Validate core data and its raw-mean selector.
core = readtable(coreFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
requiredCore = ["trial_id", "algorithm", "comm_label", "value", "trial_status", ...
    "total_team_steps", "max_robot_steps"];
requireColumns(core, requiredCore, coreFile);
core.algorithm = string(core.algorithm);
core.comm_label = string(core.comm_label);
core.trial_status = string(core.trial_status);
core.value = double(core.value);
core.trial_id = double(core.trial_id);
validation(end+1) = sprintf('core_rows=%d', height(core));

expectedEffort = [2, 1, 1, 12, 5];
expectedMakespan = [1, 1, 1, 1, 1];
selectedEffort = zeros(1, numel(algorithms));
selectedMakespan = zeros(1, numel(algorithms));
for a = 1:numel(algorithms)
    algorithm = algorithms(a);
    for h = horizons
        for comm = comms
            idx = core.algorithm == algorithm & core.value == h & core.comm_label == comm;
            block = core(idx, :);
            assertCondition(height(block) == 300, sprintf('%s h=%g %s has %d rows; expected 300.', ...
                algorithm, h, comm, height(block)));
            assertCondition(all(block.trial_status == "completed"), sprintf('%s h=%g %s has non-completed trials.', ...
                algorithm, h, comm));
            assertCondition(numel(unique(block.trial_id)) == 300, sprintf('%s h=%g %s has duplicate trial IDs.', ...
                algorithm, h, comm));
            assertCondition(all(isfinite(block.total_team_steps) & block.total_team_steps > 0), ...
                sprintf('%s h=%g %s has invalid total_team_steps.', algorithm, h, comm));
            assertCondition(all(isfinite(block.max_robot_steps) & block.max_robot_steps > 0), ...
                sprintf('%s h=%g %s has invalid max_robot_steps.', algorithm, h, comm));
        end
    end
    selectedEffort(a) = rawMeanSelection(core, algorithm, horizons, 'total_team_steps');
    selectedMakespan(a) = rawMeanSelection(core, algorithm, horizons, 'max_robot_steps');
    assertCondition(selectedEffort(a) == expectedEffort(a), sprintf( ...
        'Raw effort selector mismatch for %s: observed h=%g, expected h=%g.', ...
        algorithm, selectedEffort(a), expectedEffort(a)));
    assertCondition(selectedMakespan(a) == expectedMakespan(a), sprintf( ...
        'Raw makespan selector mismatch for %s: observed h=%g, expected h=%g.', ...
        algorithm, selectedMakespan(a), expectedMakespan(a)));
    validation(end+1) = sprintf('core_%s: selected effort h=%g; makespan h=%g', ...
        algorithm, selectedEffort(a), selectedMakespan(a));
end

%% Validate target-load penalty data and its horizon pairs.
penalties = readtable(penaltyFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
requiredPenalty = ["target_count", "algorithm", "comm_label", "effort_selected_horizon", ...
    "makespan_selected_horizon", "metric", "makespan_penalty_pct", ...
    "paired_bootstrap_percent_change_ci95_lower", "paired_bootstrap_percent_change_ci95_upper"];
requireColumns(penalties, requiredPenalty, penaltyFile);
penalties.algorithm = string(penalties.algorithm);
penalties.comm_label = string(penalties.comm_label);
penalties.metric = string(penalties.metric);
penalties.target_count = double(penalties.target_count);
penalties = penalties(penalties.metric == "max_robot_steps" & ...
    ismember(penalties.target_count, [5, 10, 20]) & ismember(penalties.comm_label, comms), :);
assertCondition(height(penalties) == 30, sprintf('Expected 30 makespan transfer rows; found %d.', height(penalties)));
validation(end+1) = sprintf('target_load_penalty_rows=%d', height(penalties));

expectedPairs = [5 1; 1 1; 1 5; 5 1; 3 1; ...
                 2 1; 1 3; 1 1; 12 1; 5 1; ...
                 2 2; 5 5; 12 12; 12 1; 3 1];
pairRow = 0;
for t = [5, 10, 20]
    for a = 1:numel(algorithms)
        pairRow = pairRow + 1;
        for comm = comms
            idx = penalties.target_count == t & penalties.algorithm == algorithms(a) & penalties.comm_label == comm;
            assertCondition(nnz(idx) == 1, sprintf('Expected one penalty row for t=%g, %s, %s; found %d.', ...
                t, algorithms(a), comm, nnz(idx)));
            row = penalties(idx, :);
            lower = double(row.paired_bootstrap_percent_change_ci95_lower);
            upper = double(row.paired_bootstrap_percent_change_ci95_upper);
            estimate = double(row.makespan_penalty_pct);
            assertCondition(isfinite(estimate) && isfinite(lower) && isfinite(upper), ...
                sprintf('Non-finite penalty or interval for t=%g, %s, %s.', t, algorithms(a), comm));
            assertCondition(lower <= upper, sprintf('Reversed interval for t=%g, %s, %s.', t, algorithms(a), comm));
            assertCondition(double(row.effort_selected_horizon) == expectedPairs(pairRow, 1) && ...
                double(row.makespan_selected_horizon) == expectedPairs(pairRow, 2), sprintf( ...
                'Horizon-pair mismatch for t=%g, %s, %s: observed %g/%g, expected %g/%g.', ...
                t, algorithms(a), comm, row.effort_selected_horizon, row.makespan_selected_horizon, ...
                expectedPairs(pairRow, 1), expectedPairs(pairRow, 2)));
        end
        validation(end+1) = sprintf('target_load_t=%g_%s: selected h=%g/%g', ...
            t, algorithms(a), expectedPairs(pairRow,1), expectedPairs(pairRow,2));
    end
end

%% Figure 1: 2-wide by 3-tall primary-CV response surfaces.
fig1 = figure('Color', 'white', 'Units', 'inches', 'Position', [1 1 3.45 5.45], ...
    'PaperPositionMode', 'auto', 'Visible', 'off');
layout1 = tiledlayout(fig1, 3, 2, 'TileSpacing', 'compact', 'Padding', 'loose');
effortHandles = gobjects(1, 1); makespanHandles = gobjects(1, 1);
for a = 1:numel(algorithms)
    ax = nexttile(layout1, a); hold(ax, 'on');
    [effortDisplay, makespanDisplay] = displayResponseValues(core, algorithms(a), horizons);
    yline(ax, 1, '-', 'Color', [0.78 0.78 0.78], 'LineWidth', 0.8, 'HandleVisibility', 'off');
    pEffort = plot(ax, horizons, effortDisplay, '-o', 'Color', [0 0.447 0.741], ...
        'MarkerFaceColor', [0 0.447 0.741], 'LineWidth', 1.25, 'MarkerSize', 4.3);
    pMakespan = plot(ax, horizons, makespanDisplay, '-s', 'Color', [0.850 0.325 0.098], ...
        'MarkerFaceColor', [0.850 0.325 0.098], 'LineWidth', 1.25, 'MarkerSize', 4.3);
    plot(ax, selectedEffort(a), effortDisplay(horizons == selectedEffort(a)), 'o', ...
        'Color', [0 0.447 0.741], 'MarkerFaceColor', 'white', 'LineWidth', 1.35, 'MarkerSize', 7.0, ...
        'HandleVisibility', 'off');
    plot(ax, selectedMakespan(a), makespanDisplay(horizons == selectedMakespan(a)), 's', ...
        'Color', [0.850 0.325 0.098], 'MarkerFaceColor', 'white', 'LineWidth', 1.35, 'MarkerSize', 7.0, ...
        'HandleVisibility', 'off');
    xlim(ax, [0.75 12.25]); xticks(ax, horizons);
    title(ax, sprintf('(%s) %s', char('a' + a - 1), algorithms(a)), ...
        'FontWeight', 'normal', 'FontSize', publicationFontSize);
    set(ax, 'FontName', 'Arial', 'FontSize', publicationFontSize, 'LineWidth', 0.65, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, 'Box', 'on', 'Layer', 'top');
    padTightY(ax, [effortDisplay, makespanDisplay, 1]);
    if a <= 4
        xticklabels(ax, []);
    end
    if a == 1
        effortHandles = pEffort; makespanHandles = pMakespan;
    end
end
legend1 = legend([effortHandles makespanHandles], {'Effort', 'Makespan'}, ...
    'Orientation', 'vertical', 'Box', 'off', 'FontSize', publicationFontSize);
legend1.Layout.Tile = 6;
xlabel(layout1, 'Commitment horizon', 'FontSize', publicationFontSize, 'FontWeight', 'normal');
ylabel(layout1, 'Relative mean', 'FontSize', publicationFontSize, 'FontWeight', 'normal');
applyUniformTypography(fig1, publicationFontSize);
assertUniformTypography(fig1, publicationFontSize, 'cv_objective_response_surfaces');
validation(end+1) = sprintf('cv_objective_response_surfaces_typography=all %.1f pt', publicationFontSize);
drawnow;
exportFigureTriplet(fig1, outputDir, 'cv_objective_response_surfaces');
close(fig1);

%% Figure 2: vertically stacked target-load makespan penalties.
allBounds = [double(penalties.paired_bootstrap_percent_change_ci95_lower); ...
             double(penalties.paired_bootstrap_percent_change_ci95_upper); 0];
yMin = min(allBounds); yMax = max(allBounds); yPad = max(1, 0.08 * (yMax - yMin));
sharedYLim = [min(0, yMin - yPad), max(0, yMax + yPad)];
fig2 = figure('Color', 'white', 'Units', 'inches', 'Position', [1 1 3.45 5.70], ...
    'PaperPositionMode', 'auto', 'Visible', 'off');
layout2 = tiledlayout(fig2, 2, 1, 'TileSpacing', 'compact', 'Padding', 'loose');
plotHandles = gobjects(1, numel(algorithms));
for c = 1:numel(comms)
    ax = nexttile(layout2, c); hold(ax, 'on');
    yline(ax, 0, '--', 'Color', [0.45 0.45 0.45], 'LineWidth', 0.9, 'HandleVisibility', 'off');
    for a = 1:numel(algorithms)
        rows = penalties(penalties.algorithm == algorithms(a) & penalties.comm_label == comms(c), :);
        [~, order] = sort(double(rows.target_count)); rows = rows(order, :);
        x = double(rows.target_count); y = double(rows.makespan_penalty_pct);
        lowerErr = y - double(rows.paired_bootstrap_percent_change_ci95_lower);
        upperErr = double(rows.paired_bootstrap_percent_change_ci95_upper) - y;
        h = errorbar(ax, x, y, lowerErr, upperErr, ['-' markers{a}], ...
            'Color', colors(a, :), 'MarkerFaceColor', 'white', 'LineWidth', 1.2, ...
            'MarkerSize', 5.0, 'CapSize', 4);
        if c == 1, plotHandles(a) = h; end
    end
    xlim(ax, [4.2 20.8]); xticks(ax, [5 10 20]); ylim(ax, sharedYLim);
    if c == 1
        title(ax, '(a) Ideal communication', 'FontWeight', 'normal', 'FontSize', publicationFontSize);
        xticklabels(ax, []);
    else
        title(ax, '(b) 25% packet loss', 'FontWeight', 'normal', 'FontSize', publicationFontSize);
        xlabel(ax, 'Target count', 'FontSize', publicationFontSize, 'FontWeight', 'normal');
    end
    set(ax, 'FontName', 'Arial', 'FontSize', publicationFontSize, 'LineWidth', 0.65, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, 'Box', 'on', 'Layer', 'top');
end
legend2 = legend(plotHandles, cellstr(algorithms), 'Orientation', 'horizontal', ...
    'NumColumns', 3, 'Box', 'off', 'FontSize', publicationFontSize);
legend2.Layout.Tile = 'south';
ylabel(layout2, 'Makespan penalty (%)', 'Interpreter', 'none', ...
    'FontSize', publicationFontSize, 'FontWeight', 'normal');
applyUniformTypography(fig2, publicationFontSize);
assertUniformTypography(fig2, publicationFontSize, 'target_load_makespan_penalty');
validation(end+1) = sprintf('target_load_makespan_penalty_typography=all %.1f pt', publicationFontSize);
drawnow;
exportFigureTriplet(fig2, outputDir, 'target_load_makespan_penalty');
close(fig2);

%% Write the report only after both figures have validated and exported.
reportFile = fullfile(outputDir, 'figure_generation_validation.txt');
fid = fopen(reportFile, 'w');
assertCondition(fid >= 0, sprintf('Could not write validation report: %s', reportFile));
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, 'Commitment-horizon paper figure generation validation\n');
fprintf(fid, 'Generated: %s\n\n', datestr(now, 31));
fprintf(fid, 'Input paths:\n  %s\n  %s\n\n', coreFile, penaltyFile);
fprintf(fid, 'Validation checks:\n');
fprintf(fid, '  %s\n', validation);
fprintf(fid, '\nFigure dimensions:\n');
fprintf(fid, '  cv_objective_response_surfaces: 3.45 x 5.45 inches; 3 x 2 tiles\n');
fprintf(fid, '  target_load_makespan_penalty: 3.45 x 5.70 inches; 2 x 1 tiles\n');
fprintf(fid, '\nOutputs (editable FIG, 300-dpi PNG, vector PDF):\n');
for base = ["cv_objective_response_surfaces", "target_load_makespan_penalty"]
    fprintf(fid, '  %s.fig\n  %s.png\n  %s.pdf\n', base, base, base);
end
if isempty(warnings)
    fprintf(fid, '\nWarnings: none\n');
else
    fprintf(fid, '\nWarnings:\n  %s\n', warnings);
end
fprintf('Created validated publication figures in:\n%s\n', outputDir);

function selected = rawMeanSelection(core, algorithm, horizons, metric)
    means = zeros(size(horizons));
    for k = 1:numel(horizons)
        h = horizons(k);
        ideal = pairedCell(core, algorithm, h, "ideal", metric);
        bernoulli = pairedCell(core, algorithm, h, "bernoulli_025", metric);
        assertCondition(isequal(ideal.trial_id, bernoulli.trial_id), sprintf( ...
            'Unpaired ideal/Bernoulli trial IDs for %s h=%g %s.', algorithm, h, metric));
        means(k) = mean(0.5 * (ideal.value + bernoulli.value));
    end
    [~, index] = min(means); % horizons are ascending, so exact ties use the smaller horizon.
    selected = horizons(index);
end

function [effortDisplay, makespanDisplay] = displayResponseValues(core, algorithm, horizons)
    effortDisplay = displayMetric(core, algorithm, horizons, 'total_team_steps');
    makespanDisplay = displayMetric(core, algorithm, horizons, 'max_robot_steps');
end

function displayValues = displayMetric(core, algorithm, horizons, metric)
    byComm = zeros(2, numel(horizons));
    for c = 1:2
        comm = ["ideal", "bernoulli_025"];
        for k = 1:numel(horizons)
            cellData = pairedCell(core, algorithm, horizons(k), comm(c), metric);
            byComm(c, k) = mean(cellData.value);
        end
        byComm(c, :) = byComm(c, :) ./ min(byComm(c, :));
    end
    displayValues = mean(byComm, 1);
end

function cellData = pairedCell(core, algorithm, horizon, comm, metric)
    idx = core.algorithm == algorithm & core.value == horizon & core.comm_label == comm;
    cellData = table(core.trial_id(idx), double(core.(metric)(idx)), 'VariableNames', {'trial_id', 'value'});
    cellData = sortrows(cellData, 'trial_id');
end

function exportFigureTriplet(fig, outputDir, baseName)
    savefig(fig, fullfile(outputDir, baseName + ".fig"));
    exportgraphics(fig, fullfile(outputDir, baseName + ".png"), 'Resolution', 300, 'Padding', 'figure');
    exportgraphics(fig, fullfile(outputDir, baseName + ".pdf"), 'ContentType', 'vector', 'Padding', 'figure');
end

function padTightY(ax, values)
    lower = min(values); upper = max(values); span = upper - lower;
    padding = max(0.018, 0.14 * max(span, 0.01));
    ylim(ax, [max(0.90, lower - padding), upper + padding]);
end

function applyUniformTypography(fig, fontSize)
    axesObjects = findall(fig, 'Type', 'axes');
    for k = 1:numel(axesObjects)
        axesObjects(k).FontSize = fontSize;
        axesObjects(k).TitleFontSizeMultiplier = 1;
        axesObjects(k).LabelFontSizeMultiplier = 1;
    end
    layouts = findall(fig, 'Type', 'tiledlayout');
    for k = 1:numel(layouts)
        layouts(k).XLabel.FontSize = fontSize;
        layouts(k).YLabel.FontSize = fontSize;
        layouts(k).Title.FontSize = fontSize;
    end
    fontObjects = findall(fig, '-property', 'FontSize');
    for k = 1:numel(fontObjects), fontObjects(k).FontSize = fontSize; end
end

function assertUniformTypography(fig, fontSize, figureName)
    fontObjects = findall(fig, '-property', 'FontSize');
    observed = zeros(numel(fontObjects), 1);
    for k = 1:numel(fontObjects), observed(k) = double(fontObjects(k).FontSize); end
    assertCondition(all(abs(observed - fontSize) < 1e-9), sprintf( ...
        '%s contains text that is not %.1f pt.', figureName, fontSize));
end

function requireColumns(tab, columns, source)
    missing = columns(~ismember(columns, string(tab.Properties.VariableNames)));
    assertCondition(isempty(missing), sprintf('Missing required columns in %s: %s.', source, strjoin(missing, ', ')));
end

function mustExist(path, description)
    assertCondition(isfile(path), sprintf('%s not found: %s', description, path));
end

function assertCondition(condition, message)
    if ~condition, error('commitment_tuning_figures:validation', '%s', message); end
end
