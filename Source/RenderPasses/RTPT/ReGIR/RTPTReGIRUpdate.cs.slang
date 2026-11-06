/** Prepare current descriptors, then incrementally refresh affected cell lists. */
#include "Scene/SceneDefines.slangh"
#ifndef RTPT_REGIR_ENABLED
#define RTPT_REGIR_ENABLED 1
#endif
#include "../ReSTIRDI/RTPTDISDK.slangh"
#include "RTPTReGIRCellLists.slang"

RTPTReGIRLightDescriptor rtptReGIRDescribeLight(uint stableID)
{
    RTPTReGIRLightDescriptor result = {};
    const uint rank = gReGIRIdToCatalog[stableID];
    if (rank >= gReGIRSettings.lightCount) return result;
    const RTPTDILightInfo light = gReGIRCatalog[rank];
    if (light.kind == kRTPTDILightEmissive)
    {
        if (light.sourceIndex >= gScene.lightCollection.getTriangleCount()) return result;
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(light.sourceIndex);
        result.boundsMin = min(triangle.posW[0], min(triangle.posW[1], triangle.posW[2]));
        result.boundsMax = max(triangle.posW[0], max(triangle.posW[1], triangle.posW[2]));
        result.position = triangle.posW[0] / 3.f + triangle.posW[1] / 3.f + triangle.posW[2] / 3.f;
        result.direction = triangle.normal;
        result.flags = kRTPTReGIRDescriptorActive | kRTPTReGIRDescriptorTriangle;
        if (gScene.materials.getMaterialHeader(triangle.materialID).isDoubleSided())
            result.flags |= kRTPTReGIRDescriptorDoubleSided;
        result.power = asfloat(0x7f800000u);
        // An average radiance cannot bound an emissive texture's bright texel.
        // Likewise an arbitrary angular profile needs its actual maximum.
        if (gScene.materials.isBasicMaterial(triangle.materialID) &&
            !gScene.materials.isEmissiveTextured(triangle.materialID) &&
            !gScene.materials.hasLightProfile(triangle.materialID))
        {
            const float3 radiance = gScene.materials.evalEmissive(triangle.materialID, float2(0.f));
            const float maximumRadiance = rtptReGIRCullingMaxAbs(radiance);
            const float power = triangle.area * maximumRadiance;
            if (isfinite(power) && power >= 0.f)
            {
                // Keep a positive upper proxy when the area/radiance product
                // underflows; a rounded zero is not a proof of zero emission.
                result.power = power == 0.f && triangle.area > 0.f && maximumRadiance > 0.f ? asfloat(0x00800000u) : power;
            }
        }
    }
    else if (light.kind == kRTPTDILightPoint)
    {
        if (light.sourceIndex >= gScene.getLightCount()) return result;
        const LightData data = gScene.getLight(light.sourceIndex);
        if (data.type != uint(LightType::Point)) return result;
        result.boundsMin = result.boundsMax = result.position = data.posW;
        result.direction = data.dirW;
        result.cosOpeningAngle = data.cosOpeningAngle;
        result.flags = kRTPTReGIRDescriptorActive | kRTPTReGIRDescriptorPoint;
        const float power = rtptReGIRCullingMaxAbs(data.intensity);
        result.power = isfinite(power) && power >= 0.f ? power : asfloat(0x7f800000u);
    }
    return result;
}

bool rtptReGIRDescriptorsMatch(RTPTReGIRLightDescriptor a, RTPTReGIRLightDescriptor b)
{
    return all(asuint(a.boundsMin) == asuint(b.boundsMin)) && asuint(a.power) == asuint(b.power) &&
        all(asuint(a.boundsMax) == asuint(b.boundsMax)) && a.flags == b.flags &&
        all(asuint(a.direction) == asuint(b.direction)) && asuint(a.cosOpeningAngle) == asuint(b.cosOpeningAngle) &&
        all(asuint(a.position) == asuint(b.position));
}

[numthreads(256, 1, 1)]
void updateLights(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint stableID = dispatchThreadID.x;
    if (stableID >= gReGIRSettings.stableIdCount) return;
    const RTPTReGIRLightDescriptor descriptor = rtptReGIRDescribeLight(stableID);
    const RTPTReGIRLightDescriptor previous = gReGIRPreviousLightDescriptors[stableID];
    gReGIRLightDescriptors[stableID] = descriptor;
    if (!rtptReGIRDescriptorsMatch(descriptor, previous))
    {
        uint dirtyIndex;
        InterlockedAdd(gReGIRState[6], 1u, dirtyIndex);
        if (dirtyIndex < gReGIRSettings.stableIdCount) gReGIRDirtyLightIDs[dirtyIndex] = stableID;
    }
}

[numthreads(256, 1, 1)]
void updateCells(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    const uint cell = dispatchThreadID.x;
    if (cell >= gReGIRSettings.cellCapacity) return;
    if (rtptReGIRTryEvictCell(cell)) return;
    if (gReGIRCells[cell] == uint64_t(0u) || gReGIRCells[cell] == ~uint64_t(0u)) return;
    float3 center, halfExtent;
    if (!rtptReGIRCellBounds(gReGIRCells[cell], center, halfExtent)) return;
    RTPTReGIRCellView stored = rtptReGIRGetStoredCellView(cell);
    bool rebuild = stored.ready == 0u;
    const uint dirtyCount = min(gReGIRState[6], gReGIRSettings.stableIdCount);
    for (uint index = 0u; index < dirtyCount && !rebuild; ++index)
    {
        const uint stableID = gReGIRDirtyLightIDs[index];
        if (stableID >= gReGIRSettings.stableIdCount) continue;
        // An unchanged ID remains in the list even if its intensity or
        // position changes. Only an actual membership change rewrites IDs;
        // RIS weights are rebuilt separately when light data change.
        rebuild = rtptReGIRMembershipChanged(gReGIRPreviousLightDescriptors[stableID],
            gReGIRLightDescriptors[stableID], center, halfExtent);
    }
    if (rebuild)
    {
        // Exactly one update thread owns a cell before consumer dispatches.
        gReGIRCellMeta[cell].w = kRTPTReGIRListBuilding;
        stored = rtptReGIRBuildCellList(cell, center, halfExtent);
        InterlockedAdd(gReGIRState[7], 1u);
    }
    else InterlockedAdd(gReGIRState[3], 1u);

    if (stored.count == 0u) return;
    const bool buildRIS = gReGIRSettings.invalidateRIS != 0u ||
        gReGIRCellRISState[cell] == kRTPTReGIRRISUnbuilt;
    gReGIRCellRISState[cell] = buildRIS ? kRTPTReGIRRISBuild : kRTPTReGIRRISReused;
    InterlockedAdd(gReGIRState[buildRIS ? 10u : 11u], 1u);
}
