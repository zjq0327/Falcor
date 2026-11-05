#pragma once

import Scene.ShadingData;
import Scene.Material.MaterialTypes;
import Rendering.Materials.LobeType;

bool rtptGRISSupportsSurface(ShadingData sd, uint lobes)
{
    const MaterialType material = sd.mtl.getMaterialType();
    const uint continuousReflection = uint(LobeType::NonDeltaReflection);
    return sd.frontFacing && (material == MaterialType::PBRTDiffuse || material == MaterialType::Standard) &&
        lobes != 0u && (lobes & ~continuousReflection) == 0u;
}
