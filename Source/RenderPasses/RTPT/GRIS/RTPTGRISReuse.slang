#pragma once
#include "RTPTGRISTypes.slang"
#include "RTPTGRISSupport.slang"

#ifndef RTPT_GRIS_SPATIAL_REUSE
#define RTPT_GRIS_SPATIAL_REUSE 0
#endif

float rtptGrisTarget(float3 F)
{
    return dot(abs(F), float3(0.2126f, 0.7152f, 0.0722f));
}
