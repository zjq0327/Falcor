#pragma once
#include "RTPTVXPGTypes.slang"

// Importance history, not cached transport radiance. Weight decays lazily
// between positive observations; missing observations do not mean zero light.
RTPTVXPGHistory rtptVXPGResolveHistory(RTPTVXPGHistory previous, float mean, uint count, uint window, uint lifetime)
{
    if (count == 0)
    {
        if (previous.valid != 0 && ++previous.age >= lifetime) previous = {};
        return previous;
    }
    const float retention = 1.f - rcp(float(max(window, 1u)));
    const float oldWeight = previous.valid != 0 ? previous.weight * pow(retention, float(previous.age + 1u)) : 0.f;
    const float total = oldWeight + float(count);
    RTPTVXPGHistory result;
    result.mean = oldWeight > 0.f ? lerp(previous.mean, mean, float(count) / total) : mean;
    result.weight = total;
    result.age = 0;
    // Bit 1 marks borrowed LOD history. It cannot donate to another level,
    // preventing feedback amplification through repeated camera crossings.
    result.valid = previous.valid | 1u;
    return result;
}
