#include "../RTPTLocalLightSampling.slang"
#include "RTPTLocalLightDebugLayout.slangh"

cbuffer gLocalDebugParams
{
    uint2 selectedPixel;
    float opacity;
};
RWTexture2D<float4> gLocalDebugOutput;
RWStructuredBuffer<uint4> gLocalInspection;

float3 localDebugHeat(float value)
{
    value = saturate(value);
    return saturate(float3(1.5f - abs(4.f * value - 3.f), 1.5f - abs(4.f * value - 2.f), 1.5f - abs(4.f * value - 1.f)));
}

float3 localDebugKeyColor(uint value)
{
    const uint hash = rtptLocalHash(value);
    return 0.15f + 0.85f * float3(hash & 255u, (hash >> 8u) & 255u, (hash >> 16u) & 255u) / 255.f;
}

RTPTLocalLightFeedbackRecord localDebugHistory(uint2 pixel)
{
    const uint2 sample = min(pixel / max(gLocalLightParams.feedbackStride, 1u), gLocalLightParams.feedbackDim - 1u);
    return gLocalReprojectedHistory[sample.x + sample.y * gLocalLightParams.feedbackDim.x];
}

float4 localDebugGridValues(uint slot, uint kind, uint entry)
{
    const uint base = rtptLocalGridBase(slot, kind);
    float cdfLo = -1.f, cdfHi = -1.f;
    const uint mass=rtptFullCdfMass(gLocalFullCdf,base,entry,gLocalLightParams.cdfEnabled!=0u);
    if(gLocalLightParams.cdfEnabled!=0u)
    {
        cdfHi=float(gLocalFullCdf[base+entry])/float(RTPT_FULL_CDF_BINS);
        cdfLo=cdfHi-float(mass)/float(RTPT_FULL_CDF_BINS);
    }
    return float4(float(mass),cdfLo,cdfHi,float(mass)/float(RTPT_FULL_CDF_BINS));
}

[numthreads(8, 8, 1)]
void draw(uint3 tid : SV_DispatchThreadID)
{
    const uint2 pixel = tid.xy;
    if (any(pixel >= gLocalLightParams.frameDim)) return;
    const float4 position = gLocalPrimaryPosition[pixel];
    const uint mode = gLocalLightParams.debugMode;
    const bool primaryValid = gLocalLightParams.primaryValid != 0u && position.w != 0.f;
    const uint4 event = gLocalDebugEvents[pixel];
    const bool eventValid = (event.w & 1u) != 0;
    float3 color = primaryValid ? float3(.20f) : float3(.055f);

    if (primaryValid && (mode == 0u || mode == 6u || mode == 8u || mode == 9u) && gLocalLightParams.gridEnabled != 0u)
    {
        const uint slot = rtptLocalFindCell(position.xyz);
        if (slot != RTPT_LOCAL_LIGHT_INVALID)
        {
            const uint4 counts = gLocalGridCount[slot];
            const bool overflow = counts.x == RTPT_LOCAL_LIGHT_INVALID || counts.y == RTPT_LOCAL_LIGHT_INVALID;
            if (overflow) color = float3(1.f, 0.f, 1.f);
            else if (mode == 0u)
                color = localDebugHeat(log2(float(counts.x + counts.y) + 1.f) / log2(float(max(1u,gLocalLightParams.fullEmissiveCapacity+gLocalLightParams.fullAnalyticCapacity))+1.f));
            else if (mode == 8u)
            {
                const uint4 state = gLocalGridState[slot];
                color = state.y != gLocalLightParams.gridGeneration ? float3(.20f) :
                    state.w == gLocalLightParams.frameSerial ? float3(1.f, .5f, .05f) : float3(.1f, .85f, .25f);
            }
            else if (mode == 9u)
            {
                const uint4 state = gLocalGridState[slot];
                color = state.y != gLocalLightParams.gridGeneration ? float3(.20f) :
                    localDebugHeat(float(gLocalLightParams.frameSerial - state.w) / 256.f);
            }
            else color = localDebugKeyColor(slot);
            float3 distance = frac((position.xyz-gLocalLightParams.fullOrigin) / gLocalLightParams.fullCellExtent);
            distance = min(distance, 1.f - distance);
            // Suppress the normal axis so a surface lying on a cell plane is
            // not painted entirely white.
            const float3 normal = abs(gLocalPrimaryNormalRoughness[pixel].xyz);
            if (normal.x > .8f) distance.x = 1.f;
            if (normal.y > .8f) distance.y = 1.f;
            if (normal.z > .8f) distance.z = 1.f;
            if (min(distance.x, min(distance.y, distance.z)) < .015f) color = 1.f;
        }
    }
    else if (primaryValid && mode == 1u && gLocalLightParams.tileEnabled != 0u)
    {
        const uint node = gLocalPixelToTile[pixel];
        if (node != RTPT_LOCAL_LIGHT_INVALID && node < gLocalLightParams.tileNodeCount)
        {
            uint2 origin; uint size;
            rtptLocalTileBounds(node, origin, size);
            color = size == 8u ? float3(1.f, .45f, .08f) : size == 16u ? float3(.1f, .8f, .65f) : float3(.15f, .35f, 1.f);
            const uint2 local = pixel - origin;
            if (any(local == 0u) || any(local == size - 1u)) color = 1.f;
        }
    }
    else if (mode == 2u && eventValid)
        color = localDebugKeyColor(event.y ^ rtptLocalHash(event.x));
    else if (mode == 3u && eventValid)
        color = event.z == RTPT_LIGHT_SOURCE_TILE ? float3(1.f, .5f, .05f) :
                event.z == RTPT_LIGHT_SOURCE_GRID ? float3(.1f, .9f, .25f) : float3(.15f, .4f, 1.f);
    else if (mode == 5u && eventValid)
        color = (event.w & 8u) == 0u ? float3(.9f, .75f, .1f) :
                (event.w & 2u) != 0u ? float3(.1f, .85f, .2f) : float3(.9f, .08f, .05f);
    else if (primaryValid && (mode == 4u || mode == 7u) && gLocalLightParams.tileEnabled != 0u)
    {
        const RTPTLocalLightFeedbackRecord history = localDebugHistory(pixel);
        const bool valid = gLocalLightParams.historyValid != 0u && rtptLocalFeedbackValid(history);
        if (mode == 4u) color = valid ? float3(.1f, .8f, .2f) : float3(.6f, .12f, .1f);
        else if (valid)
            color = localDebugHeat(float(gLocalLightParams.frameSerial - history.key.w) / max(float(gLocalLightParams.historyStaleFrames), 1.f));
    }
    const int2 offset = int2(pixel) - int2(selectedPixel);
    const bool cross = (offset.x == 0 && abs(offset.y) <= 4) || (offset.y == 0 && abs(offset.x) <= 4);
    gLocalDebugOutput[pixel] = float4(cross ? float3(1.f) : color, cross ? 1.f : opacity);
}

[numthreads(1, 1, 1)]
void inspect(uint3 tid : SV_DispatchThreadID)
{
    for (uint i = 0u; i < RTPT_LOCAL_INSPECT_LANES; ++i) gLocalInspection[i] = 0u;
    const uint2 pixel = min(selectedPixel, gLocalLightParams.frameDim - 1u);
    const float4 position = gLocalPrimaryPosition[pixel];
    const float4 normal = gLocalPrimaryNormalRoughness[pixel];
    const bool primaryValid = gLocalLightParams.primaryValid != 0u && position.w != 0.f;
    const uint flags = gLocalLightParams.gridEnabled | (gLocalLightParams.tileEnabled << 1u) |
        (gLocalLightParams.adaptiveEnabled << 2u) | (gLocalLightParams.historyValid << 3u) | (gLocalLightParams.useNEE << 4u);
    gLocalInspection[RTPT_LOCAL_INSPECT_METADATA] = uint4(gLocalLightParams.frameSerial, gLocalLightParams.sceneGeneration,
                                                       gLocalLightParams.proposalGeneration, flags);
    gLocalInspection[RTPT_LOCAL_INSPECT_PIXEL] = uint4(pixel, gLocalLightParams.debugMode, primaryValid ? 1u : 0u);
    gLocalInspection[RTPT_LOCAL_INSPECT_PRIMARY_POSITION] = asuint(position);
    gLocalInspection[RTPT_LOCAL_INSPECT_PRIMARY_NORMAL] = asuint(normal);
    gLocalInspection[RTPT_LOCAL_INSPECT_GRID_CONFIG] = uint4(gLocalLightParams.gridGeneration, gLocalLightParams.cdfEnabled,
        gLocalLightParams.persistentEnabled, 0u);
    if (gLocalLightParams.gridEnabled != 0u)
    {
        gLocalInspection[RTPT_LOCAL_INSPECT_GRID_STATS_A] = uint4(gLocalGridStats[0], gLocalGridStats[1], gLocalGridStats[2], gLocalGridStats[3]);
        gLocalInspection[RTPT_LOCAL_INSPECT_GRID_STATS_B] = uint4(gLocalGridStats[4], gLocalGridStats[5], gLocalGridStats[6], gLocalGridStats[7]);
    }
    for(uint query=0u;query<4u;++query)
        gLocalInspection[RTPT_LOCAL_INSPECT_BRANCH_COUNTS+query]=uint4(
            gLocalGridStats[8u+query*3u],gLocalGridStats[9u+query*3u],gLocalGridStats[10u+query*3u],0u);
    gLocalInspection[RTPT_LOCAL_INSPECT_FULL_AUDIT]=uint4(gLocalGridStats[20],gLocalGridStats[21],gLocalGridStats[22],gLocalGridStats[23]);
    uint cell = RTPT_LOCAL_LIGHT_INVALID;
    if (primaryValid) cell = rtptLocalFindCell(position.xyz);
    gLocalInspection[RTPT_LOCAL_INSPECT_GRID_CELL] = uint4(asuint(rtptLocalCellKey(position.xyz)), cell);
    if (cell != RTPT_LOCAL_LIGHT_INVALID)
    {
        if(gLocalGridState[cell].w!=gLocalLightParams.frameSerial)
            gLocalInspection[RTPT_LOCAL_INSPECT_GRID_STATS_A].y=gLocalLightParams.gridCellCount;
        gLocalInspection[RTPT_LOCAL_INSPECT_GRID_COUNTS] = gLocalGridCount[cell];
        gLocalInspection[RTPT_LOCAL_INSPECT_GRID_STATE] = gLocalGridState[cell];
        const uint meshCount = rtptLocalGridSize(cell, RTPT_LIGHT_KIND_EMISSIVE);
        const uint analyticCount = rtptLocalGridSize(cell, RTPT_LIGHT_KIND_ANALYTIC);
        gLocalInspection[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_COUNTS] = uint4(meshCount, analyticCount,
            min(meshCount, RTPT_LOCAL_INSPECT_MAX_CANDIDATES), min(analyticCount, RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
        for (uint category = 0u; category < 2u; ++category)
        {
            const uint kind = category == 0u ? RTPT_LIGHT_KIND_EMISSIVE : RTPT_LIGHT_KIND_ANALYTIC;
            const uint count = min(category == 0u ? meshCount : analyticCount, RTPT_LOCAL_INSPECT_MAX_CANDIDATES);
            const uint base = rtptLocalGridBase(cell, kind);
            for (uint i = 0u; i < count; ++i)
            {
                const uint id = rtptLocalGridLightIndex(cell,kind,i);
                const uint lane = category * RTPT_LOCAL_INSPECT_MAX_CANDIDATES + i;
                gLocalInspection[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_KEYS + lane] = uint4(kind, id, i, gLocalGridState[cell].z);
                gLocalInspection[RTPT_LOCAL_INSPECT_GRID_CANDIDATE_VALUES + lane] = asuint(localDebugGridValues(cell, kind, i));
            }
        }
    }
    uint node = RTPT_LOCAL_LIGHT_INVALID;
    gLocalInspection[RTPT_LOCAL_INSPECT_TILE] = uint4(node, 0u, 0u, 0u);
    if (gLocalLightParams.tileEnabled != 0u && primaryValid)
    {
        node = gLocalPixelToTile[pixel];
        if (node != RTPT_LOCAL_LIGHT_INVALID && node < gLocalLightParams.tileNodeCount)
        {
            uint2 origin; uint size;
            rtptLocalTileBounds(node, origin, size);
            gLocalInspection[RTPT_LOCAL_INSPECT_TILE] = uint4(node, origin, size);
            gLocalInspection[RTPT_LOCAL_INSPECT_TILE_STATE] = gLocalTileState[node];
        }
        else node = RTPT_LOCAL_LIGHT_INVALID;
        const RTPTLocalLightFeedbackRecord history = localDebugHistory(pixel);
        const bool valid = gLocalLightParams.historyValid != 0u && rtptLocalFeedbackValid(history);
        const uint age = history.pixelInfo.z != 0u ? gLocalLightParams.frameSerial - history.key.w : RTPT_LOCAL_LIGHT_INVALID;
        const uint2 sample = pixel / max(gLocalLightParams.feedbackStride, 1u);
        const uint slot = sample.x + sample.y * gLocalLightParams.feedbackDim.x;
        gLocalInspection[RTPT_LOCAL_INSPECT_HISTORY_KEY] = history.key;
        gLocalInspection[RTPT_LOCAL_INSPECT_HISTORY_INFO] = uint4(valid ? 1u : 0u, age, history.pixelInfo.w, slot);
        gLocalInspection[RTPT_LOCAL_INSPECT_HISTORY_POSITION] = asuint(history.positionScore);
        gLocalInspection[RTPT_LOCAL_INSPECT_HISTORY_NORMAL] = asuint(history.normalWeight);
    }
    RTPTLocalLightDebugEvent event = gLocalDebugSelected[0];
    if (any(event.context.xy != pixel) || event.generation.x != gLocalLightParams.frameSerial ||
        event.generation.y != gLocalLightParams.sceneGeneration || event.generation.z != gLocalLightParams.proposalGeneration)
        event = {};
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_POSITION] = asuint(event.positionPmf);
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_NORMAL] = asuint(event.normalPdf);
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_TARGET] = asuint(event.targetReference);
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_DIRECTION] = asuint(event.directionRaw);
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_IDENTITY] = event.identity;
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_CONTEXT] = event.context;
    gLocalInspection[RTPT_LOCAL_INSPECT_EVENT_GENERATION] = event.generation;
    gLocalInspection[RTPT_LOCAL_INSPECT_GRID_SELECTED_VALUES] = asuint(float4(0.f, -1.f, -1.f, 0.f));
    if (cell != RTPT_LOCAL_LIGHT_INVALID &&
        (event.identity.x == RTPT_LIGHT_KIND_EMISSIVE || event.identity.x == RTPT_LIGHT_KIND_ANALYTIC))
    {
        const uint entry = rtptLocalFindGridEntry(cell, event.identity.x, event.identity.y);
        if (entry != RTPT_LOCAL_LIGHT_INVALID)
        {
            gLocalInspection[RTPT_LOCAL_INSPECT_GRID_SELECTED_VALUES] = asuint(localDebugGridValues(cell, event.identity.x, entry));
        }
    }

    // Show the current tile's unique candidates and evaluate the same complete
    // proposal PMF used by NEE. No random stream is consumed by this view.
    if (node != RTPT_LOCAL_LIGHT_INVALID)
    {
        const uint count = min(gLocalTileState[node].w, min(gLocalLightParams.tileCandidates, RTPT_LOCAL_INSPECT_MAX_CANDIDATES));
        gLocalInspection[RTPT_LOCAL_INSPECT_CANDIDATE_COUNT] = uint4(count, 0u, 0u, 0u);
        RTPTLightingContext context = rtptMakeLightContext(position.xyz, normal.xyz, pixel,
            gLocalLightParams.sampleOffset + gLocalLightParams.seed * 0x9e3779b9u, 0u, RTPT_LIGHT_QUERY_MAIN_PRIMARY);
        context.snapshotGeneration = gLocalLightParams.proposalGeneration;
        for (uint i = 0u; i < count; ++i)
        {
            const uint offset = node * gLocalLightParams.tileCandidates + i;
            const uint2 light = gLocalTileLights[offset];
            RTPTLightKey key = {};
            key.kind = light.x; key.index = light.y; key.sceneGeneration = gLocalLightParams.sceneGeneration;
            const float pmf = rtptLocalEvalSelectionPmf(context, key);
            gLocalInspection[RTPT_LOCAL_INSPECT_CANDIDATE_KEYS + i] = uint4(light, key.sceneGeneration, 0u);
            gLocalInspection[RTPT_LOCAL_INSPECT_CANDIDATE_VALUES + i] = asuint(float4(gLocalTileWeights[offset], pmf, 0.f, 0.f));
        }
    }
}
