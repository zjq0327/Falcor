#pragma once
#include "RTPTGRISTypes.slang"
import Utils.Sampling.SampleGenerator;

bool rtptSelectGrisTerminal(inout TerminalPicker picker, inout SampleGenerator rng, float3 contribution, GrisTerminalKind kind)
{
    // A scalar luminance of the magnitudes covers every nonzero RGB contribution.
    const float h = dot(abs(contribution), float3(0.2126f, 0.7152f, 0.0722f));
    if (!(h > 0.f)) return false;
    picker.sumH += h;
    if (sampleNext1D(rng) * picker.sumH < h)
    {
        picker.winnerH = h;
        picker.winnerF = contribution;
        picker.winnerKind = uint(kind);
        return true;
    }
    return false;
}
