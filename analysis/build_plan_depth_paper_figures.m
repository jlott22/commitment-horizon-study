% BUILD_PLAN_DEPTH_PAPER_FIGURES
% Build the two single-column plan-depth figures from published CSV results.
% The script is MATLAB-only, runs from any working directory, and writes only
% beneath analysis/paper_figures.

scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(scriptDir);
outputDir = fullfile(scriptDir, 'paper_figures');
sourceDir = fullfile(outputDir, 'source_data');
if ~isfolder(outputDir), mkdir(outputDir); end
if ~isfolder(sourceDir), mkdir(sourceDir); end

requiredCommit = "0bb9d4fbc42a717a8c40c0ca29af547af5a77f31";
primaryFile = fullfile(repoRoot, 'reference_core_benchmark_pilot', 'combined', ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv');
loadFile = fullfile(repoRoot, 'results', 'combined', ...
    'target_load_horizon_pilot_25_combined_system_performance.csv');
algorithms = ["ACBBA", "HIPC", "PI"];
horizons = [1, 2, 3, 5, 8, 12];
comms = ["ideal", "bernoulli_025"];
% Match dcta_benchmark_sim/results/analysis/final_figure_style.m exactly.
fontSize = 8.0;
fontName = 'Helvetica';

mustExist(primaryFile, 'Corrected primary ten-target system-performance CSV');
mustExist(loadFile, 'Five- and twenty-target system-performance CSV');
archiveToken = lower(fullfile('archive', 'pre_completion_retention_acbba_hipc'));
assertCondition(~contains(lower(primaryFile), archiveToken), ...
    'The primary input resolved inside the prohibited pre-completion-retention archive.');
expectedPrimary = fullfile(repoRoot, 'reference_core_benchmark_pilot', 'combined', ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv');
assertCondition(strcmp(canonicalPath(primaryFile), canonicalPath(expectedPrimary)), ...
    'The primary input is not the corrected canonical CSV.');

[gitStatus, repoCommit] = system(sprintf('git -C "%s" rev-parse HEAD', repoRoot));
assertCondition(gitStatus == 0, 'Could not determine the repository commit with git rev-parse.');
repoCommit = strtrim(string(repoCommit));
ancestorStatus = system(sprintf('git -C "%s" merge-base --is-ancestor %s HEAD', ...
    repoRoot, requiredCommit));
assertCondition(ancestorStatus == 0, sprintf( ...
    'Repository HEAD %s does not descend from required corrected-data commit %s.', ...
    repoCommit, requiredCommit));

%% Read, standardize, and validate the corrected primary evidence.
primaryAll = readtable(primaryFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
requiredColumns = ["trial_id", "algorithm", "comm_label", "target_count", "value", ...
    "trial_status", "total_team_steps", "max_robot_steps"];
requireColumns(primaryAll, requiredColumns, primaryFile);
primaryAll = standardizeSystemTable(primaryAll);
primary = primaryAll(primaryAll.trial_status == "completed" & ...
    ismember(primaryAll.algorithm, algorithms) & ...
    ismember(primaryAll.comm_label, comms) & ...
    ismember(primaryAll.horizon, horizons) & primaryAll.target_count == 10, :);
assertCondition(height(primary) == 10800, sprintf( ...
    'Corrected primary filter retained %d rows; expected exactly 10,800.', height(primary)));
expectedPrimaryIds = (0:299)';
validateCells(primary, algorithms, horizons, comms, 10, expectedPrimaryIds, 'primary');
if ismember('stage', primaryAll.Properties.VariableNames)
    correctedRows = ismember(primaryAll.algorithm, ["ACBBA", "HIPC"]);
    assertCondition(all(primaryAll.stage(correctedRows) == "completion_retention_integrated"), ...
        'ACBBA/HIPC primary rows do not carry the corrected completion-retention provenance stage.');
end

primarySource = summarizeResponses(primary, algorithms, horizons, comms, 10, 300);
expectedMeans = table( ...
    ["ACBBA"; "ACBBA"; "HIPC"; "HIPC"; "PI"; "PI"], ...
    [1; 12; 1; 12; 1; 12], ...
    [80.9300; 65.5600; 77.7533; 53.0667; 80.4933; 61.9667], ...
    [23.4100; 34.0867; 23.3233; 39.0800; 23.5067; 45.6833], ...
    'VariableNames', {'algorithm', 'horizon', 'mean_effort', 'mean_makespan'});
meanTolerance = 5.1e-4;
for k = 1:height(expectedMeans)
    idx = primarySource.algorithm == expectedMeans.algorithm(k) & ...
        primarySource.comm_label == "ideal" & ...
        primarySource.horizon == expectedMeans.horizon(k);
    assertCondition(nnz(idx) == 1, 'A required corrected ideal-network mean cell is missing.');
    assertCondition(abs(primarySource.mean_effort(idx) - expectedMeans.mean_effort(k)) <= meanTolerance, ...
        sprintf('%s h=%g ideal effort mean is %.6f; expected %.4f.', ...
        expectedMeans.algorithm(k), expectedMeans.horizon(k), ...
        primarySource.mean_effort(idx), expectedMeans.mean_effort(k)));
    assertCondition(abs(primarySource.mean_makespan(idx) - expectedMeans.mean_makespan(k)) <= meanTolerance, ...
        sprintf('%s h=%g ideal makespan mean is %.6f; expected %.4f.', ...
        expectedMeans.algorithm(k), expectedMeans.horizon(k), ...
        primarySource.mean_makespan(idx), expectedMeans.mean_makespan(k)));
end

%% Assemble the balanced 25-scenario target-load sensitivity evidence.
loadAll = readtable(loadFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
requireColumns(loadAll, requiredColumns, loadFile);
loadAll = standardizeSystemTable(loadAll);
loadSubset = loadAll(loadAll.trial_status == "completed" & ...
    ismember(loadAll.algorithm, algorithms) & ...
    ismember(loadAll.comm_label, comms) & ...
    ismember(loadAll.horizon, horizons) & ...
    ismember(loadAll.target_count, [5, 20]) & ...
    ismember(loadAll.trial_id, 0:24), :);
assertCondition(height(loadSubset) == 1800, sprintf( ...
    'Five/twenty-target filter retained %d rows; expected exactly 1,800.', height(loadSubset)));
balancedTen = primary(ismember(primary.trial_id, 0:24), :);
assertCondition(height(balancedTen) == 900, sprintf( ...
    'Balanced ten-target filter retained %d rows; expected exactly 900.', height(balancedTen)));
targetLoad = [loadSubset; balancedTen];
assertCondition(height(targetLoad) == 2700, sprintf( ...
    'Combined 5/10/20 source contains %d observations; expected exactly 2,700.', height(targetLoad)));
expectedLoadIds = (0:24)';
for targetCount = [5, 10, 20]
    validateCells(targetLoad, algorithms, horizons, comms, targetCount, expectedLoadIds, ...
        sprintf('%d-target', targetCount));
end
targetSource = summarizeResponses(targetLoad, algorithms, horizons, comms, [5, 10, 20], 25);

expectedHipcMax = [81.953, 85.456, 85.674];
observedHipcMax = zeros(1, 3);
for k = 1:3
    targetCount = [5, 10, 20];
    idx = targetSource.algorithm == "HIPC" & targetSource.comm_label == "ideal" & ...
        targetSource.target_count == targetCount(k);
    observedHipcMax(k) = max(targetSource.divergence_pct_points(idx));
    assertCondition(abs(observedHipcMax(k) - expectedHipcMax(k)) <= 0.01, sprintf( ...
        'HIPC maximum ideal divergence for %d targets is %.6f; expected approximately %.3f.', ...
        targetCount(k), observedHipcMax(k), expectedHipcMax(k)));
end
validateLines(primarySource, algorithms, horizons, comms, 10, 'primary response');
validateLines(targetSource, algorithms, horizons, comms, [5, 10, 20], 'target-load divergence');

% These are the exact numerical sources used by the two figures.
primarySourceFile = fullfile(sourceDir, 'cv_network_conditioned_response_curves_source.csv');
targetSourceFile = fullfile(sourceDir, 'target_load_objective_divergence_source.csv');
writetable(primarySource, primarySourceFile);
writetable(targetSource, targetSourceFile);

%% Figure 1: network-conditioned primary ten-target response curves.
fig1Width = 3.45; fig1Height = 4.80;
fig1 = makeFigure(fig1Width, fig1Height);
layout1 = tiledlayout(fig1, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
responseHandles = gobjects(1, 4);
blue = [0.000, 0.365, 0.675];
red = [0.800, 0.220, 0.160];
allQ = [primarySource.Q_effort; primarySource.Q_makespan; 1];
qSpan = max(allQ) - min(allQ);
qPad = max(0.025, 0.06 * max(qSpan, 0.01));
sharedQLimit = [min(allQ) - qPad, max(allQ) + qPad];
for a = 1:numel(algorithms)
    ax = nexttile(layout1, a); hold(ax, 'on');
    yline(ax, 1, '-', 'Color', [0.78, 0.78, 0.78], 'LineWidth', 0.75, ...
        'HandleVisibility', 'off');
    rows = primarySource(primarySource.algorithm == algorithms(a), :);
    ideal = sortrows(rows(rows.comm_label == "ideal", :), 'horizon');
    loss = sortrows(rows(rows.comm_label == "bernoulli_025", :), 'horizon');
    responseHandles(1) = plot(ax, ideal.horizon, ideal.Q_effort, '-o', ...
        'Color', blue, 'MarkerFaceColor', blue, 'LineWidth', 1.25, 'MarkerSize', 4.6);
    responseHandles(2) = plot(ax, ideal.horizon, ideal.Q_makespan, '-s', ...
        'Color', red, 'MarkerFaceColor', red, 'LineWidth', 1.25, 'MarkerSize', 4.6);
    responseHandles(3) = plot(ax, loss.horizon, loss.Q_effort, '--o', ...
        'Color', blue, 'MarkerFaceColor', 'white', 'LineWidth', 1.25, 'MarkerSize', 4.6);
    responseHandles(4) = plot(ax, loss.horizon, loss.Q_makespan, '--s', ...
        'Color', red, 'MarkerFaceColor', 'white', 'LineWidth', 1.25, 'MarkerSize', 4.6);
    formatPanel(ax, algorithms(a), a, horizons, fontSize, fontName);
    ylim(ax, sharedQLimit);
    if a < numel(algorithms), xticklabels(ax, []); else, xlabel(ax, 'Plan depth, h'); end
end
ylabel(layout1, 'Normalized response, Q');
legend1 = legend(responseHandles, {'Ideal effort', 'Ideal makespan', ...
    '25% loss effort', '25% loss makespan'}, 'Orientation', 'horizontal', ...
    'NumColumns', 2, 'Box', 'off');
legend1.Layout.Tile = 'south';
applyUniformTypography(fig1, fontSize, fontName);

%% Figure 2: objective divergence across balanced target loads.
fig2Width = 3.45; fig2Height = 5.00;
fig2 = makeFigure(fig2Width, fig2Height);
layout2 = tiledlayout(fig2, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
loadColors = [0.000, 0.365, 0.675; 0.850, 0.325, 0.098; 0.220, 0.570, 0.280];
loadMarkers = {'o', 's', '^'};
loads = [5, 10, 20];
allD = targetSource.divergence_pct_points;
dSpan = max(allD) - min(allD);
dPad = max(3.0, 0.06 * max(dSpan, 1));
sharedDLimit = [min(0, min(allD) - dPad), max(0, max(allD) + dPad)];
divergenceHandles = gobjects(1, 6);
for a = 1:numel(algorithms)
    ax = nexttile(layout2, a); hold(ax, 'on');
    yline(ax, 0, '-', 'Color', [0.72, 0.72, 0.72], 'LineWidth', 0.75, ...
        'HandleVisibility', 'off');
    handleIndex = 0;
    for t = 1:numel(loads)
        for c = 1:numel(comms)
            handleIndex = handleIndex + 1;
            rows = targetSource(targetSource.algorithm == algorithms(a) & ...
                targetSource.target_count == loads(t) & targetSource.comm_label == comms(c), :);
            rows = sortrows(rows, 'horizon');
            if c == 1
                lineStyle = '-'; markerFace = loadColors(t, :);
            else
                lineStyle = '--'; markerFace = 'white';
            end
            divergenceHandles(handleIndex) = plot(ax, rows.horizon, rows.divergence_pct_points, ...
                'LineStyle', lineStyle, 'Marker', loadMarkers{t}, 'Color', loadColors(t, :), ...
                'MarkerFaceColor', markerFace, 'LineWidth', 1.25, 'MarkerSize', 4.6);
        end
    end
    formatPanel(ax, algorithms(a), a, horizons, fontSize, fontName);
    ylim(ax, sharedDLimit);
    if a < numel(algorithms), xticklabels(ax, []); else, xlabel(ax, 'Plan depth, h'); end
end
ylabel(layout2, 'Objective divergence, D (percentage points)');
legend2 = legend(divergenceHandles, {'T=5 ideal', 'T=5 loss', 'T=10 ideal', ...
    'T=10 loss', 'T=20 ideal', 'T=20 loss'}, 'Orientation', 'horizontal', ...
    'NumColumns', 3, 'Box', 'off');
legend2.Layout.Tile = 'south';
applyUniformTypography(fig2, fontSize, fontName);

% Layout and typography must pass before any figure is exported.
responseAxes = findall(fig1, 'Type', 'axes');
responseYLimits = vertcat(responseAxes.YLim);
assertCondition(all(max(abs(responseYLimits - sharedQLimit), [], 2) < 1e-10), ...
    'Primary response panels do not share one identical y-axis scale.');
layoutWarnings1 = validateFigureLayout(fig1, fig1Width, fig1Height, fontSize, fontName, ...
    'cv_network_conditioned_response_curves');
layoutWarnings2 = validateFigureLayout(fig2, fig2Width, fig2Height, fontSize, fontName, ...
    'target_load_objective_divergence');

%% Export editable, raster, and vector versions, then verify PDF page boxes.
fig1Base = fullfile(outputDir, 'cv_network_conditioned_response_curves');
fig2Base = fullfile(outputDir, 'target_load_objective_divergence');
exportFigureTriplet(fig1, fig1Base);
exportFigureTriplet(fig2, fig2Base);
pdfSize1 = verifyPdfPageSize(fig1Base + ".pdf", fig1Width, fig1Height);
pdfSize2 = verifyPdfPageSize(fig2Base + ".pdf", fig2Width, fig2Height);
close(fig1); close(fig2);

%% Write a compact, auditable validation record.
reportFile = fullfile(outputDir, 'figure_generation_validation.txt');
fid = fopen(reportFile, 'w');
assertCondition(fid >= 0, sprintf('Could not write validation report: %s', reportFile));
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, 'Plan-depth paper figure generation validation\n');
fprintf(fid, 'Generated: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
fprintf(fid, 'Repository commit: %s\n', repoCommit);
fprintf(fid, 'Required corrected-data ancestor: %s\n\n', requiredCommit);
fprintf(fid, 'Inputs:\n  primary: %s\n  target loads 5/20: %s\n', primaryFile, loadFile);
fprintf(fid, '  archive input used: no\n\n');
fprintf(fid, 'Retained observations:\n');
fprintf(fid, '  primary 10-target (300 paired IDs/cell): %d\n', height(primary));
fprintf(fid, '  5/20-target subset (25 paired IDs/cell): %d\n', height(loadSubset));
fprintf(fid, '  balanced 10-target subset (IDs 0--24): %d\n', height(balancedTen));
fprintf(fid, '  combined target-load source observations: %d\n', height(targetLoad));
fprintf(fid, 'Pairing checks:\n');
fprintf(fid, '  all 36 primary cells contain exactly IDs 0--299\n');
fprintf(fid, '  all 108 target-load cells contain exactly IDs 0--24\n\n');
fprintf(fid, 'Corrected ideal-network raw means (effort, makespan):\n');
for k = 1:height(expectedMeans)
    idx = primarySource.algorithm == expectedMeans.algorithm(k) & ...
        primarySource.comm_label == "ideal" & primarySource.horizon == expectedMeans.horizon(k);
    fprintf(fid, '  %s h=%g: %.6f, %.6f\n', expectedMeans.algorithm(k), ...
        expectedMeans.horizon(k), primarySource.mean_effort(idx), primarySource.mean_makespan(idx));
end
fprintf(fid, '\nHIPC maximum ideal divergence (percentage points):\n');
fprintf(fid, '  T=5: %.6f\n  T=10: %.6f\n  T=20: %.6f\n', observedHipcMax);
fprintf(fid, '\nFigure dimensions and PDF page boxes:\n');
fprintf(fid, '  cv_network_conditioned_response_curves: %.2f x %.2f in; PDF %.3f x %.3f in\n', ...
    fig1Width, fig1Height, pdfSize1(1), pdfSize1(2));
fprintf(fid, '  target_load_objective_divergence: %.2f x %.2f in; PDF %.3f x %.3f in\n', ...
    fig2Width, fig2Height, pdfSize2(1), pdfSize2(2));
fprintf(fid, '  typography: %.1f pt %s for every text object\n', fontSize, fontName);
fprintf(fid, '  shared primary response y limits: [%.6f, %.6f]\n', sharedQLimit);
fprintf(fid, '\nOutputs:\n');
for name = ["cv_network_conditioned_response_curves", "target_load_objective_divergence"]
    fprintf(fid, '  %s.fig\n  %s.png\n  %s.pdf\n', name, name, name);
end
fprintf(fid, '  source_data/%s\n', string(java.io.File(primarySourceFile).getName()));
fprintf(fid, '  source_data/%s\n', string(java.io.File(targetSourceFile).getName()));
allWarnings = [layoutWarnings1; layoutWarnings2];
if isempty(allWarnings)
    fprintf(fid, '\nWarnings: none\n');
else
    fprintf(fid, '\nWarnings:\n');
    fprintf(fid, '  %s\n', allWarnings);
end
fprintf('Created validated plan-depth paper figures in:\n%s\n', outputDir);

function tab = standardizeSystemTable(tab)
    hasStage = ismember('stage', tab.Properties.VariableNames);
    if hasStage, stage = string(tab.stage); end
    tab = table(double(tab.trial_id), string(tab.algorithm), string(tab.comm_label), ...
        double(tab.target_count), double(tab.value), string(tab.trial_status), ...
        double(tab.total_team_steps), double(tab.max_robot_steps), ...
        'VariableNames', {'trial_id', 'algorithm', 'comm_label', 'target_count', ...
        'horizon', 'trial_status', 'effort', 'makespan'});
    if hasStage, tab.stage = stage; end
end

function validateCells(tab, algorithms, horizons, comms, targetCount, expectedIds, label)
    for a = 1:numel(algorithms)
        for c = 1:numel(comms)
            for h = horizons
                idx = tab.algorithm == algorithms(a) & tab.comm_label == comms(c) & ...
                    tab.horizon == h & tab.target_count == targetCount;
                block = tab(idx, :);
                ids = sort(unique(block.trial_id));
                assertCondition(height(block) == numel(expectedIds), sprintf( ...
                    '%s cell %s/%s/h=%g has %d rows; expected %d.', label, ...
                    algorithms(a), comms(c), h, height(block), numel(expectedIds)));
                assertCondition(isequal(ids, expectedIds), sprintf( ...
                    '%s cell %s/%s/h=%g does not contain the expected paired trial IDs.', ...
                    label, algorithms(a), comms(c), h));
                assertCondition(all(isfinite(block.effort) & block.effort > 0), sprintf( ...
                    '%s cell %s/%s/h=%g has invalid effort.', label, algorithms(a), comms(c), h));
                assertCondition(all(isfinite(block.makespan) & block.makespan > 0), sprintf( ...
                    '%s cell %s/%s/h=%g has invalid makespan.', label, algorithms(a), comms(c), h));
            end
        end
    end
end

function summary = summarizeResponses(tab, algorithms, horizons, comms, loads, expectedN)
    rowCount = numel(algorithms) * numel(horizons) * numel(comms) * numel(loads);
    algorithm = strings(rowCount, 1); target_count = zeros(rowCount, 1);
    comm_label = strings(rowCount, 1); horizon = zeros(rowCount, 1);
    sample_size = zeros(rowCount, 1); mean_effort = zeros(rowCount, 1);
    mean_makespan = zeros(rowCount, 1); row = 0;
    for a = 1:numel(algorithms)
        for targetCount = loads
            for c = 1:numel(comms)
                for h = horizons
                    row = row + 1;
                    idx = tab.algorithm == algorithms(a) & tab.target_count == targetCount & ...
                        tab.comm_label == comms(c) & tab.horizon == h;
                    block = tab(idx, :);
                    algorithm(row) = algorithms(a); target_count(row) = targetCount;
                    comm_label(row) = comms(c); horizon(row) = h;
                    sample_size(row) = height(block);
                    mean_effort(row) = mean(block.effort);
                    mean_makespan(row) = mean(block.makespan);
                    assertCondition(sample_size(row) == expectedN, 'Unexpected summary cell sample size.');
                end
            end
        end
    end
    summary = table(algorithm, target_count, comm_label, horizon, sample_size, ...
        mean_effort, mean_makespan);
    summary.Q_effort = nan(rowCount, 1); summary.Q_makespan = nan(rowCount, 1);
    for row = 1:rowCount
        baseline = summary.algorithm == summary.algorithm(row) & ...
            summary.target_count == summary.target_count(row) & ...
            summary.comm_label == summary.comm_label(row) & summary.horizon == 1;
        assertCondition(nnz(baseline) == 1, 'A unique h=1 normalization baseline was not found.');
        summary.Q_effort(row) = summary.mean_effort(row) / summary.mean_effort(baseline);
        summary.Q_makespan(row) = summary.mean_makespan(row) / summary.mean_makespan(baseline);
    end
    summary.divergence_pct_points = 100 * (summary.Q_makespan - summary.Q_effort);
end

function validateLines(summary, algorithms, horizons, comms, loads, label)
    for a = 1:numel(algorithms)
        for targetCount = loads
            for c = 1:numel(comms)
                rows = summary(summary.algorithm == algorithms(a) & ...
                    summary.target_count == targetCount & summary.comm_label == comms(c), :);
                assertCondition(isequal(sort(rows.horizon)', horizons), sprintf( ...
                    '%s line %s/T=%g/%s does not contain all six tested depths.', ...
                    label, algorithms(a), targetCount, comms(c)));
                values = [rows.mean_effort; rows.mean_makespan; rows.Q_effort; ...
                    rows.Q_makespan; rows.divergence_pct_points];
                assertCondition(all(isfinite(values)), sprintf( ...
                    '%s line %s/T=%g/%s contains non-finite values.', ...
                    label, algorithms(a), targetCount, comms(c)));
            end
        end
    end
end

function fig = makeFigure(width, height)
    fig = figure('Color', 'white', 'Units', 'inches', 'Position', [1, 1, width, height], ...
        'PaperUnits', 'inches', 'PaperSize', [width, height], ...
        'PaperPosition', [0, 0, width, height], 'PaperPositionMode', 'manual', ...
        'InvertHardcopy', 'off', 'Visible', 'off');
end

function formatPanel(ax, algorithm, panelIndex, horizons, fontSize, fontName)
    xlim(ax, [0.65, 12.35]); xticks(ax, horizons);
    title(ax, sprintf('(%s) %s', char('a' + panelIndex - 1), algorithm), ...
        'FontWeight', 'normal', 'FontSize', fontSize);
    grid(ax, 'off'); box(ax, 'on');
    set(ax, 'FontName', fontName, 'FontSize', fontSize, 'LineWidth', 0.65, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, 'Layer', 'top');
end

function applyUniformTypography(fig, fontSize, fontName)
    % Tiled-layout labels are not reliably returned by the generic FontSize
    % query, so normalize them explicitly before and after drawnow.
    layouts = findall(fig, 'Type', 'tiledlayout');
    for k = 1:numel(layouts)
        layouts(k).XLabel.FontSize = fontSize;
        layouts(k).YLabel.FontSize = fontSize;
        layouts(k).Title.FontSize = fontSize;
        layouts(k).XLabel.FontName = fontName;
        layouts(k).YLabel.FontName = fontName;
        layouts(k).Title.FontName = fontName;
    end
    objects = findall(fig, '-property', 'FontSize');
    for k = 1:numel(objects)
        objects(k).FontSize = fontSize;
        if isprop(objects(k), 'FontName'), objects(k).FontName = fontName; end
    end
    axesObjects = findall(fig, 'Type', 'axes');
    for k = 1:numel(axesObjects)
        axesObjects(k).TitleFontSizeMultiplier = 1;
        axesObjects(k).LabelFontSizeMultiplier = 1;
    end
    drawnow;
    for k = 1:numel(layouts)
        layouts(k).XLabel.FontSize = fontSize;
        layouts(k).YLabel.FontSize = fontSize;
        layouts(k).Title.FontSize = fontSize;
    end
end

function warnings = validateFigureLayout(fig, expectedWidth, expectedHeight, fontSize, fontName, name)
    drawnow;
    warnings = strings(0, 1);
    oldUnits = fig.Units; fig.Units = 'inches'; sizeInches = fig.Position(3:4);
    assertCondition(all(abs(sizeInches - [expectedWidth, expectedHeight]) < 0.01), sprintf( ...
        '%s has incorrect figure dimensions.', name));
    fig.Units = oldUnits;
    axesObjects = findall(fig, 'Type', 'axes');
    assertCondition(numel(axesObjects) == 3, sprintf('%s does not contain exactly three panels.', name));
    fontObjects = findall(fig, '-property', 'FontSize');
    observed = zeros(numel(fontObjects), 1);
    for k = 1:numel(fontObjects), observed(k) = double(fontObjects(k).FontSize); end
    assertCondition(all(abs(observed - fontSize) < 1e-9), sprintf( ...
        '%s contains text that is not %.1f pt.', name, fontSize));
    namedObjects = findall(fig, '-property', 'FontName');
    observedNames = strings(numel(namedObjects), 1);
    for k = 1:numel(namedObjects), observedNames(k) = string(namedObjects(k).FontName); end
    assertCondition(all(strcmpi(observedNames, fontName)), sprintf( ...
        '%s contains text that is not set in %s.', name, fontName));
    layouts = findall(fig, 'Type', 'tiledlayout');
    for k = 1:numel(layouts)
        layoutSizes = [layouts(k).XLabel.FontSize, layouts(k).YLabel.FontSize, ...
            layouts(k).Title.FontSize];
        assertCondition(all(abs(layoutSizes - fontSize) < 1e-9), sprintf( ...
            '%s contains a tiled-layout label that is not %.1f pt.', name, fontSize));
        layoutNames = string({layouts(k).XLabel.FontName, layouts(k).YLabel.FontName, ...
            layouts(k).Title.FontName});
        assertCondition(all(strcmpi(layoutNames, fontName)), sprintf( ...
            '%s contains a tiled-layout label that is not set in %s.', name, fontName));
    end
    legends = findall(fig, 'Type', 'legend');
    assertCondition(isscalar(legends), sprintf('%s does not contain exactly one shared legend.', name));
    fig.Units = 'pixels'; figBox = [0, 0, fig.Position(3), fig.Position(4)];
    legendBox = getpixelposition(legends(1), true);
    assertCondition(isInside(legendBox, figBox, 3), sprintf('%s legend is clipped by the figure boundary.', name));
    for k = 1:numel(axesObjects)
        axesBox = getpixelposition(axesObjects(k), true);
        assertCondition(rectangleIntersectionArea(axesBox, legendBox) < 1, sprintf( ...
            '%s legend overlaps a data panel.', name));
        oldAxUnits = axesObjects(k).Units; axesObjects(k).Units = 'normalized';
        position = axesObjects(k).Position; inset = axesObjects(k).TightInset;
        axesObjects(k).Units = oldAxUnits;
        outer = [position(1) - inset(1), position(2) - inset(2), ...
            position(3) + inset(1) + inset(3), position(4) + inset(2) + inset(4)];
        assertCondition(outer(1) >= -0.025 && outer(2) >= -0.025 && ...
            outer(1) + outer(3) <= 1.025 && outer(2) + outer(4) <= 1.025, ...
            sprintf('%s panel text extends outside the figure boundary.', name));
    end
    fig.Units = oldUnits;
end

function exportFigureTriplet(fig, basePath)
    savefig(fig, basePath + ".fig");
    exportgraphics(fig, basePath + ".png", 'Resolution', 300, 'Padding', 'figure');
    exportgraphics(fig, basePath + ".pdf", 'ContentType', 'vector', 'Padding', 'figure');
end

function pageInches = verifyPdfPageSize(pdfFile, expectedWidth, expectedHeight)
    fid = fopen(pdfFile, 'r');
    assertCondition(fid >= 0, sprintf('Could not read exported PDF: %s', pdfFile));
    cleanup = onCleanup(@() fclose(fid));
    bytes = fread(fid, Inf, '*uint8')'; text = char(bytes);
    token = regexp(text, '/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*\]', ...
        'tokens', 'once');
    assertCondition(~isempty(token), sprintf('Could not locate a PDF MediaBox in %s.', pdfFile));
    points = str2double(string(token));
    pageInches = [(points(3) - points(1)) / 72, (points(4) - points(2)) / 72];
    assertCondition(all(abs(pageInches - [expectedWidth, expectedHeight]) <= 0.03), sprintf( ...
        'PDF page box for %s is %.3f x %.3f in; expected %.2f x %.2f in.', ...
        pdfFile, pageInches(1), pageInches(2), expectedWidth, expectedHeight));
end

function area = rectangleIntersectionArea(a, b)
    width = max(0, min(a(1) + a(3), b(1) + b(3)) - max(a(1), b(1)));
    height = max(0, min(a(2) + a(4), b(2) + b(4)) - max(a(2), b(2)));
    area = width * height;
end

function result = isInside(inner, outer, tolerance)
    result = inner(1) >= outer(1) - tolerance && inner(2) >= outer(2) - tolerance && ...
        inner(1) + inner(3) <= outer(1) + outer(3) + tolerance && ...
        inner(2) + inner(4) <= outer(2) + outer(4) + tolerance;
end

function path = canonicalPath(path)
    path = char(java.io.File(path).getCanonicalPath());
end

function requireColumns(tab, columns, source)
    missing = columns(~ismember(columns, string(tab.Properties.VariableNames)));
    assertCondition(isempty(missing), sprintf('Missing columns in %s: %s.', source, strjoin(missing, ', ')));
end

function mustExist(path, description)
    assertCondition(isfile(path), sprintf('%s not found: %s', description, path));
end

function assertCondition(condition, message)
    if ~condition, error('plan_depth_figures:validation', '%s', message); end
end
