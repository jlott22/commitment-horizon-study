function value = pilot_horizon_percentile(values, pct)
%PILOT_HORIZON_PERCENTILE Type-7 linear percentile used by DCTA analyses.

data = sort(double(values(:)));
data = data(isfinite(data));
if isempty(data)
    value = NaN;
    return;
end
if numel(data) == 1
    value = data(1);
    return;
end

position = 1 + (double(pct) / 100) * (numel(data) - 1);
lowerIndex = floor(position);
upperIndex = ceil(position);
if lowerIndex == upperIndex
    value = data(lowerIndex);
else
    weight = position - lowerIndex;
    value = data(lowerIndex) + weight * (data(upperIndex) - data(lowerIndex));
end
end
