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
#if ENABLE_SHARC && SHARC_QUERY && !RTPT_GRIS_CACHE_TAIL
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
#if RTPT_GRIS_SUFFIX_REPLAY || RTPT_GRIS_DUAL_DYNAMIC_REPLAY
StructuredBuffer<uint> gGRISReplayMovedInstances;

bool rtptGrisReplayStaticSurface(PackedHitInfo packed)
{
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle) return false;
    return gGRISReplayMovedInstances[hit.getTriangleHit().instanceID.index] == 0u;
}
#endif

#if RTPT_GRIS_DUAL_DYNAMIC_REPLAY
struct GrisReplayMovedBounds
{
    float3 minPoint;
    float3 maxPoint;
};

StructuredBuffer<GrisReplayMovedBounds> gGRISReplayMovedBounds;

bool rtptGrisReplayRayClear(Ray ray, uint count)
{
    if (count == 0u || !all(isfinite(ray.origin)) || !all(isfinite(ray.dir)) ||
        !isfinite(ray.tMin) || !isfinite(ray.tMax) || ray.tMax < ray.tMin) return false;
    // Include the ray's arithmetic scale as well as the host's transform padding.
    const float3 scale = max(abs(ray.origin), abs(ray.dir) * max(abs(ray.tMin), abs(ray.tMax)));
    const float3 padding = max(1.f, scale) * 1.9073486328125e-6f;
    if (!all(isfinite(padding))) return false;
    [loop] for (uint i = 0u; i < count; ++i)
    {
        const GrisReplayMovedBounds bounds = gGRISReplayMovedBounds[i];
        const float3 lo = bounds.minPoint - padding;
        const float3 hi = bounds.maxPoint + padding;
        float nearT = ray.tMin;
        float farT = ray.tMax;
        bool intersects = true;
        [unroll] for (uint axis = 0u; axis < 3u; ++axis)
        {
            if (ray.dir[axis] == 0.f)
                intersects = intersects && ray.origin[axis] >= lo[axis] && ray.origin[axis] <= hi[axis];
            else
            {
                const float a = (lo[axis] - ray.origin[axis]) / ray.dir[axis];
                const float b = (hi[axis] - ray.origin[axis]) / ray.dir[axis];
                nearT = max(nearT, min(a, b));
                farT = min(farT, max(a, b));
            }
        }
        if (intersects && nearT <= farT) return false;
    }
    return true;
}
#endif

#if defined(RTPT_GRIS_TEMPORAL_REUSE) && ((RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_STORED_PREFIX_REUSE)) || RTPT_GRIS_DUAL_DYNAMIC_REPLAY)
struct GrisReplayInstanceTransform
{
    float4x4 world;
    float4x4 inverseTransposeWorld;
};

// These transforms belong to the frame that published the history reservoir.
StructuredBuffer<GrisReplayInstanceTransform> gGRISReplayPreviousInstanceTransforms;
#endif

// The represented prefix is defined by packed surface hits. Generate and
// reconnection must use the same geometry and view normalization: a sampled
// ray cannot be recovered exactly from float intersection barycentrics, and
// even a tiny direction error changes a grazing BSDF by several percent.
VertexData rtptGrisPrefixVertex(TriangleHit triangle, bool previousGeometry = false)
{
    StaticVertexData vertices[3];
    VertexData vertex;
    float4x4 world;
#if defined(RTPT_GRIS_TEMPORAL_REUSE) && ((RTPT_GRIS_SUFFIX_REPLAY && defined(RTPT_GRIS_STORED_PREFIX_REUSE)) || RTPT_GRIS_DUAL_DYNAMIC_REPLAY)
    if (previousGeometry)
    {
        // Temporal replay only enables this path for rigid motion, so the
        // object-space vertices and barycentric coordinates are unchanged.
        const uint3 indices = gScene.getIndices(triangle.instanceID, triangle.primitiveIndex);
        vertices = { gScene.getVertex(indices[0]), gScene.getVertex(indices[1]), gScene.getVertex(indices[2]) };
        const GrisReplayInstanceTransform transform = gGRISReplayPreviousInstanceTransforms[triangle.instanceID.index];
        world = transform.world;
        vertex = gScene.computeVertexData(vertices, world, float3x3(transform.inverseTransposeWorld),
            gScene.isObjectFrontFaceCW(triangle.instanceID), triangle.getBarycentricWeights());
    }
    else
#endif
    {
        vertex = gScene.getVertexData(triangle, vertices);
        world = gScene.getWorldMatrix(triangle.instanceID);
    }
    // Affine interpolation preserves constant plane coordinates. Explicit
    // precision prevents separate Generate/reuse compilations from choosing
    // different reassociations or fused operations for the same packed hit.
    precise float3 positionO = vertices[0].position +
        triangle.barycentrics.x * (vertices[1].position - vertices[0].position) +
        triangle.barycentrics.y * (vertices[2].position - vertices[0].position);
    precise float3 positionW = mul(world, float4(positionO, 1.f)).xyz;
    vertex.posW = positionW;
    return vertex;
}

bool rtptGrisRefPosition(PackedHitInfo packed, out float3 position, bool previousGeometry = false)
{
    position = 0.f;
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle) return false;
    position = rtptGrisPrefixVertex(hit.getTriangleHit(), previousGeometry).posW;
    return all(isfinite(position));
}

bool rtptGrisRefLoad(PackedHitInfo packed, float3 view, out ShadingData sd, bool previousGeometry = false)
{
    sd = {};
    const HitInfo hit = HitInfo(packed);
    if (hit.getType() != HitType::Triangle || !all(isfinite(view))) return false;
    const float viewLengthSquared = dot(view, view);
    if (!(viewLengthSquared > 0.f) || !isfinite(viewLengthSquared)) return false;
    const TriangleHit triangle = hit.getTriangleHit();
    sd = gScene.materials.prepareShadingData(rtptGrisPrefixVertex(triangle, previousGeometry),
        gScene.getMaterialID(triangle.instanceID), view * rsqrt(viewLengthSquared));
    sd.mtl.setActiveLobes(uint(LobeType::Reflection));
    return true;
}

bool rtptGrisRefPrimary(PackedHitInfo primaryHit, float3 cameraPosition, out ShadingData primary,
    bool previousGeometry = false)
{
    float3 position;
    primary = {};
    return rtptGrisRefPosition(primaryHit, position, previousGeometry) &&
        rtptGrisRefLoad(primaryHit, cameraPosition - position, primary, previousGeometry);
}

#endif
