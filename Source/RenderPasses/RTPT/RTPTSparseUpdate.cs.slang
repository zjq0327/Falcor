/** Shared sparse BSDF-only training paths, always Compute Shader + RayQuery. */
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveUniformSampler;
import Rendering.Lights.EmissiveLightSamplerInterface;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Materials.IsotropicGGX;

struct RTPTParams
{
    uint2 frameDim;
    uint samplesPerPixel;
    uint maxBounces;
    uint rrStartBounce;
    uint seed;
    uint sampleOffset;
    uint accumulatedSamples;
    uint useNEE;
    uint useRussianRoulette;
    uint accumulate;
};
struct RTPTSparseSettings
{
    uint2 frameDim;
    uint updateStride;
    uint frameIndex;
    uint updateBounces;
    uint writeSHARC;
    uint recordPG;
};
ConstantBuffer<RTPTParams> gParams;
ConstantBuffer<RTPTSparseSettings> gSparseSettings;
#if USE_ENV_LIGHT
ParameterBlock<EnvMapSampler> gEnvMapSampler;
#endif
#include "RTPTPGTypes.slang"
#include "RTPTGrid.slang"
#include "RTPTLighting.slang"
#include "RTPTSharc.slang"

void rtptPGStoreVertex(uint path, inout uint count, RTPTPGVertex vertex, inout bool valid)
{
#if ENABLE_PG
    if (count >= gPGSettings.verticesPerPath)
    { valid = false; rtptPGCount(RTPT_PG_DIAG_RECORD_OVERFLOW); return; }
    gPGVertices[path * gPGSettings.verticesPerPath + count] = vertex;
    ++count;
#endif
}

void rtptSparseTrace(Ray ray, inout SampleGenerator sg, uint path, uint ownerPixel, bool record)
{
#if ENABLE_SHARC
    SharcState sharcState;
    SharcInit(sharcState);
#endif
    uint count = 0u;
    bool valid = true;
    float3 pathThroughput = 1.f;
    float3 previousPosition = 0.f;
    float3 previousNormal = 0.f;
    float previousPdf = 0.f;
    bool previousDelta = true;
    bool previousUsedNEE = false;
    SceneRayQuery<true> query;
    for (uint bounce = 0u; bounce <= gSparseSettings.updateBounces; ++bounce)
    {
        float hitT;
        const HitInfo hit = query.traceRay(ray, hitT);
        if (!hit.isValid())
        {
            float3 environment = 0.f;
            float hitMIS = 1.f;
#if USE_ENV_LIGHT
            environment = gScene.envMap.eval(ray.dir);
            if (previousUsedNEE && !previousDelta)
                hitMIS = rtptPowerHeuristic(previousPdf, rtptEnvironmentLightPdf(ray.dir));
#endif
            if (!all(isfinite(environment))) { valid = false; break; }
#if ENABLE_SHARC
            if (gSparseSettings.writeSHARC != 0u) SharcUpdateMiss(gSharc, sharcState, environment * hitMIS);
#endif
            // A terminal pseudo-vertex preserves raw environment and arrival MIS separately.
            if (record)
            {
                RTPTPGVertex terminal = {};
                terminal.emission = environment;
                terminal.hitMIS = hitMIS;
                rtptPGStoreVertex(path, count, terminal, valid);
            }
            break;
        }
        if (hit.getType() != HitType::Triangle) { valid = false; break; }
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
        const TriangleHit triangleHit = hit.getTriangleHit();
        const VertexData vertexData = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = gScene.materials.prepareShadingData(vertexData, materialID, -ray.dir);
        sd.mtl.setActiveLobes(uint(LobeType::Reflection));
        const IMaterialInstance mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));
        const BSDFProperties properties = mi.getProperties(sd);
        float3 emission = 0.f;
        float hitMIS = 1.f;
#if USE_EMISSIVE_LIGHTS
        emission = properties.emission;
        if (sd.frontFacing && gScene.materials.hasLightProfile(materialID))
            emission *= gScene.materials.evalLightProfile(dot(sd.faceN, sd.V));
        if (previousUsedNEE && !previousDelta)
            hitMIS = rtptPowerHeuristic(previousPdf, rtptEmissiveLightPdf(previousPosition, previousNormal, triangleHit, sd));
#endif
        if (!all(isfinite(emission))) { valid = false; break; }
        RTPTPGVertex vertex = {};
        vertex.sampleSurvival = 1.f;
        vertex.emission = emission;
        vertex.hitMIS = hitMIS;
#if ENABLE_PG
        if (record)
            vertex.key = rtptGridKey(sd.posW, sd.getOrientedFaceNormal(), gPGSettings.cameraPosition,
                gPGSettings.sceneScale, gPGSettings.coarseLevels);
#endif
        const uint lobes = mi.getLobeTypes(sd) & sd.mtl.getActiveLobes();
        const bool trainable = (lobes & uint(LobeType::NonDeltaReflection)) != 0u &&
            (lobes & ~uint(LobeType::NonDeltaReflection)) == 0u;
        if (trainable) vertex.flags |= RTPT_PG_VERTEX_TRAINABLE;
        if (bounce == gSparseSettings.updateBounces)
        {
#if ENABLE_SHARC
            if (gSparseSettings.writeSHARC != 0u) SharcUpdateMiss(gSharc, sharcState, emission * hitMIS);
#endif
            if (record) rtptPGStoreVertex(path, count, vertex, valid);
            break;
        }
        const bool useNEE = gParams.useNEE != 0u && (lobes & uint(LobeType::NonDeltaReflection)) != 0u;
        vertex.direct = useNEE ? rtptEstimateDirect(sd, mi, sg) : float3(0.f);
        if (!all(isfinite(vertex.direct))) { valid = false; break; }
#if ENABLE_SHARC
        if (gSparseSettings.writeSHARC != 0u)
        {
            const SharcHitData cacheHit = rtptMakeSharcHit(sd, properties, emission * hitMIS);
            if (!SharcUpdateHit(gSharc, sharcState, cacheHit, vertex.direct, sampleNext1D(sg)))
                SharcUpdateMiss(gSharc, sharcState, vertex.direct + emission * hitMIS);
        }
#endif
        BSDFSample bs = {};
        bool continued = mi.sample(sd, sg, bs);
        const bool delta = bs.isLobe(LobeType::Delta);
        if (continued && (!all(isfinite(bs.wo)) || !all(isfinite(bs.weight)) ||
            (!delta && (!(bs.pdf > 0.f) || !isfinite(bs.pdf))))) { valid = false; break; }
        continued = continued && !bs.isLobe(LobeType::Transmission) && any(bs.weight > 0.f);
        float3 transport = continued ? bs.weight : float3(0.f);
        if (continued)
        {
            pathThroughput *= bs.weight;
            if (!all(isfinite(pathThroughput))) { valid = false; break; }
            if (gParams.useRussianRoulette != 0u && bounce + 1u >= gParams.rrStartBounce)
            {
                const float survival = min(0.95f, max(pathThroughput.x, max(pathThroughput.y, pathThroughput.z)));
                if (!(survival > 0.f) || sampleNext1D(sg) >= survival) continued = false;
                else
                {
                    vertex.sampleSurvival = survival;
                    transport /= survival;
                    pathThroughput /= survival;
                }
            }
        }
        if (continued)
        {
            vertex.flags |= RTPT_PG_VERTEX_OUTGOING;
            vertex.direction = bs.wo;
            vertex.samplePdf = bs.pdf;
            vertex.transport = transport;
        }
        if (record) rtptPGStoreVertex(path, count, vertex, valid);
        if (!continued) break;
#if ENABLE_SHARC
        if (gSparseSettings.writeSHARC != 0u) SharcSetThroughput(sharcState, transport);
#endif
        previousPosition = sd.posW;
        previousNormal = sd.getOrientedFaceNormal();
        previousPdf = bs.pdf;
        previousDelta = delta;
        previousUsedNEE = useNEE;
        ray = Ray(sd.computeRayOrigin(), bs.wo);
#else
        valid = false;
        break;
#endif
    }
#if ENABLE_PG
    if (record)
    {
        RTPTPGPathHeader header = {};
        header.vertexCount = count;
        header.flags = valid ? RTPT_PG_PATH_COMPLETE : RTPT_PG_PATH_INVALID;
        header.ownerPixel = ownerPixel;
        header.generation = gPGSettings.recordGeneration;
        header.sceneGeneration = gPGSettings.sceneGeneration;
        gPGPathHeaders[path] = header;
        if (!valid) rtptPGCount(RTPT_PG_DIAG_INVALID);
    }
#endif
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint stride = max(gSparseSettings.updateStride, 1u);
    const uint2 tileDim = (gSparseSettings.frameDim + stride - 1u) / stride;
    const uint2 tile = dispatchThreadID.xy;
    if (any(tile >= tileDim)) return;
    const uint2 origin = tile * stride;
    const uint2 extent = min(uint2(stride), gSparseSettings.frameDim - origin);
    const uint phase = rtptGridHash32(tile.x * 0x9e3779b9u ^ tile.y * 0x85ebca6bu ^ gParams.seed);
    const uint offset = (phase + gSparseSettings.frameIndex) % max(extent.x * extent.y, 1u);
    const uint2 pixel = origin + uint2(offset % max(extent.x, 1u), offset / max(extent.x, 1u));
    const uint path = tile.y * tileDim.x + tile.x;
#if ENABLE_PG
    const bool record = gSparseSettings.recordPG != 0u && gPGSettings.trainingEnabled != 0u && path < gPGSettings.pathCapacity;
#else
    const bool record = false;
#endif
    const uint sampleIndex = gParams.sampleOffset + gSparseSettings.frameIndex * 0x85ebca6bu + gParams.seed * 0x9e3779b9u;
    SampleGenerator sg = SampleGenerator(pixel, sampleIndex);
    const float2 p = (float2(pixel) + sampleNext2D(sg)) / float2(gSparseSettings.frameDim);
    const float2 ndc = p * float2(2.f, -2.f) + float2(-1.f, 1.f);
    let camera = gScene.camera.data;
    const float3 direction = normalize(ndc.x * camera.cameraU + ndc.y * camera.cameraV + camera.cameraW);
    const float inverseCosine = 1.f / dot(normalize(camera.cameraW), direction);
    const Ray ray = Ray(camera.posW, direction, camera.nearZ * inverseCosine, camera.farZ * inverseCosine);
    rtptSparseTrace(ray, sg, path, pixel.y * gSparseSettings.frameDim.x + pixel.x, record);
}
