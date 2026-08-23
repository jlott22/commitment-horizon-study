% BUILD_BUNDLE_LENGTH_RESPONSE_WITH_ERROR_BARS
% Create a separate uncertainty-aware version of bundle_length_response.
% Error bars are paired-trial percentile-bootstrap 95% confidence intervals
% for the percent change from B=1. Existing publication files are untouched.

close all;
scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(scriptDir));
sourceFile = fullfile(repoRoot, 'reference_core_benchmark_pilot', 'combined', ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv');
outputBase = fullfile(scriptDir, 'bundle_length_response_with_error_bars');

algorithms = ["ACBBA", "HIPC", "PI"];
objectives = ["MiniSum", "MiniMax"];
metrics = ["total_team_steps", "max_robot_steps"];
comms = ["ideal", "bernoulli_025"];
bundleLengths = [1, 2, 3, 5, 8, 12];
bootstrapSeed = 20260824;
bootstrapResamples = 20000;
fontSize = 8.0;
fontName = 'Helvetica';

assertCondition(isfile(sourceFile), sprintf('Source CSV not found: %s', sourceFile));
raw = readtable(sourceFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
required = ["trial_id", "algorithm", "comm_label", "target_count", "value", ...
    "trial_status", "total_team_steps", "max_robot_steps"];
requireColumns(raw, required, sourceFile);

raw.trial_id = double(raw.trial_id);
raw.algorithm = string(raw.algorithm);
raw.comm_label = string(raw.comm_label);
raw.target_count = double(raw.target_count);
raw.value = double(raw.value);
raw.trial_status = string(raw.trial_status);
raw.total_team_steps = double(raw.total_team_steps);
raw.max_robot_steps = double(raw.max_robot_steps);
data = raw(raw.trial_status == "completed" & raw.target_count == 10 & ...
    ismember(raw.algorithm, algorithms) & ismember(raw.comm_label, comms) & ...
    ismember(raw.value, bundleLengths), :);
assertCondition(height(data) == 10800, sprintf( ...
    'Retained %d rows; expected exactly 10,800.', height(data)));

% Compute mean responses and paired-bootstrap intervals. Each bootstrap draw
% resamples the same trial identifiers at B and B=1, preserving pairing.
nRows = numel(algorithms) * numel(objectives) * numel(comms) * numel(bundleLengths);
algorithm = strings(nRows, 1);
objective = strings(nRows, 1);
comm_label = strings(nRows, 1);
B = zeros(nRows, 1);
n = zeros(nRows, 1);
change_from_B1_pct = zeros(nRows, 1);
ci95_lower = zeros(nRows, 1);
ci95_upper = zeros(nRows, 1);
row = 0;
rng(bootstrapSeed, 'twister');

for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        for c = 1:numel(comms)
            [baselineIds, baselineValues] = cellVector(data, algorithms(a), ...
                comms(c), 1, metrics(o));
            assertCondition(isequal(baselineIds, (0:299)'), ...
                'The B=1 cell does not contain paired trial IDs 0--299.');
            sampleIndex = randi(numel(baselineIds), numel(baselineIds), bootstrapResamples);
            baselineBoot = mean(baselineValues(sampleIndex), 1);
            for b = 1:numel(bundleLengths)
                row = row + 1;
                [ids, values] = cellVector(data, algorithms(a), comms(c), ...
                    bundleLengths(b), metrics(o));
                assertCondition(isequal(ids, baselineIds), ...
                    'A bundle-length cell is not exactly paired with B=1.');
                estimate = 100 * (mean(values) / mean(baselineValues) - 1);
                bootChange = 100 * (mean(values(sampleIndex), 1) ./ baselineBoot - 1);
                interval = prctile(bootChange, [2.5, 97.5]);
                algorithm(row) = algorithms(a);
                objective(row) = objectives(o);
                comm_label(row) = comms(c);
                B(row) = bundleLengths(b);
                n(row) = numel(ids);
                change_from_B1_pct(row) = estimate;
                ci95_lower(row) = interval(1);
                ci95_upper(row) = interval(2);
            end
        end
    end
end
intervals = table(algorithm, objective, comm_label, B, n, ...
    change_from_B1_pct, ci95_lower, ci95_upper);

% Match the established publication figure while allowing modest room for
% confidence limits so whiskers cannot be clipped.
idealColor = [0.08, 0.22, 0.36];
lossColor = [0.68, 0.36, 0.16];
figureWidth = 3.45;
figureHeight = 5.45;
fig = figure('Color', 'white', 'Units', 'inches', ...
    'Position', [1, 1, figureWidth, figureHeight], ...
    'PaperUnits', 'inches', 'PaperSize', [figureWidth, figureHeight], ...
    'PaperPosition', [0, 0, figureWidth, figureHeight], ...
    'PaperPositionMode', 'manual', 'InvertHardcopy', 'off', 'Visible', 'off');
layout = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

objectiveLimits = zeros(2, 2);
for o = 1:numel(objectives)
    block = intervals(intervals.objective == objectives(o), :);
    span = max(block.change_from_B1_pct) - min(block.change_from_B1_pct);
    padding = max(2.5, 0.07 * max(span, 1));
    objectiveLimits(o, :) = [min(0, min(block.ci95_lower) - padding), ...
        max(0, max(block.ci95_upper) + padding)];
end

legendHandles = gobjects(1, 2);
for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        ax = nexttile(layout, (a - 1) * 2 + o);
        hold(ax, 'on');
        yline(ax, 0, '-', 'Color', [0.78, 0.78, 0.78], 'LineWidth', 0.75, ...
            'HandleVisibility', 'off');
        idealRows = sortrows(intervals(intervals.algorithm == algorithms(a) & ...
            intervals.objective == objectives(o) & intervals.comm_label == "ideal", :), 'B');
        lossRows = sortrows(intervals(intervals.algorithm == algorithms(a) & ...
            intervals.objective == objectives(o) & ...
            intervals.comm_label == "bernoulli_025", :), 'B');

        drawIntervals(ax, idealRows, idealColor);
        drawIntervals(ax, lossRows, lossColor);
        pIdeal = plot(ax, idealRows.B, idealRows.change_from_B1_pct, '-o', ...
            'Color', idealColor, 'MarkerFaceColor', idealColor, ...
            'LineWidth', 1.25, 'MarkerSize', 4.5);
        pLoss = plot(ax, lossRows.B, lossRows.change_from_B1_pct, '--s', ...
            'Color', lossColor, 'MarkerFaceColor', 'white', ...
            'LineWidth', 1.25, 'MarkerSize', 4.5);
        if a == 1 && o == 1
            legendHandles = [pIdeal, pLoss];
        end

        xlim(ax, [0.65, 12.35]);
        xticks(ax, bundleLengths);
        ylim(ax, objectiveLimits(o, :));
        configureAxes(ax, fontSize, fontName);
        if a < numel(algorithms)
            xticklabels(ax, []);
        else
            xlabel(ax, 'Bundle length (B)');
        end
        if o == 1
            ylabel(ax, sprintf('%s\nChange (%%)', algorithms(a)));
        end
        if a == 1
            if o == 1
                title(ax, 'MiniSum (total effort)', 'FontWeight', 'normal');
            else
                title(ax, 'MiniMax (makespan)', 'FontWeight', 'normal');
            end
        end
    end
end
legendObject = legend(legendHandles, {'Ideal', '25% packet loss'}, ...
    'Orientation', 'horizontal', 'NumColumns', 2, 'Box', 'off');
legendObject.Layout.Tile = 'south';
applyUniformTypography(fig, fontSize, fontName);
validateFigure(fig, objectiveLimits, fontSize, fontName, figureWidth, figureHeight);

savefig(fig, outputBase + ".fig");
exportgraphics(fig, outputBase + ".png", 'Resolution', 300, 'Padding', 'figure');
exportgraphics(fig, outputBase + ".pdf", 'ContentType', 'vector', 'Padding', 'figure');
writetable(intervals, outputBase + "_intervals.csv");
close(fig);

fprintf('Created bundle-length response with paired-bootstrap 95%% intervals:\n%s.png\n', ...
    outputBase);

function drawIntervals(ax, rows, color)
    lower = rows.change_from_B1_pct - rows.ci95_lower;
    upper = rows.ci95_upper - rows.change_from_B1_pct;
    errorbar(ax, rows.B, rows.change_from_B1_pct, lower, upper, ...
        'LineStyle', 'none', 'Marker', 'none', 'Color', color, ...
        'LineWidth', 0.75, 'CapSize', 3, 'HandleVisibility', 'off');
end

function [ids, values] = cellVector(tab, algorithm, comm, B, metric)
    idx = tab.algorithm == algorithm & tab.comm_label == comm & tab.value == B;
    block = sortrows(table(tab.trial_id(idx), tab.(metric)(idx), ...
        'VariableNames', {'trial_id', 'value'}), 'trial_id');
    ids = block.trial_id;
    values = block.value;
    assertCondition(height(block) == 300 && numel(unique(ids)) == 300, ...
        'A required data cell does not contain 300 unique trials.');
    assertCondition(all(isfinite(values) & values > 0), ...
        'A required data cell contains a non-finite or non-positive outcome.');
end

function configureAxes(ax, fontSize, fontName)
    set(ax, 'FontName', fontName, 'FontSize', fontSize, 'LineWidth', 0.65, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, ...
        'Box', 'on', 'Layer', 'top');
end

function applyUniformTypography(fig, fontSize, fontName)
    objects = findall(fig, '-property', 'FontSize');
    for k = 1:numel(objects)
        objects(k).FontSize = fontSize;
        if isprop(objects(k), 'FontName')
            objects(k).FontName = fontName;
        end
    end
    axesObjects = findall(fig, 'Type', 'axes');
    for k = 1:numel(axesObjects)
        axesObjects(k).TitleFontSizeMultiplier = 1;
        axesObjects(k).LabelFontSizeMultiplier = 1;
    end
    drawnow;
end

function validateFigure(fig, objectiveLimits, fontSize, fontName, width, height)
    drawnow;
    oldUnits = fig.Units;
    fig.Units = 'inches';
    assertCondition(all(abs(fig.Position(3:4) - [width, height]) < 0.01), ...
        'The error-bar figure has incorrect canvas dimensions.');
    axesObjects = findall(fig, 'Type', 'axes');
    assertCondition(numel(axesObjects) == 6, ...
        'The error-bar figure does not contain exactly six panels.');
    for k = 1:numel(axesObjects)
        observed = axesObjects(k).YLim;
        matches = max(abs(observed - objectiveLimits(1, :))) < 1e-10 || ...
            max(abs(observed - objectiveLimits(2, :))) < 1e-10;
        assertCondition(matches, 'A panel does not use its column-wide y limits.');
    end
    objects = findall(fig, '-property', 'FontSize');
    for k = 1:numel(objects)
        assertCondition(abs(double(objects(k).FontSize) - fontSize) < 1e-9, ...
            'The error-bar figure contains inconsistent text sizing.');
        if isprop(objects(k), 'FontName')
            assertCondition(strcmpi(string(objects(k).FontName), fontName), ...
                'The error-bar figure contains inconsistent fonts.');
        end
    end
    fig.Units = oldUnits;
end

function requireColumns(tab, required, file)
    missing = setdiff(required, string(tab.Properties.VariableNames));
    assertCondition(isempty(missing), sprintf('Missing columns in %s: %s', ...
        file, strjoin(missing, ', ')));
end

function assertCondition(condition, message)
    if ~condition
        error('bundle_length_response_with_error_bars:Validation', '%s', message);
    end
end
