function adjusted = pilot_horizon_holm_adjust(pValues)
%PILOT_HORIZON_HOLM_ADJUST Holm step-down adjustment for a p-value family.
%
% Non-finite entries are retained as NaN and do not contribute to the family
% size. This mirrors the active DCTA MATLAB analysis convention.

pValues = double(pValues);
adjusted = nan(size(pValues));
valid = find(isfinite(pValues));
if isempty(valid)
    return;
end

[sortedP, order] = sort(pValues(valid));
m = numel(sortedP);
scaled = (m - (1:m)' + 1) .* sortedP(:);
scaled = cummax(scaled);
scaled = min(1, scaled);

sortedIndices = valid(order);
adjusted(sortedIndices) = scaled;
end
