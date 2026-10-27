#pragma once
#include "RTPTVXPGTypes.slang"

// Common GPU declarations, in the existing binding order and with unchanged RW types.
// Access by phase:
// - Training reads the grid and writes observations, discovery records, cell
//   activity/representatives and state/error counters; it never publishes trees.
// - Build kernels update grid/history/trees/screen data and publish generations.
// - Rendering reads the published grid/proposal and writes diagnostic counters
//   plus unconditional invalid-data counters, even with diagnostics disabled.
//   It does not update observations, histories or topology.
// Entry-specific scratch resources remain beside their compute entry points.
ConstantBuffer<RTPTVXPGParams> gVXPGParams;
RWStructuredBuffer<uint4> gVXPGBoundMin;
RWStructuredBuffer<uint4> gVXPGBoundMax;
RWStructuredBuffer<uint> gVXPGState;
// Diagnostic-only render writes: forward/reverse query counts and depths.
RWStructuredBuffer<uint> gVXPGQueryStats;
RWStructuredBuffer<uint> gVXPGInverse;
RWStructuredBuffer<uint> gVXPGCompact;
RWStructuredBuffer<uint> gVXPGCount;
RWStructuredBuffer<RTPTVXPGHistory> gVXPGHistory;
RWStructuredBuffer<RTPTVXPGHistory> gVXPGHistoryPrevious;
RWStructuredBuffer<float4> gVXPGNormalPrevious;
// Valid histories, carried histories, expired histories, fresh observations.
RWStructuredBuffer<uint> gVXPGHistoryStats;
RWStructuredBuffer<uint64_t> gVXPGFlux;
RWStructuredBuffer<float> gVXPGMass;
RWStructuredBuffer<float> gVXPGGlobalTree;
RWStructuredBuffer<float> gVXPGCellMass;
// mode(full=1), previous active count, dirty leaves, full/local totals,
// updated global/forest nodes, topology age, previous valid, membership changes,
// full-build reason bits (reset=1, periodic=2, membership=4, invalid=8).
RWStructuredBuffer<uint> gVXPGTreeState;
RWStructuredBuffer<uint> gVXPGDirtyLeaves;
RWStructuredBuffer<uint> gVXPGDirtyNodes;
RWStructuredBuffer<uint> gVXPGLocalArgs;
// free cells, pending entries, retired cells, insertion/eviction/rejection
// totals, live cells. OCCUPIED in gVXPGState remains the cell-ID high-water.
RWStructuredBuffer<uint> gVXPGGridState;
RWStructuredBuffer<uint4> gVXPGCellLifetime;
RWStructuredBuffer<uint> gVXPGFreeCells;
RWStructuredBuffer<uint> gVXPGRetiredCells;
RWStructuredBuffer<RTPTVXPGDiscovery> gVXPGDiscovery;
RWStructuredBuffer<uint> gVXPGPendingHash;
RWStructuredBuffer<uint> gVXPGPendingSlots;
RWStructuredBuffer<float4> gVXPGRepresentativePosition;
RWStructuredBuffer<float4> gVXPGRepresentativeNormal;
RWStructuredBuffer<uint> gVXPGHashSlots;
RWStructuredBuffer<int4> gVXPGCellKeys;
// Header: actual global leaf base, radix padded count, radix groups.
RWStructuredBuffer<uint> gVXPGWorkArgs;
RWTexture2D<float4> gVXPGPrimaryPosition;
RWTexture2D<float4> gVXPGPrimaryNormal;
RWTexture2D<uint4> gVXPGPrimaryHit;

// 128 representative primary points, matching the reference MRCS descriptor.
RWStructuredBuffer<float4> gVXPGRowPosition;
RWStructuredBuffer<float4> gVXPGRowNormal;
RWStructuredBuffer<uint4> gVXPGVisibility;
RWStructuredBuffer<RTPTVXPGClusterSeed> gVXPGSeeds;
RWStructuredBuffer<uint> gVXPGCluster;
// x: sorted leaf range start, y: count, z: heap allocation, w: leaf base.
RWStructuredBuffer<uint4> gVXPGClusterInfo;
RWStructuredBuffer<RTPTVXPGNode> gVXPGForest;
RWStructuredBuffer<uint> gVXPGCompactToLeaf;
RWStructuredBuffer<float4> gVXPGSuperpixelPosition;
RWStructuredBuffer<float4> gVXPGSuperpixelNormal;
RWTexture2D<uint4> gVXPGFuzzyIds;
RWTexture2D<float4> gVXPGFuzzyWeights;
RWStructuredBuffer<float> gVXPGTopTree;
RWStructuredBuffer<uint> gVXPGSuperpixelCount;
RWStructuredBuffer<uint2> gVXPGSuperpixelRange;
RWStructuredBuffer<uint> gVXPGSuperpixelBlocks;
RWStructuredBuffer<uint> gVXPGSuperpixelPoints;
// Separate from renderer counters, also persists while frozen.
// 0: valid superpixels, 1: nonempty clusters, 2: visibility rays,
// 3: visible pairs, 4: forest node allocation, 5: top rows, 6: publication.
RWStructuredBuffer<uint> gVXPGClusterState;
