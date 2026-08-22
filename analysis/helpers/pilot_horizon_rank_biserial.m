function [rrb, wPlus, wMinus, nonzeroCount] = pilot_horizon_rank_biserial(differences)
%PILOT_HORIZON_RANK_BISERIAL Rank-biserial effect size for paired changes.
%
% Positive values mean that positive differences dominate. Zeros and
% non-finite values are excluded, matching the Wilcoxon signed-rank
% convention used by the active DCTA analyses.

delta = double(differences(:));
delta = delta(isfinite(delta) & delta ~= 0);
nonzeroCount = numel(delta);
if isempty(delta)
    rrb = 0;
    wPlus = 0;
    wMinus = 0;
    return;
end

[sortedValues, order] = sort(abs(delta));
ranksSorted = nan(size(sortedValues));
first = 1;
while first <= numel(sortedValues)
    last = first;
    while last < numel(sortedValues) && sortedValues(last + 1) == sortedValues(first)
        last = last + 1;
    end
    ranksSorted(first:last) = mean(first:last);
    first = last + 1;
end
ranks = nan(size(delta));
ranks(order) = ranksSorted;
wPlus = sum(ranks(delta > 0));
wMinus = sum(ranks(delta < 0));
denominator = wPlus + wMinus;
rrb = (wPlus - wMinus) / denominator;
rrb = min(max(rrb, -1), 1);
end
