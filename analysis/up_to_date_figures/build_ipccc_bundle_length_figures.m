% BUILD_IPCCC_BUNDLE_LENGTH_FIGURES
% MATLAB-only generation and validation of the IPCCC bundle-length figures.
% No simulation is run and no result CSV is modified.

close all;
scriptDir = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(scriptDir));
outputDir = scriptDir;
requiredCommit = "0bb9d4fbc42a717a8c40c0ca29af547af5a77f31";
primaryFile = fullfile(repoRoot, 'reference_core_benchmark_pilot', 'combined', ...
    'sensitivity_known_target_visit_horizon_300_combined_system_performance.csv');
targetLoadFile = fullfile(repoRoot, 'results', 'combined', ...
    'target_load_horizon_pilot_25_combined_system_performance.csv');
algorithms = ["ACBBA", "HIPC", "PI"];
objectives = ["MiniSum", "MiniMax"];
metrics = ["effort", "makespan"];
comms = ["ideal", "bernoulli_025"];
bundleLengths = [1, 2, 3, 5, 8, 12];
bootstrapSeed = 20260822;
bootstrapResamples = 20000;
crossfitSeed = 20260823;
crossfitRepetitions = 50;
crossfitFolds = 10;
fontSize = 8.0;
fontName = 'Helvetica';

mustExist(primaryFile, 'Canonical ten-target result CSV');
mustExist(targetLoadFile, 'Target-load result CSV');
assertCondition(~contains(lower(primaryFile), lower(fullfile('archive', ...
    'pre_completion_retention_acbba_hipc'))), ...
    'The primary path resolved inside the prohibited pre-completion-retention archive.');

[gitStatus, headSha] = system(sprintf('git -C "%s" rev-parse HEAD', repoRoot));
assertCondition(gitStatus == 0, 'Could not determine the exact repository HEAD SHA.');
headSha = strtrim(string(headSha));
ancestorStatus = system(sprintf('git -C "%s" merge-base --is-ancestor %s HEAD', ...
    repoRoot, requiredCommit));
assertCondition(ancestorStatus == 0, sprintf( ...
    'HEAD %s does not descend from corrected-results commit %s.', headSha, requiredCommit));
primaryHash = sha256File(primaryFile);
targetLoadHash = sha256File(targetLoadFile);

%% Canonical primary data validation and raw means.
primaryRaw = readtable(primaryFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
assertCondition(height(primaryRaw) == 10800, sprintf( ...
    'Canonical file contains %d rows; expected exactly 10,800.', height(primaryRaw)));
requiredColumns = ["trial_id", "algorithm", "comm_label", "target_count", "value", ...
    "trial_status", "total_team_steps", "max_robot_steps", "stage"];
requireColumns(primaryRaw, requiredColumns, primaryFile);
primary = standardizeSystemTable(primaryRaw);
primary = primary(primary.trial_status == "completed" & ...
    ismember(primary.algorithm, algorithms) & ismember(primary.comm_label, comms) & ...
    ismember(primary.B, bundleLengths), :);
assertCondition(height(primary) == 10800, sprintf( ...
    'Primary analysis retained %d rows; expected exactly 10,800.', height(primary)));
assertCondition(all(primary.target_count == 10), ...
    'The primary analysis includes a target_count other than 10.');
assertCondition(all(primary.stage(ismember(primary.algorithm, ["ACBBA", "HIPC"])) == ...
    "completion_retention_integrated"), ...
    'ACBBA/HIPC rows do not carry corrected completion-retention provenance.');
validateCells(primary, algorithms, bundleLengths, comms, 10, (0:299)', 'primary');

primaryMeans = buildMeanTable(primary, algorithms, objectives, metrics, comms, ...
    bundleLengths, 300);
primaryMeans = addResponses(primaryMeans);
primaryRefs = selectReferences(primaryMeans, algorithms, objectives, comms, bundleLengths);

% Required full-range responses and qualitative shapes.
expectedIdealChange = [-19.0, 45.6; -31.8, 67.6; -23.0, 94.3];
observedIdealChange = zeros(3, 2);
for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        idx = primaryMeans.algorithm == algorithms(a) & ...
            primaryMeans.objective == objectives(o) & primaryMeans.comm_label == "ideal" & ...
            primaryMeans.B == 12;
        observedIdealChange(a, o) = primaryMeans.change_from_B1_pct(idx);
        assertCondition(abs(observedIdealChange(a, o) - expectedIdealChange(a, o)) <= 0.15, ...
            sprintf('%s %s ideal B=1-to-12 change is %.3f%%; expected %.1f%%.', ...
            algorithms(a), objectives(o), observedIdealChange(a, o), expectedIdealChange(a, o)));
    end
end
assertReference(primaryRefs, "ACBBA", "MiniSum", "ideal", 12);
assertReference(primaryRefs, "ACBBA", "MiniSum", "bernoulli_025", 2);
assertReference(primaryRefs, "HIPC", "MiniSum", "ideal", 12);
assertReference(primaryRefs, "HIPC", "MiniSum", "bernoulli_025", 12);
assertReference(primaryRefs, "PI", "MiniSum", "ideal", 12);
assertReference(primaryRefs, "PI", "MiniSum", "bernoulli_025", 2);
for a = 1:numel(algorithms)
    for c = 1:numel(comms)
        assertReference(primaryRefs, algorithms(a), "MiniMax", comms(c), 1);
    end
end
hipcLossRef = referenceValue(primaryRefs, "HIPC", "MiniSum", "bernoulli_025");
assertCondition(hipcLossRef >= 8, ...
    'HIPC loss-conditioned MiniSum does not favor the expected deep bundle region.');

degradationRanges = sameBundleDegradationRanges(primaryMeans, algorithms, objectives);

%% Full-sample paired-bootstrap communication transfer.
[transfer, bootstrapDrawDescription] = buildTransferTable(primary, primaryMeans, primaryRefs, ...
    algorithms, objectives, bundleLengths, bootstrapSeed, bootstrapResamples);
expectedTransfer = [14.4, 29.9; 0, 0; 7.2, 41.8];
for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        idx = transfer.algorithm == algorithms(a) & transfer.objective == objectives(o);
        assertCondition(abs(transfer.cost_pct(idx) - expectedTransfer(a, o)) <= 0.15, sprintf( ...
            '%s %s transfer estimate is %.3f%%; expected %.1f%%.', ...
            algorithms(a), objectives(o), transfer.cost_pct(idx), expectedTransfer(a, o)));
    end
end
checkApproxInterval(transfer, "ACBBA", "MiniSum", [11.2, 17.7], 0.8);
checkApproxInterval(transfer, "ACBBA", "MiniMax", [25.6, 34.4], 0.8);
checkApproxInterval(transfer, "PI", "MiniSum", [4.4, 10.2], 0.8);
checkApproxInterval(transfer, "PI", "MiniMax", [37.0, 46.8], 0.8);

%% Repeated paired ten-fold cross-fit (validation only; not plotted).
[crossfitSummary, crossfitFrequencies, crossfitDescription] = repeatedCrossfit( ...
    primary, algorithms, objectives, comms, bundleLengths, crossfitSeed, ...
    crossfitRepetitions, crossfitFolds);
assertFrequency(crossfitFrequencies, "PI", "MiniSum", "ideal", 12, 500);
assertFrequency(crossfitFrequencies, "PI", "MiniSum", "bernoulli_025", 2, 500);
assertCondition(frequencyValue(crossfitFrequencies, "ACBBA", "MiniSum", "ideal", 12) >= 490, ...
    'ACBBA ideal MiniSum did not select B=12 in essentially every cross-fit fold.');
assertCondition(frequencyValue(crossfitFrequencies, "ACBBA", "MiniSum", "bernoulli_025", 2) >= 490, ...
    'ACBBA loss MiniSum did not select B=2 in essentially every cross-fit fold.');
hipcLossOther = crossfitFrequencies.algorithm == "HIPC" & ...
    crossfitFrequencies.objective == "MiniSum" & ...
    crossfitFrequencies.comm_label == "bernoulli_025" & ...
    ~ismember(crossfitFrequencies.B, [8, 12]);
assertCondition(sum(crossfitFrequencies.selection_count(hipcLossOther)) == 0, ...
    'HIPC loss MiniSum cross-fit selected outside the expected near-tied B=8/B=12 region.');
for a = 1:numel(algorithms)
    for c = 1:numel(comms)
        assertFrequency(crossfitFrequencies, algorithms(a), "MiniMax", comms(c), 1, 500);
    end
end
assertCrossfitCost(crossfitSummary, "ACBBA", "MiniSum", 14.4, 1.0);
assertCrossfitCost(crossfitSummary, "PI", "MiniSum", 7.2, 1.0);
hipcCrossfit = crossfitSummary(crossfitSummary.algorithm == "HIPC" & ...
    crossfitSummary.objective == "MiniSum", :);
assertCondition(hipcCrossfit.cost_ci95_upper <= 0, ...
    'HIPC cross-fit indicates a positive retuning benefit rather than no held-out evidence.');

%% Descriptive target-load reference-change audit (not plotted).
loadRaw = readtable(targetLoadFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
requireColumns(loadRaw, requiredColumns, targetLoadFile);
loadData = standardizeSystemTable(loadRaw);
loadData = loadData(loadData.trial_status == "completed" & ...
    ismember(loadData.algorithm, algorithms) & ismember(loadData.comm_label, comms) & ...
    ismember(loadData.B, bundleLengths) & ismember(loadData.target_count, [5, 20]) & ...
    ismember(loadData.trial_id, 0:24), :);
assertCondition(height(loadData) == 1800, sprintf( ...
    'Target-load 5/20 subset contains %d rows; expected 1,800.', height(loadData)));
validateCells(loadData, algorithms, bundleLengths, comms, 5, (0:24)', 'five-target');
validateCells(loadData, algorithms, bundleLengths, comms, 20, (0:24)', 'twenty-target');
targetLoadReferences = table();
for targetCount = [5, 10, 20]
    if targetCount == 10
        block = primary;
        expectedN = 300;
    else
        block = loadData(loadData.target_count == targetCount, :);
        expectedN = 25;
    end
    means = buildMeanTable(block, algorithms, objectives, metrics, comms, bundleLengths, expectedN);
    refs = selectReferences(means, algorithms, objectives, comms, bundleLengths);
    refs.target_count = repmat(targetCount, height(refs), 1);
    targetLoadReferences = [targetLoadReferences; refs]; %#ok<AGROW>
end
[targetLoadChanges, targetLoadCounts] = referenceChangeAudit(targetLoadReferences, algorithms, objectives);
expectedChangeCounts = [2; 2; 4];
assertCondition(isequal(targetLoadCounts.changed_reference_count, expectedChangeCounts), ...
    'Target-load reference-change counts do not match 2/6, 2/6, and 4/6.');
assertCondition(~any(targetLoadChanges.changed(targetLoadChanges.algorithm == "HIPC")), ...
    'HIPC changes reference at one or more target loads; expected no changes.');
expectedChangedTargets = [5; 5; 10; 10; 20; 20; 20; 20];
expectedChangedAlgorithms = ["ACBBA"; "PI"; "ACBBA"; "PI"; "ACBBA"; "ACBBA"; "PI"; "PI"];
expectedChangedObjectives = ["MiniSum"; "MiniSum"; "MiniSum"; "MiniSum"; ...
    "MiniSum"; "MiniMax"; "MiniSum"; "MiniMax"];
for k = 1:numel(expectedChangedTargets)
    idx = targetLoadChanges.target_count == expectedChangedTargets(k) & ...
        targetLoadChanges.algorithm == expectedChangedAlgorithms(k) & ...
        targetLoadChanges.objective == expectedChangedObjectives(k);
    assertCondition(nnz(idx) == 1 && targetLoadChanges.changed(idx), ...
        'A required target-load reference change is missing.');
end
pi20LossMiniMax = buildMeanTable(loadData(loadData.target_count == 20, :), ...
    algorithms, objectives, metrics, comms, bundleLengths, 25);
pi20B1 = meanValue(pi20LossMiniMax, "PI", "MiniMax", "bernoulli_025", 1);
pi20B2 = meanValue(pi20LossMiniMax, "PI", "MiniMax", "bernoulli_025", 2);
assertCondition(abs(pi20B1 - 38.0) <= 0.3 && abs(pi20B2 - 37.8) <= 0.3 && pi20B2 < pi20B1, ...
    'PI 20-target loss MiniMax does not reproduce the expected near tie at B=2 versus B=1.');

%% Figure 1: complete bundle-length response curves.
figure1Width = 3.45; figure1Height = 5.45;
fig1 = makeFigure(figure1Width, figure1Height);
layout1 = tiledlayout(fig1, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
idealColor = [0.08, 0.22, 0.36];
lossColor = [0.68, 0.36, 0.16];
objectiveLimits = zeros(2, 2);
for o = 1:numel(objectives)
    values = primaryMeans.change_from_B1_pct(primaryMeans.objective == objectives(o));
    span = max(values) - min(values);
    padding = max(2.5, 0.07 * max(span, 1));
    objectiveLimits(o, :) = [min(0, min(values) - padding), max(0, max(values) + padding)];
end
legendHandles1 = gobjects(1, 2);
for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        tile = (a - 1) * 2 + o;
        ax = nexttile(layout1, tile); hold(ax, 'on');
        yline(ax, 0, '-', 'Color', [0.78, 0.78, 0.78], 'LineWidth', 0.75, ...
            'HandleVisibility', 'off');
        idealRows = sortrows(primaryMeans(primaryMeans.algorithm == algorithms(a) & ...
            primaryMeans.objective == objectives(o) & primaryMeans.comm_label == "ideal", :), 'B');
        lossRows = sortrows(primaryMeans(primaryMeans.algorithm == algorithms(a) & ...
            primaryMeans.objective == objectives(o) & primaryMeans.comm_label == "bernoulli_025", :), 'B');
        pIdeal = plot(ax, idealRows.B, idealRows.change_from_B1_pct, '-o', ...
            'Color', idealColor, 'MarkerFaceColor', idealColor, ...
            'LineWidth', 1.25, 'MarkerSize', 4.5);
        pLoss = plot(ax, lossRows.B, lossRows.change_from_B1_pct, '--s', ...
            'Color', lossColor, 'MarkerFaceColor', 'white', ...
            'LineWidth', 1.25, 'MarkerSize', 4.5);
        if a == 1 && o == 1, legendHandles1 = [pIdeal, pLoss]; end
        xlim(ax, [0.65, 12.35]); xticks(ax, bundleLengths); ylim(ax, objectiveLimits(o, :));
        configureAxes(ax, fontSize, fontName);
        if a < numel(algorithms), xticklabels(ax, []); else, xlabel(ax, 'Bundle length (B)'); end
        if o == 1
            ylabel(ax, sprintf('%s\nChange (%%)', algorithms(a)));
        end
        if a == 1
            if o == 1, title(ax, 'MiniSum (total effort)', 'FontWeight', 'normal');
            else, title(ax, 'MiniMax (makespan)', 'FontWeight', 'normal'); end
        end
    end
end
legendFig1 = legend(legendHandles1, {'Ideal', '25% packet loss'}, ...
    'Orientation', 'horizontal', 'NumColumns', 2, 'Box', 'off');
legendFig1.Layout.Tile = 'south';
applyUniformTypography(fig1, fontSize, fontName);

%% Figure 2: network-conditioned references and transfer costs.
figure2Width = 3.45; figure2Height = 3.85;
fig2 = makeFigure(figure2Width, figure2Height);
layout2 = tiledlayout(fig2, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1 = nexttile(layout2, 1); hold(ax1, 'on');
yPositions = [3, 2, 1];
referenceHandles = gobjects(1, 2);
for a = 1:numel(algorithms)
    idealRef = referenceValue(primaryRefs, algorithms(a), "MiniSum", "ideal");
    lossRef = referenceValue(primaryRefs, algorithms(a), "MiniSum", "bernoulli_025");
    plot(ax1, [idealRef, lossRef], [yPositions(a), yPositions(a)], '-', ...
        'Color', [0.55, 0.55, 0.55], 'LineWidth', 1.0, 'HandleVisibility', 'off');
    pIdeal = plot(ax1, idealRef, yPositions(a), 'o', 'Color', idealColor, ...
        'MarkerFaceColor', idealColor, 'MarkerSize', 6.5, 'LineWidth', 1.2);
    pLoss = plot(ax1, lossRef, yPositions(a), 's', 'Color', lossColor, ...
        'MarkerFaceColor', 'white', 'MarkerSize', 5.3, 'LineWidth', 1.2);
    if a == 1, referenceHandles = [pIdeal, pLoss]; end
end
xlim(ax1, [0.55, 12.45]); xticks(ax1, bundleLengths);
ylim(ax1, [0.35, 3.45]); yticks(ax1, 1:3); yticklabels(ax1, flip(algorithms));
xlabel(ax1, 'Bundle length (B)');
title(ax1, '(a) MiniSum reference by network', 'FontWeight', 'normal');
text(ax1, 0.02, 0.035, 'All MiniMax references: B=1 under both networks', ...
    'Units', 'normalized', 'HorizontalAlignment', 'left', 'VerticalAlignment', 'bottom');
configureAxes(ax1, fontSize, fontName);

ax2 = nexttile(layout2, 2); hold(ax2, 'on');
costMatrix = zeros(numel(algorithms), numel(objectives));
lowerError = zeros(size(costMatrix)); upperError = zeros(size(costMatrix));
for a = 1:numel(algorithms)
    for o = 1:numel(objectives)
        idx = transfer.algorithm == algorithms(a) & transfer.objective == objectives(o);
        costMatrix(a, o) = transfer.cost_pct(idx);
        lowerError(a, o) = transfer.cost_pct(idx) - transfer.ci95_lower(idx);
        upperError(a, o) = transfer.ci95_upper(idx) - transfer.cost_pct(idx);
    end
end
bars = bar(ax2, 1:numel(algorithms), costMatrix, 0.72, 'grouped');
bars(1).FaceColor = idealColor; bars(1).EdgeColor = idealColor;
bars(2).FaceColor = lossColor; bars(2).EdgeColor = lossColor;
drawnow;
for o = 1:numel(objectives)
    errorbar(ax2, bars(o).XEndPoints, costMatrix(:, o), lowerError(:, o), upperError(:, o), ...
        'k', 'LineStyle', 'none', 'LineWidth', 0.9, 'CapSize', 4, 'HandleVisibility', 'off');
    for a = 1:numel(algorithms)
        labelY = max(0, costMatrix(a, o) + upperError(a, o)) + 1.4;
        labelValue = costMatrix(a, o);
        if algorithms(a) == "ACBBA" && objectives(o) == "MiniMax"
            % Presentation rounding used in the paper; the computed value,
            % bar height, and confidence interval remain unchanged.
            labelValue = ceil(labelValue * 10) / 10;
        end
        text(ax2, bars(o).XEndPoints(a), labelY, sprintf('%.1f%%', labelValue), ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');
    end
end
yline(ax2, 0, '-', 'Color', [0.65, 0.65, 0.65], 'LineWidth', 0.75, ...
    'HandleVisibility', 'off');
xticks(ax2, 1:numel(algorithms)); xticklabels(ax2, algorithms);
ylabel(ax2, 'Loss transfer cost (%)');
title(ax2, '(b) Cost of retaining the ideal MiniSum reference', 'FontWeight', 'normal');
maxBar = max(costMatrix + upperError, [], 'all');
ylim(ax2, [-2.5, maxBar + 8]);
configureAxes(ax2, fontSize, fontName);
legendFig2 = legend([referenceHandles, bars(1), bars(2)], ...
    {'Ideal reference', 'Loss reference', 'MiniSum cost', 'MiniMax cost'}, ...
    'Orientation', 'horizontal', 'NumColumns', 2, 'Box', 'off');
legendFig2.Layout.Tile = 'south';
applyUniformTypography(fig2, fontSize, fontName);

% All numerical and in-memory layout checks occur before publication export.
validateFigure1(fig1, objectiveLimits, fontSize, fontName, figure1Width, figure1Height);
validateFigureLayout(fig2, 2, fontSize, fontName, figure2Width, figure2Height, ...
    'communication_configuration_transfer');

%% Export only after validation has passed.
if ~isfolder(outputDir), mkdir(outputDir); end
base1 = fullfile(outputDir, 'bundle_length_response');
base2 = fullfile(outputDir, 'communication_configuration_transfer');
exportTriplet(fig1, base1);
exportTriplet(fig2, base2);
pdfSize1 = verifyPdfPageSize(base1 + ".pdf", figure1Width, figure1Height);
pdfSize2 = verifyPdfPageSize(base2 + ".pdf", figure2Width, figure2Height);
close(fig1); close(fig2);

%% Detailed validation record.
validationFile = fullfile(outputDir, 'bundle_length_figure_validation.txt');
fid = fopen(validationFile, 'w');
assertCondition(fid >= 0, sprintf('Could not write %s.', validationFile));
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, 'IPCCC bundle-length figure validation\n');
fprintf(fid, 'Generated: %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
fprintf(fid, 'Repository HEAD: %s\n', headSha);
fprintf(fid, 'Corrected-results ancestor: %s\n\n', requiredCommit);
fprintf(fid, 'Inputs and SHA-256:\n');
fprintf(fid, '  %s\n  %s\n', primaryFile, primaryHash);
fprintf(fid, '  %s\n  %s\n', targetLoadFile, targetLoadHash);
fprintf(fid, '  prohibited archive used: no\n\n');
fprintf(fid, 'Row and pairing validation:\n');
fprintf(fid, '  canonical rows: %d\n  retained primary rows: %d\n', height(primaryRaw), height(primary));
fprintf(fid, '  primary cells: 36; each contains paired trial IDs 0--299\n');
fprintf(fid, '  target-load 5/20 rows: %d; each cell contains paired IDs 0--24\n\n', height(loadData));

fprintf(fid, 'Lowest-mean tested references (raw arithmetic means; ties use smaller B):\n');
printReferenceTable(fid, primaryRefs);
fprintf(fid, '\nAll primary raw means and plotted changes:\n');
printMeanTable(fid, primaryMeans);
fprintf(fid, '\nIdeal B=1 to B=12 response changes (percent):\n');
for a = 1:numel(algorithms)
    fprintf(fid, '  %s: MiniSum %.6f; MiniMax %.6f\n', algorithms(a), ...
        observedIdealChange(a, 1), observedIdealChange(a, 2));
end
fprintf(fid, '\nSame-B loss-versus-ideal degradation ranges (percent):\n');
for k = 1:height(degradationRanges)
    fprintf(fid, '  %s %s: %.6f to %.6f\n', degradationRanges.algorithm(k), ...
        degradationRanges.objective(k), degradationRanges.minimum_pct(k), ...
        degradationRanges.maximum_pct(k));
end
fprintf(fid, '\nFull-sample transfer estimates and paired-bootstrap intervals:\n');
fprintf(fid, '  seed=%d; resamples=%d\n  construction=%s\n', ...
    bootstrapSeed, bootstrapResamples, bootstrapDrawDescription);
for k = 1:height(transfer)
    fprintf(fid, '  %s %s: ideal_ref_B=%g loss_ref_B=%g cost=%.6f CI=[%.6f, %.6f]\n', ...
        transfer.algorithm(k), transfer.objective(k), transfer.ideal_reference_B(k), ...
        transfer.loss_reference_B(k), transfer.cost_pct(k), ...
        transfer.ci95_lower(k), transfer.ci95_upper(k));
end
fprintf(fid, '\nRepeated paired ten-fold cross-fit:\n');
fprintf(fid, '  seed=%d; repetitions=%d; folds=%d\n  construction=%s\n', ...
    crossfitSeed, crossfitRepetitions, crossfitFolds, crossfitDescription);
fprintf(fid, '  selection frequencies (of %d folds):\n', crossfitRepetitions * crossfitFolds);
for k = 1:height(crossfitFrequencies)
    if crossfitFrequencies.selection_count(k) > 0
        fprintf(fid, '    %s %s %s B=%g: %d\n', crossfitFrequencies.algorithm(k), ...
            crossfitFrequencies.objective(k), crossfitFrequencies.comm_label(k), ...
            crossfitFrequencies.B(k), crossfitFrequencies.selection_count(k));
    end
end
fprintf(fid, '  held-out aggregate summaries across repetitions:\n');
for k = 1:height(crossfitSummary)
    fprintf(fid, ['    %s %s: mean_loss_at_ideal_ref=%.6f; mean_loss_at_loss_ref=%.6f; ', ...
        'mean_cost=%.6f; repetition_CI=[%.6f, %.6f]\n'], ...
        crossfitSummary.algorithm(k), crossfitSummary.objective(k), ...
        crossfitSummary.mean_loss_at_ideal_reference(k), ...
        crossfitSummary.mean_loss_at_loss_reference(k), crossfitSummary.mean_cost_pct(k), ...
        crossfitSummary.cost_ci95_lower(k), crossfitSummary.cost_ci95_upper(k));
end
fprintf(fid, ['  HIPC MiniSum: no held-out evidence that loss-conditioned retuning improves ', ...
    'performance; the mean cost and its repetition interval are negative.\n']);
fprintf(fid, '\nTarget-load reference-change audit:\n');
for k = 1:height(targetLoadChanges)
    fprintf(fid, '  targets=%g %s %s: ideal_B=%g loss_B=%g changed=%d\n', ...
        targetLoadChanges.target_count(k), targetLoadChanges.algorithm(k), ...
        targetLoadChanges.objective(k), targetLoadChanges.ideal_B(k), ...
        targetLoadChanges.loss_B(k), targetLoadChanges.changed(k));
end
for k = 1:height(targetLoadCounts)
    fprintf(fid, '  targets=%g: %d of 6 references change\n', ...
        targetLoadCounts.target_count(k), targetLoadCounts.changed_reference_count(k));
end
fprintf(fid, ['  HIPC changes at no tested load. The 5- and 20-target campaigns use ', ...
    '25 scenarios and are descriptive robustness checks.\n']);
fprintf(fid, '  PI 20-target loss MiniMax near tie: B=2 mean %.6f; B=1 mean %.6f\n', ...
    pi20B2, pi20B1);
fprintf(fid, '\nOutputs and dimensions:\n');
fprintf(fid, '  bundle_length_response.fig/.png/.pdf: %.2f x %.2f in; PDF %.3f x %.3f in\n', ...
    figure1Width, figure1Height, pdfSize1(1), pdfSize1(2));
fprintf(fid, ['  communication_configuration_transfer.fig/.png/.pdf: ', ...
    '%.2f x %.2f in; PDF %.3f x %.3f in\n'], ...
    figure2Width, figure2Height, pdfSize2(1), pdfSize2(2));
fprintf(fid, '  typography: %.1f pt %s throughout\n', fontSize, fontName);
fprintf(fid, '\nWarnings or discrepancies: none\n');
fprintf('Created validated IPCCC bundle-length figures in:\n%s\n', outputDir);

function tab = standardizeSystemTable(raw)
    tab = table(double(raw.trial_id), string(raw.algorithm), string(raw.comm_label), ...
        double(raw.target_count), double(raw.value), string(raw.trial_status), ...
        double(raw.total_team_steps), double(raw.max_robot_steps), string(raw.stage), ...
        'VariableNames', {'trial_id', 'algorithm', 'comm_label', 'target_count', ...
        'B', 'trial_status', 'effort', 'makespan', 'stage'});
end

function validateCells(tab, algorithms, bundleLengths, comms, targetCount, expectedIds, label)
    for a = 1:numel(algorithms)
        for c = 1:numel(comms)
            for B = bundleLengths
                block = tab(tab.algorithm == algorithms(a) & tab.comm_label == comms(c) & ...
                    tab.target_count == targetCount & tab.B == B, :);
                ids = sort(unique(block.trial_id));
                assertCondition(height(block) == numel(expectedIds) && isequal(ids, expectedIds), ...
                    sprintf('%s %s/%s/B=%g lacks the required paired IDs.', ...
                    label, algorithms(a), comms(c), B));
                assertCondition(all(isfinite(block.effort) & block.effort > 0 & ...
                    isfinite(block.makespan) & block.makespan > 0), sprintf( ...
                    '%s %s/%s/B=%g has non-finite or non-positive outcomes.', ...
                    label, algorithms(a), comms(c), B));
            end
        end
    end
end

function means = buildMeanTable(tab, algorithms, objectives, metrics, comms, bundleLengths, expectedN)
    nRows = numel(algorithms) * numel(objectives) * numel(comms) * numel(bundleLengths);
    algorithm = strings(nRows, 1); objective = strings(nRows, 1);
    metric = strings(nRows, 1); comm_label = strings(nRows, 1);
    B = zeros(nRows, 1); sample_size = zeros(nRows, 1); raw_mean = zeros(nRows, 1); row = 0;
    for a = 1:numel(algorithms)
        for o = 1:numel(objectives)
            for c = 1:numel(comms)
                for bundle = bundleLengths
                    row = row + 1;
                    block = tab(tab.algorithm == algorithms(a) & tab.comm_label == comms(c) & ...
                        tab.B == bundle, :);
                    algorithm(row) = algorithms(a); objective(row) = objectives(o);
                    metric(row) = metrics(o); comm_label(row) = comms(c); B(row) = bundle;
                    sample_size(row) = height(block); raw_mean(row) = mean(block.(metrics(o)));
                    assertCondition(sample_size(row) == expectedN, 'Unexpected mean-cell sample size.');
                end
            end
        end
    end
    means = table(algorithm, objective, metric, comm_label, B, sample_size, raw_mean);
end

function means = addResponses(means)
    means.change_from_B1_pct = nan(height(means), 1);
    for k = 1:height(means)
        baseline = means.algorithm == means.algorithm(k) & means.objective == means.objective(k) & ...
            means.comm_label == means.comm_label(k) & means.B == 1;
        assertCondition(nnz(baseline) == 1, 'A unique B=1 response baseline was not found.');
        means.change_from_B1_pct(k) = 100 * (means.raw_mean(k) / means.raw_mean(baseline) - 1);
    end
end

function refs = selectReferences(means, algorithms, objectives, comms, bundleLengths)
    nRows = numel(algorithms) * numel(objectives) * numel(comms);
    algorithm = strings(nRows, 1); objective = strings(nRows, 1);
    comm_label = strings(nRows, 1); reference_B = zeros(nRows, 1);
    reference_mean = zeros(nRows, 1); row = 0;
    for a = 1:numel(algorithms)
        for o = 1:numel(objectives)
            for c = 1:numel(comms)
                row = row + 1;
                block = means(means.algorithm == algorithms(a) & means.objective == objectives(o) & ...
                    means.comm_label == comms(c), :);
                block = sortrows(block, 'B');
                assertCondition(isequal(block.B', bundleLengths), 'Reference selection lacks a tested B.');
                minimum = min(block.raw_mean);
                firstMinimum = find(block.raw_mean == minimum, 1, 'first');
                algorithm(row) = algorithms(a); objective(row) = objectives(o);
                comm_label(row) = comms(c); reference_B(row) = block.B(firstMinimum);
                reference_mean(row) = block.raw_mean(firstMinimum);
            end
        end
    end
    refs = table(algorithm, objective, comm_label, reference_B, reference_mean);
end

function ranges = sameBundleDegradationRanges(means, algorithms, objectives)
    algorithm = strings(6, 1); objective = strings(6, 1);
    minimum_pct = zeros(6, 1); maximum_pct = zeros(6, 1); row = 0;
    for a = 1:numel(algorithms)
        for o = 1:numel(objectives)
            row = row + 1; changes = zeros(6, 1);
            for B = [1, 2, 3, 5, 8, 12]
                ideal = meanValue(means, algorithms(a), objectives(o), "ideal", B);
                loss = meanValue(means, algorithms(a), objectives(o), "bernoulli_025", B);
                changes(find([1, 2, 3, 5, 8, 12] == B, 1)) = 100 * (loss / ideal - 1);
            end
            algorithm(row) = algorithms(a); objective(row) = objectives(o);
            minimum_pct(row) = min(changes); maximum_pct(row) = max(changes);
        end
    end
    ranges = table(algorithm, objective, minimum_pct, maximum_pct);
end

function [transfer, description] = buildTransferTable(tab, means, refs, algorithms, objectives, ~, seed, nBoot)
    rng(seed, 'twister');
    nRows = numel(algorithms) * numel(objectives);
    algorithm = strings(nRows, 1); objective = strings(nRows, 1);
    ideal_reference_B = zeros(nRows, 1); loss_reference_B = zeros(nRows, 1);
    loss_mean_at_ideal_reference = zeros(nRows, 1); loss_mean_at_loss_reference = zeros(nRows, 1);
    cost_pct = zeros(nRows, 1); ci95_lower = zeros(nRows, 1); ci95_upper = zeros(nRows, 1); row = 0;
    for a = 1:numel(algorithms)
        sampleIndex = randi(300, 300, nBoot);
        for o = 1:numel(objectives)
            row = row + 1; metric = ["effort", "makespan"]; metric = metric(o);
            idealB = referenceValue(refs, algorithms(a), "MiniSum", "ideal");
            lossB = referenceValue(refs, algorithms(a), "MiniSum", "bernoulli_025");
            [ids1, values1] = cellVector(tab, algorithms(a), "bernoulli_025", idealB, metric);
            [ids2, values2] = cellVector(tab, algorithms(a), "bernoulli_025", lossB, metric);
            assertCondition(isequal(ids1, ids2) && isequal(ids1, (0:299)'), ...
                'Bootstrap inputs are not complete paired trial identifiers.');
            boot1 = mean(values1(sampleIndex), 1); boot2 = mean(values2(sampleIndex), 1);
            bootCost = 100 * (boot1 ./ boot2 - 1);
            algorithm(row) = algorithms(a); objective(row) = objectives(o);
            ideal_reference_B(row) = idealB; loss_reference_B(row) = lossB;
            loss_mean_at_ideal_reference(row) = meanValue(means, algorithms(a), objectives(o), ...
                "bernoulli_025", idealB);
            loss_mean_at_loss_reference(row) = meanValue(means, algorithms(a), objectives(o), ...
                "bernoulli_025", lossB);
            cost_pct(row) = 100 * (loss_mean_at_ideal_reference(row) / ...
                loss_mean_at_loss_reference(row) - 1);
            interval = prctile(bootCost, [2.5, 97.5]);
            ci95_lower(row) = interval(1); ci95_upper(row) = interval(2);
        end
    end
    transfer = table(algorithm, objective, ideal_reference_B, loss_reference_B, ...
        loss_mean_at_ideal_reference, loss_mean_at_loss_reference, cost_pct, ci95_lower, ci95_upper);
    description = "Within each algorithm, one 300-by-20000 trial-ID index matrix was sampled with replacement and reused for paired MiniSum/MiniMax ratios.";
end

function [summary, frequencies, description] = repeatedCrossfit(tab, algorithms, objectives, comms, ...
        bundleLengths, seed, repetitions, folds)
    rng(seed, 'twister'); ids = (0:299)';
    counts = zeros(numel(algorithms), numel(objectives), numel(comms), numel(bundleLengths));
    repetitionCost = zeros(repetitions, numel(algorithms), numel(objectives));
    repetitionNumerator = zeros(size(repetitionCost)); repetitionDenominator = zeros(size(repetitionCost));
    metricNames = ["effort", "makespan"];
    for repetition = 1:repetitions
        permutation = ids(randperm(numel(ids)));
        foldById = zeros(numel(ids), 1);
        for k = 1:numel(ids), foldById(permutation(k) + 1) = mod(k - 1, folds) + 1; end
        for a = 1:numel(algorithms)
            for o = 1:numel(objectives)
                numerator = nan(300, 1); denominator = nan(300, 1);
                for fold = 1:folds
                    heldIds = ids(foldById == fold); trainIds = ids(foldById ~= fold);
                    selected = zeros(1, 2);
                    for c = 1:numel(comms)
                        selected(c) = selectTrainingReference(tab, algorithms(a), comms(c), ...
                            metricNames(o), bundleLengths, trainIds);
                        counts(a, o, c, bundleLengths == selected(c)) = ...
                            counts(a, o, c, bundleLengths == selected(c)) + 1;
                    end
                    [evalIds1, eval1] = heldVector(tab, algorithms(a), "bernoulli_025", ...
                        selected(1), metricNames(o), heldIds);
                    [evalIds2, eval2] = heldVector(tab, algorithms(a), "bernoulli_025", ...
                        selected(2), metricNames(o), heldIds);
                    assertCondition(isequal(evalIds1, evalIds2), 'Cross-fit held-out IDs are not paired.');
                    numerator(evalIds1 + 1) = eval1; denominator(evalIds2 + 1) = eval2;
                end
                assertCondition(all(isfinite(numerator) & isfinite(denominator)), ...
                    'Cross-fit did not produce all 300 out-of-fold predictions.');
                repetitionNumerator(repetition, a, o) = mean(numerator);
                repetitionDenominator(repetition, a, o) = mean(denominator);
                repetitionCost(repetition, a, o) = 100 * (mean(numerator) / mean(denominator) - 1);
            end
        end
    end
    nFreq = numel(algorithms) * numel(objectives) * numel(comms) * numel(bundleLengths);
    algorithm = strings(nFreq, 1); objective = strings(nFreq, 1);
    comm_label = strings(nFreq, 1); B = zeros(nFreq, 1); selection_count = zeros(nFreq, 1); row = 0;
    for a = 1:numel(algorithms)
        for o = 1:numel(objectives)
            for c = 1:numel(comms)
                for b = 1:numel(bundleLengths)
                    row = row + 1; algorithm(row) = algorithms(a); objective(row) = objectives(o);
                    comm_label(row) = comms(c); B(row) = bundleLengths(b);
                    selection_count(row) = counts(a, o, c, b);
                end
            end
        end
    end
    frequencies = table(algorithm, objective, comm_label, B, selection_count);
    nSummary = numel(algorithms) * numel(objectives);
    algorithm = strings(nSummary, 1); objective = strings(nSummary, 1);
    mean_loss_at_ideal_reference = zeros(nSummary, 1);
    mean_loss_at_loss_reference = zeros(nSummary, 1); mean_cost_pct = zeros(nSummary, 1);
    cost_ci95_lower = zeros(nSummary, 1); cost_ci95_upper = zeros(nSummary, 1); row = 0;
    for a = 1:numel(algorithms)
        for o = 1:numel(objectives)
            row = row + 1; costs = repetitionCost(:, a, o);
            algorithm(row) = algorithms(a); objective(row) = objectives(o);
            mean_loss_at_ideal_reference(row) = mean(repetitionNumerator(:, a, o));
            mean_loss_at_loss_reference(row) = mean(repetitionDenominator(:, a, o));
            mean_cost_pct(row) = mean(costs);
            interval = prctile(costs, [2.5, 97.5]);
            cost_ci95_lower(row) = interval(1); cost_ci95_upper(row) = interval(2);
        end
    end
    summary = table(algorithm, objective, mean_loss_at_ideal_reference, ...
        mean_loss_at_loss_reference, mean_cost_pct, cost_ci95_lower, cost_ci95_upper);
    description = "For each repetition, trial IDs 0--299 were randomly permuted once with MATLAB twister RNG, assigned round-robin to 10 folds, and kept intact across every B and network; 300 held-out predictions were aggregated before each ratio of means.";
end

function selected = selectTrainingReference(tab, algorithm, comm, metric, bundleLengths, trainIds)
    means = zeros(size(bundleLengths));
    for k = 1:numel(bundleLengths)
        idx = tab.algorithm == algorithm & tab.comm_label == comm & tab.B == bundleLengths(k) & ...
            ismember(tab.trial_id, trainIds);
        means(k) = mean(tab.(metric)(idx));
    end
    minimum = min(means); selected = bundleLengths(find(means == minimum, 1, 'first'));
end

function [ids, values] = cellVector(tab, algorithm, comm, B, metric)
    idx = tab.algorithm == algorithm & tab.comm_label == comm & tab.B == B;
    block = sortrows(table(tab.trial_id(idx), tab.(metric)(idx), ...
        'VariableNames', {'trial_id', 'value'}), 'trial_id');
    ids = block.trial_id; values = block.value;
end

function [ids, values] = heldVector(tab, algorithm, comm, B, metric, heldIds)
    [allIds, allValues] = cellVector(tab, algorithm, comm, B, metric);
    keep = ismember(allIds, heldIds); ids = allIds(keep); values = allValues(keep);
end

function [changes, counts] = referenceChangeAudit(refs, algorithms, objectives)
    n = 3 * numel(algorithms) * numel(objectives);
    target_count = zeros(n, 1); algorithm = strings(n, 1); objective = strings(n, 1);
    ideal_B = zeros(n, 1); loss_B = zeros(n, 1); changed = false(n, 1); row = 0;
    for target = [5, 10, 20]
        for a = 1:numel(algorithms)
            for o = 1:numel(objectives)
                row = row + 1; target_count(row) = target; algorithm(row) = algorithms(a);
                objective(row) = objectives(o);
                block = refs(refs.target_count == target & refs.algorithm == algorithms(a) & ...
                    refs.objective == objectives(o), :);
                ideal_B(row) = block.reference_B(block.comm_label == "ideal");
                loss_B(row) = block.reference_B(block.comm_label == "bernoulli_025");
                changed(row) = ideal_B(row) ~= loss_B(row);
            end
        end
    end
    changes = table(target_count, algorithm, objective, ideal_B, loss_B, changed);
    counts = table([5; 10; 20], zeros(3, 1), ...
        'VariableNames', {'target_count', 'changed_reference_count'});
    for k = 1:3
        counts.changed_reference_count(k) = nnz(changes.changed(changes.target_count == counts.target_count(k)));
    end
end

function value = meanValue(means, algorithm, objective, comm, B)
    idx = means.algorithm == algorithm & means.objective == objective & ...
        means.comm_label == comm & means.B == B;
    assertCondition(nnz(idx) == 1, 'A requested raw mean is missing or duplicated.');
    value = means.raw_mean(idx);
end

function value = referenceValue(refs, algorithm, objective, comm)
    idx = refs.algorithm == algorithm & refs.objective == objective & refs.comm_label == comm;
    assertCondition(nnz(idx) == 1, 'A requested reference is missing or duplicated.');
    value = refs.reference_B(idx);
end

function assertReference(refs, algorithm, objective, comm, expected)
    observed = referenceValue(refs, algorithm, objective, comm);
    assertCondition(observed == expected, sprintf( ...
        '%s %s %s reference is B=%g; expected B=%g.', algorithm, objective, comm, observed, expected));
end

function checkApproxInterval(transfer, algorithm, objective, expected, tolerance)
    idx = transfer.algorithm == algorithm & transfer.objective == objective;
    observed = [transfer.ci95_lower(idx), transfer.ci95_upper(idx)];
    assertCondition(all(abs(observed - expected) <= tolerance), sprintf( ...
        '%s %s bootstrap CI [%.3f, %.3f] differs from expected [%.1f, %.1f].', ...
        algorithm, objective, observed(1), observed(2), expected(1), expected(2)));
end

function assertFrequency(frequencies, algorithm, objective, comm, B, expected)
    observed = frequencyValue(frequencies, algorithm, objective, comm, B);
    assertCondition(observed == expected, sprintf( ...
        '%s %s %s B=%g cross-fit frequency is %d; expected %d.', ...
        algorithm, objective, comm, B, observed, expected));
end

function value = frequencyValue(frequencies, algorithm, objective, comm, B)
    idx = frequencies.algorithm == algorithm & frequencies.objective == objective & ...
        frequencies.comm_label == comm & frequencies.B == B;
    assertCondition(nnz(idx) == 1, 'A requested cross-fit frequency is missing.');
    value = frequencies.selection_count(idx);
end

function assertCrossfitCost(summary, algorithm, objective, expected, tolerance)
    idx = summary.algorithm == algorithm & summary.objective == objective;
    observed = summary.mean_cost_pct(idx);
    assertCondition(abs(observed - expected) <= tolerance, sprintf( ...
        '%s %s cross-fit cost is %.3f%%; expected approximately %.1f%%.', ...
        algorithm, objective, observed, expected));
end

function fig = makeFigure(width, height)
    fig = figure('Color', 'white', 'Units', 'inches', 'Position', [1, 1, width, height], ...
        'PaperUnits', 'inches', 'PaperSize', [width, height], ...
        'PaperPosition', [0, 0, width, height], 'PaperPositionMode', 'manual', ...
        'InvertHardcopy', 'off', 'Visible', 'off');
end

function configureAxes(ax, fontSize, fontName)
    set(ax, 'FontName', fontName, 'FontSize', fontSize, 'LineWidth', 0.65, ...
        'TitleFontSizeMultiplier', 1, 'LabelFontSizeMultiplier', 1, ...
        'Box', 'on', 'Layer', 'top');
end

function applyUniformTypography(fig, fontSize, fontName)
    layouts = findall(fig, 'Type', 'tiledlayout');
    for k = 1:numel(layouts)
        layouts(k).XLabel.FontSize = fontSize; layouts(k).YLabel.FontSize = fontSize;
        layouts(k).Title.FontSize = fontSize; layouts(k).XLabel.FontName = fontName;
        layouts(k).YLabel.FontName = fontName; layouts(k).Title.FontName = fontName;
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
end

function validateFigure1(fig, objectiveLimits, fontSize, fontName, width, height)
    validateFigureLayout(fig, 6, fontSize, fontName, width, height, 'bundle_length_response');
    axesObjects = findall(fig, 'Type', 'axes');
    for k = 1:numel(axesObjects)
        observed = axesObjects(k).YLim;
        matches = max(abs(observed - objectiveLimits(1, :))) < 1e-10 || ...
            max(abs(observed - objectiveLimits(2, :))) < 1e-10;
        assertCondition(matches, 'A bundle-response panel does not use its column-wide y limits.');
    end
end

function validateFigureLayout(fig, expectedAxes, fontSize, fontName, width, height, name)
    drawnow;
    oldUnits = fig.Units; fig.Units = 'inches'; observedSize = fig.Position(3:4);
    assertCondition(all(abs(observedSize - [width, height]) < 0.01), ...
        sprintf('%s has incorrect canvas dimensions.', name));
    fig.Units = oldUnits;
    axesObjects = findall(fig, 'Type', 'axes');
    assertCondition(numel(axesObjects) == expectedAxes, sprintf( ...
        '%s has %d axes; expected %d.', name, numel(axesObjects), expectedAxes));
    objects = findall(fig, '-property', 'FontSize');
    for k = 1:numel(objects)
        assertCondition(abs(double(objects(k).FontSize) - fontSize) < 1e-9, ...
            sprintf('%s contains text that is not %.1f pt.', name, fontSize));
        if isprop(objects(k), 'FontName')
            assertCondition(strcmpi(string(objects(k).FontName), fontName), ...
                sprintf('%s contains text that is not %s.', name, fontName));
        end
    end
    layouts = findall(fig, 'Type', 'tiledlayout');
    for k = 1:numel(layouts)
        sizes = [layouts(k).XLabel.FontSize, layouts(k).YLabel.FontSize, layouts(k).Title.FontSize];
        assertCondition(all(abs(sizes - fontSize) < 1e-9), 'A tiled-layout label has the wrong size.');
    end
    legends = findall(fig, 'Type', 'legend');
    assertCondition(isscalar(legends), sprintf('%s does not have one compact shared legend.', name));
    fig.Units = 'pixels'; figBox = [0, 0, fig.Position(3), fig.Position(4)];
    legendBox = getpixelposition(legends, true);
    assertCondition(isInside(legendBox, figBox, 3), sprintf('%s legend is clipped.', name));
    for k = 1:numel(axesObjects)
        assertCondition(rectangleIntersectionArea(getpixelposition(axesObjects(k), true), legendBox) < 1, ...
            sprintf('%s legend overlaps a panel.', name));
    end
    fig.Units = oldUnits;
end

function exportTriplet(fig, basePath)
    savefig(fig, basePath + ".fig");
    exportgraphics(fig, basePath + ".png", 'Resolution', 300, 'Padding', 'figure');
    exportgraphics(fig, basePath + ".pdf", 'ContentType', 'vector', 'Padding', 'figure');
end

function pageInches = verifyPdfPageSize(pdfFile, expectedWidth, expectedHeight)
    fid = fopen(pdfFile, 'r'); assertCondition(fid >= 0, sprintf('Could not read %s.', pdfFile));
    cleanup = onCleanup(@() fclose(fid)); bytes = fread(fid, Inf, '*uint8')'; text = char(bytes);
    token = regexp(text, '/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*\]', ...
        'tokens', 'once');
    assertCondition(~isempty(token), sprintf('Could not locate the PDF MediaBox in %s.', pdfFile));
    points = str2double(string(token));
    pageInches = [(points(3) - points(1)) / 72, (points(4) - points(2)) / 72];
    assertCondition(all(abs(pageInches - [expectedWidth, expectedHeight]) <= 0.03), sprintf( ...
        '%s PDF page is %.3f x %.3f in; expected %.2f x %.2f in.', ...
        pdfFile, pageInches(1), pageInches(2), expectedWidth, expectedHeight));
end

function printReferenceTable(fid, refs)
    for k = 1:height(refs)
        fprintf(fid, '  %s %s %s: B=%g mean=%.9f\n', refs.algorithm(k), refs.objective(k), ...
            refs.comm_label(k), refs.reference_B(k), refs.reference_mean(k));
    end
end

function printMeanTable(fid, means)
    for k = 1:height(means)
        fprintf(fid, '  %s %s %s B=%g n=%d mean=%.9f change=%.9f%%\n', ...
            means.algorithm(k), means.objective(k), means.comm_label(k), means.B(k), ...
            means.sample_size(k), means.raw_mean(k), means.change_from_B1_pct(k));
    end
end

function hash = sha256File(path)
    digest = java.security.MessageDigest.getInstance('SHA-256');
    fid = fopen(path, 'r'); assertCondition(fid >= 0, sprintf('Could not hash %s.', path));
    cleanup = onCleanup(@() fclose(fid));
    while ~feof(fid)
        bytes = fread(fid, 1048576, '*uint8');
        if ~isempty(bytes), digest.update(bytes); end
    end
    raw = typecast(digest.digest(), 'uint8');
    hash = lower(string(reshape(dec2hex(raw, 2).', 1, [])));
end

function requireColumns(tab, columns, source)
    missing = columns(~ismember(columns, string(tab.Properties.VariableNames)));
    assertCondition(isempty(missing), sprintf('Missing columns in %s: %s.', source, strjoin(missing, ', ')));
end

function mustExist(path, description)
    assertCondition(isfile(path), sprintf('%s not found: %s', description, path));
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

function assertCondition(condition, message)
    if ~condition, error('ipccc_bundle_length:validation', '%s', message); end
end
