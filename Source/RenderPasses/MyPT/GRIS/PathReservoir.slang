__exported import PathState;
__exported import Utils.Sampling.SampleGenerator;

// Same scalar target as the reference PathReservoir.slang. F already contains 1/p in PSS.
float pathTarget(float3 F) { return dot(F, float3(0.299f, 0.587f, 0.114f)); }

// Keep the usual arithmetic for ordinary values, but do not lose a representable
// final mass because an intermediate product overflows or underflows.
float resamplingMass(float target, float jacobian, float W, float mis)
{
    if (target <= 0.f || jacobian <= 0.f || W <= 0.f || mis <= 0.f) return 0.f;
    float mass = target * jacobian * W * mis;
    if (isfinite(mass) && mass > 0.f) return mass;
    return exp2(log2(target) + log2(jacobian) + log2(W) + log2(mis));
}

float balanceProductMass(float3 a, float3 b, float bothZero)
{
    bool hasA = all(a > 0.f);
    bool hasB = all(b > 0.f);
    if (!hasA) return hasB ? 0.f : bothZero;
    if (!hasB) return 1.f;
    float massA = a.x * a.y * a.z;
    float massB = b.x * b.y * b.z;
    if (massA > 0.f && massB > 0.f && isfinite(massA + massB)) return massA / (massA + massB);
    float logA = log2(a.x) + log2(a.y) + log2(a.z);
    float logB = log2(b.x) + log2(b.y) + log2(b.z);
    float scale = max(logA, logB);
    massA = exp2(logA - scale);
    massB = exp2(logB - scale);
    return massA / (massA + massB);
}

struct PathReservoir
{
    PathSample sample;
    float weightSum;            // Raw accumulator, never overwritten by normalized W.
    float W;
    float M;                   // Initial tree count; accumulated confidence after correlated reuse.
    uint invalidCount;

    [mutating]
    void addContribution(PathSample candidate, inout SampleGenerator selection)
    {
        if (any(!isfinite(candidate.F)) || any(candidate.F < 0.f)) { invalidCount++; return; }
        float weight = pathTarget(candidate.F);
        if (weight <= 0.f) return;
        if (!isfinite(weightSum + weight)) { invalidCount++; return; }
        weightSum += weight;
        if (sampleNext1D(selection) * weightSum < weight) sample = candidate;
    }

    [mutating]
    void mergeTree(PathReservoir tree, inout SampleGenerator selection)
    {
        // Reference PathBuilder.finalize() resets the contribution count to one tree.
        M += tree.M;
        invalidCount += tree.invalidCount;
        if (tree.weightSum <= 0.f) return;
        if (!isfinite(weightSum + tree.weightSum)) { invalidCount++; return; }
        weightSum += tree.weightSum;
        if (sampleNext1D(selection) * weightSum < tree.weightSum) sample = tree.sample;
    }

    [mutating]
    void finalizeRIS()
    {
        float target = pathTarget(sample.F);
        W = target > 0.f && M > 0 ? (weightSum / float(M)) / target : 0.f;
        if (!isfinite(W)) { W = 0.f; invalidCount++; }
    }

    [mutating]
    void mergeWithResamplingMIS(PathSample shifted, float jacobian, PathReservoir source,
        float mis, inout SampleGenerator selection)
    {
        // Reference PathReservoir.mergeWithResamplingMIS: M is already in the MIS weights.
        M += source.M;
        invalidCount += source.invalidCount;
        float weight = resamplingMass(pathTarget(shifted.F), jacobian, source.W, mis);
        if (!isfinite(weight) || weight < 0.f || !isfinite(weightSum + weight)) { invalidCount++; return; }
        if (weight == 0.f) return;
        weightSum += weight;
        if (sampleNext1D(selection) * weightSum < weight) sample = shifted;
    }

    [mutating]
    void finalizeGRIS(uint validNeighbors)
    {
        float target = pathTarget(sample.F);
        W = target > 0.f ? (weightSum / float(validNeighbors + 1)) / target : 0.f;
        if (!isfinite(W)) { W = 0.f; invalidCount++; }
    }
};
