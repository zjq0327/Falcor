__exported import PathState;
__exported import Utils.Sampling.SampleGenerator;

// Same scalar target as the reference PathReservoir.slang. F already contains 1/p in PSS.
float pathTarget(float3 F) { return dot(F, float3(0.299f, 0.587f, 0.114f)); }

struct PathReservoir
{
    PathSample sample;
    float weightSum;            // Raw accumulator, never overwritten by normalized W.
    float W;
    uint M;                    // Number of independent path trees, including zero trees.
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
};
