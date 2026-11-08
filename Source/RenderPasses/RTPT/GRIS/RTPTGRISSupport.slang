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

bool rtptGRISSupportsFirstVertex(ShadingData sd, uint lobes)
{
    // A single diffuse lobe has the same proposal in sampling and evaluation.
    return lobes == uint(LobeType::DiffuseReflection) && rtptGRISSupportsSurface(sd, lobes);
}

bool rtptGRISPathReuseEnabled()
{
#if RTPT_REGIR_TRANSPORT && (!RTPT_REGIR_ONLY || !RTPT_GRIS_REFERENCE_REUSE)
    return false;
#else
#if ENABLE_SHARC && SHARC_QUERY
    if (gSharcSettings.useCache != 0u) return false;
#endif
    return true;
#endif
}

bool rtptGrisPrefixDirection(float3 origin, float3 position, out float3 direction, out float distanceSquared)
{
    precise float3 edge = position - origin;
    precise float squared = dot(edge, edge);
    distanceSquared = squared;
    direction = 0.f;
    if (!(distanceSquared > 0.f) || !isfinite(distanceSquared)) return false;
    direction = edge * rsqrt(distanceSquared);
    return all(isfinite(direction));
}

#if (RTPT_GRIS_SPATIAL || RTPT_USE_GRIS) && !RTPT_GRIS_ALTERNATING && SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
// The represented prefix is defined by packed surface hits. Generate and
// reconnection must use the same geometry and view normalization: a sampled
// ray cannot be recovered exactly from float intersection barycentrics, and
// even a tiny direction error changes a grazing BSDF by several percent.
VertexData rtptGrisPrefixVertex(TriangleHit triangle)
{
    StaticVertexData vertices[3];
    VertexData vertex = gScene.getVertexData(triangle, vertices);
    // Affine interpolation preserves constant plane coordinates. Explicit
    // precision prevents separate Generate/reuse compilations from choosing
    // different reassociations or fused operations for the same packed hit.
    precise float3 positionO = vertices[0].position +
        triangle.barycentrics.x * (vertices[1].position - vertices[0].position) +
        triangle.barycentrics.y * (vertices[2].position - vertices[0].position);
    precise float3 positionW = mul(gScene.getWorldMatrix(triangle.instanceID), float4(positionO, 1.f)).xyz;
    vertex.posW = positionW;
    return vertex;
}

bool rtptGrisRefPosition(PackedHitInfo packed, out float3 position)
{
    position = 0.f;
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle) return false;
    position = rtptGrisPrefixVertex(hit.getTriangleHit()).posW;
    return all(isfinite(position));
}

bool rtptGrisRefLoad(PackedHitInfo packed, float3 view, out ShadingData sd)
{
    sd = {};
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle || !all(isfinite(view))) return false;
    const float viewLengthSquared = dot(view, view);
    if (!(viewLengthSquared > 0.f) || !isfinite(viewLengthSquared)) return false;
    const TriangleHit triangle = hit.getTriangleHit();
    sd = gScene.materials.prepareShadingData(rtptGrisPrefixVertex(triangle),
        gScene.getMaterialID(triangle.instanceID), view * rsqrt(viewLengthSquared));
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    return true;
}

bool rtptGrisRefPrimary(PackedHitInfo primaryHit, float3 cameraPosition, out ShadingData primary)
{
    float3 position;
    primary = {};
    return rtptGrisRefPosition(primaryHit, position) &&
        rtptGrisRefLoad(primaryHit, cameraPosition - position, primary);
}

#endif
