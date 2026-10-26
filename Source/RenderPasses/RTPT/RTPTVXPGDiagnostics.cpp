#include "RTPTVXPG.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <numeric>
#include <vector>

using namespace Falcor;
namespace RTPTVXPG
{
namespace
{
using Json = Properties::json;
constexpr uint32_t kInvalid = 0xffffffffu;
struct SnapshotNode { float3 lo; float mass; float3 hi; uint32_t compact; };
static_assert(sizeof(SnapshotNode) == 32);

Json vectorJson(float3 v) { return Json::array({v.x,v.y,v.z}); }
Json vectorJson(uint4 v) { return Json::array({v.x,v.y,v.z,v.w}); }
Json vectorJson(int4 v) { return Json::array({v.x,v.y,v.z,v.w}); }
float3 xyz(float4 v) { return float3(v.x,v.y,v.z); }
bool finite3(float3 v) { return std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z); }
float fromBits(uint32_t bits) { float value; std::memcpy(&value,&bits,sizeof(value)); return value; }

template<typename T> std::vector<T> snapshotRead(const ref<Buffer>& buffer,uint32_t count)
{
    FALCOR_CHECK(buffer && uint64_t(count)*sizeof(T)<=buffer->getSize(),"VXPG snapshot buffer range is invalid.");
    std::vector<T> result(count);
    if(count)buffer->getBlob(result.data(),0,uint64_t(count)*sizeof(T));
    return result;
}

Json histogramJson(const std::map<uint32_t,uint32_t>& values)
{
    Json result=Json::array();
    for(const auto& [value,count]:values)result.push_back(Json::array({value,count}));
    return result;
}

Json depthStatistics(const std::vector<uint32_t>& depths)
{
    std::map<uint32_t,uint32_t> histogram;
    for(uint32_t value:depths)++histogram[value];
    Json result;
    result["depthHistogram"]=histogramJson(histogram);
    result["meanDepth"]=depths.empty()?0.:double(std::accumulate(depths.begin(),depths.end(),uint64_t(0)))/depths.size();
    std::vector<uint32_t> sorted=depths;
    std::sort(sorted.begin(),sorted.end());
    result["p95Depth"]=sorted.empty()?0u:sorted[(95ull*sorted.size()+99ull)/100ull-1ull];
    result["maxDepth"]=sorted.empty()?0u:sorted.back();
    return result;
}
}

Properties Manager::readTreeSnapshot(const Settings& requested) const
{
    auto unavailable=[](const char* status)
    {
        Json result={{"version",2},{"available",false},{"status",status}};
        return Properties(std::move(result));
    };
    // This explicit API is opt-in under the existing Diagnostics switch. In
    // particular, a disabled request does not perform even a counter readback.
    if(!requested.detailedDiagnostics || !mSettings.detailedDiagnostics)return unavailable("diagnostics_disabled");
    if(!requested.enabled || !requested.visibilityEnabled || !mSettings.enabled || !mSettings.visibilityEnabled)
        return unavailable("clustered_vxpg_disabled");
    if(!mReady || !mDistributionValid || !mpScene || !mpState || !mpClusterState || !mpSortA ||
        !mpCompactIndices || !mpMass || !mpCluster || !mpClusterInfo || !mpForest || !mpCompactToLeaf ||
        !mpCellKeys || !mpBoundMin || !mpBoundMax || !mpSuperpixelPosition || !mpSuperpixelNormal || !mpTopTree)
        return unavailable("model_unavailable");
    const auto state=snapshotRead<uint32_t>(mpState,32);
    const auto clusterState=snapshotRead<uint32_t>(mpClusterState,8);
    if(state[5]!=mGeneration || clusterState[6]!=mGeneration)return unavailable("model_not_published");
    if(state[1] || state[4] || state[11])return unavailable("model_invalid");
    const uint32_t count=state[3],geometryCount=std::min(state[2],cellCapacity()),nodeCount=clusterState[4];
    if(count>mSettings.maxVoxels || count>geometryCount || nodeCount>4ull*mSettings.maxVoxels+64ull)
        return unavailable("model_range_invalid");
    const auto sorted=snapshotRead<uint2>(mpSortA,count);
    const auto compact=snapshotRead<uint32_t>(mpCompactIndices,count);
    const auto mass=snapshotRead<float>(mpMass,count);
    const auto clusters=snapshotRead<uint32_t>(mpCluster,count);
    const auto infos=snapshotRead<uint4>(mpClusterInfo,32);
    const auto nodes=snapshotRead<SnapshotNode>(mpForest,nodeCount);
    const auto leafMap=snapshotRead<uint32_t>(mpCompactToLeaf,count);
    const auto keys=snapshotRead<int4>(mpCellKeys,geometryCount);
    const auto loBits=snapshotRead<uint4>(mpBoundMin,geometryCount);
    const auto hiBits=snapshotRead<uint4>(mpBoundMax,geometryCount);
    std::vector<uint32_t> morton(count),sortedRank(count),depths(count),seen(count,0);
    Json sortedCompact=Json::array(),sortedKeys=Json::array();
    uint64_t previous=0;
    for(uint32_t rank=0;rank<count;++rank)
    {
        const uint2 code=sorted[rank];
        const uint32_t c=code.x>>21;
        const uint32_t index=code.y;
        const uint32_t position=code.x&0x1fffffu;
        if(index>=count || c>=mSettings.clusterCount || seen[index]++ || clusters[index]!=c || position>0x1fffffu)
            return unavailable("sort_mapping_invalid");
        // Stable Radix preserves active-list order for equal combined keys.
        const uint64_t compare=(uint64_t(code.x)<<32)|index;
        if(rank && compare<previous)return unavailable("sort_order_invalid");
        previous=compare;
        const uint4 info=infos[c];
        if(rank<info.x || rank-info.x>=info.y)return unavailable("cluster_range_invalid");
        morton[index]=position;sortedRank[index]=rank;
        sortedCompact.push_back(index);sortedKeys.push_back(Json::array({code.x,code.y}));
    }
    Json leaves=Json::array();
    std::vector<std::vector<uint32_t>> clusterDepths(32);
    for(uint32_t index=0;index<count;++index)
    {
        const uint32_t cell=compact[index],c=clusters[index];
        if(cell>=geometryCount || c>=mSettings.clusterCount || loBits[cell].w==0 ||
            keys[cell].w<=0 || keys[cell].w>511 || !(mass[index]>0.f) || !std::isfinite(mass[index]))
            return unavailable("leaf_data_invalid");
        const uint4 info=infos[c];
        const uint32_t leaf=leafMap[index];
        if(info.y==0 || leaf<info.w || leaf-info.w>=info.y ||
            uint64_t(info.z)+leaf>=nodes.size() || nodes[info.z+leaf].compact!=index ||
            sortedRank[index]!=info.x+leaf-info.w || nodes[info.z+leaf].mass!=mass[index])
            return unavailable("leaf_mapping_invalid");
        uint32_t node=leaf,depth=0;
        while(node>1){node/=2;++depth;}
        if(node!=1 || depth>64)return unavailable("heap_depth_invalid");
        depths[index]=depth;clusterDepths[c].push_back(depth);
        const float size=std::exp2(float(keys[cell].w))/mSettings.lodSceneScale;
        const float3 localLo(fromBits(loBits[cell].x),fromBits(loBits[cell].y),fromBits(loBits[cell].z));
        const float3 localHi(fromBits(hiBits[cell].x),fromBits(hiBits[cell].y),fromBits(hiBits[cell].z));
        const float3 key(float(keys[cell].x),float(keys[cell].y),float(keys[cell].z));
        const float3 worldLo=mGridMin+(key+localLo)*size,worldHi=mGridMin+(key+localHi)*size;
        if(!finite3(worldLo)||!finite3(worldHi)||worldHi.x<=worldLo.x||worldHi.y<=worldLo.y||worldHi.z<=worldLo.z)
            return unavailable("leaf_bounds_invalid");
        leaves.push_back({{"compact",index},{"cell",cell},{"cluster",c},{"morton",morton[index]},
            {"mass",mass[index]},{"worldMin",vectorJson(worldLo)},{"worldMax",vectorJson(worldHi)},
            {"cellKey",vectorJson(keys[cell])},{"boundMinBits",vectorJson(loBits[cell])},{"boundMaxBits",vectorJson(hiBits[cell])},
            {"sortedRank",sortedRank[index]},{"depth",depth}});
    }
    Json clusterResults=Json::array();
    std::map<uint32_t,uint32_t> totalDuplicateRuns;
    uint32_t totalUnique=0,totalDuplicateGroups=0,totalDuplicateLeaves=0,totalDuplicateExcess=0,maxDuplicateRun=0;
    uint32_t totalClusterLeaves=0;
    for(uint32_t c=0;c<mSettings.clusterCount;++c)
    {
        const uint4 info=infos[c];
        if(uint64_t(info.x)+info.y>count || info.y!=clusterDepths[c].size())return unavailable("cluster_count_invalid");
        totalClusterLeaves+=info.y;
        std::map<uint32_t,uint32_t> duplicates;
        uint32_t unique=0,duplicateGroups=0,duplicateLeaves=0,duplicateExcess=0,maxRun=0;
        for(uint32_t first=info.x;first<info.x+info.y;)
        {
            const uint32_t index=sortedCompact[first].get<uint32_t>();
            const uint32_t position=morton[index];
            uint32_t end=first+1;
            while(end<info.x+info.y && morton[sortedCompact[end].get<uint32_t>()]==position)++end;
            ++unique;
            const uint32_t run=end-first;
            if(run>1){++duplicates[run];++totalDuplicateRuns[run];++duplicateGroups;duplicateLeaves+=run;duplicateExcess+=run-1;maxRun=std::max(maxRun,run);}
            first=end;
        }
        Json record=depthStatistics(clusterDepths[c]);
        record["cluster"]=c;record["count"]=info.y;record["uniqueMorton"]=unique;
        record["duplicateGroups"]=duplicateGroups;record["duplicateLeaves"]=duplicateLeaves;
        record["duplicateExcess"]=duplicateExcess;record["maxDuplicateRun"]=maxRun;
        record["duplicateRunHistogram"]=histogramJson(duplicates);
        clusterResults.push_back(std::move(record));
        totalUnique+=unique;totalDuplicateGroups+=duplicateGroups;totalDuplicateLeaves+=duplicateLeaves;
        totalDuplicateExcess+=duplicateExcess;maxDuplicateRun=std::max(maxDuplicateRun,maxRun);
    }
    if(totalClusterLeaves!=count)return unavailable("cluster_total_invalid");
    Json totals=depthStatistics(depths);
    totals["count"]=count;totals["uniqueMorton"]=totalUnique;
    totals["duplicateGroups"]=totalDuplicateGroups;totals["duplicateLeaves"]=totalDuplicateLeaves;
    totals["duplicateExcess"]=totalDuplicateExcess;totals["maxDuplicateRun"]=maxDuplicateRun;
    totals["duplicateLeafFraction"]=count?double(totalDuplicateLeaves)/count:0.;
    totals["duplicateExcessFraction"]=count?double(totalDuplicateExcess)/count:0.;
    totals["duplicateRunHistogram"]=histogramJson(totalDuplicateRuns);
    Json nodeJson=Json::array(),infoJson=Json::array();
    for(const auto& node:nodes)nodeJson.push_back({{"lo",vectorJson(node.lo)},{"mass",node.mass},{"hi",vectorJson(node.hi)},{"compact",node.compact}});
    for(uint4 info:infos)infoJson.push_back(vectorJson(info));

    const uint2 superpixelDim=(mFrameDim+mSettings.superpixelSize-1u)/mSettings.superpixelSize;
    const uint32_t rows=superpixelDim.x*superpixelDim.y;
    const auto positions=snapshotRead<float4>(mpSuperpixelPosition,rows);
    const auto normals=snapshotRead<float4>(mpSuperpixelNormal,rows);
    const auto top=snapshotRead<float>(mpTopTree,rows*64);
    std::vector<uint32_t> validRows;
    for(uint32_t row=0;row<rows;++row)
        if(positions[row].w!=0.f && finite3(xyz(positions[row])) && finite3(xyz(normals[row])) &&
            top[row*64+1]>0.f && std::isfinite(top[row*64+1]))validRows.push_back(row);
    Json contexts=Json::array();
    const uint32_t contextCount=uint32_t(std::min<size_t>(64,validRows.size()));
    for(uint32_t i=0;i<contextCount;++i)
    {
        const uint32_t row=validRows[(uint64_t(2*i+1)*validRows.size())/(2*contextCount)];
        const float3 origin=xyz(positions[row]);
        const float3 delta=mLodCamera-(origin+float3(1.e-4f));
        const float distance2=delta.x*delta.x+delta.y*delta.y+delta.z*delta.z;
        const uint32_t level=uint32_t(std::clamp(.5f*std::log2(std::max(distance2,1.e-10f)),1.f,511.f));
        const float sourceSize=std::exp2(float(level))/mSettings.lodSceneScale;
        if(!(sourceSize>0.f)||!std::isfinite(sourceSize))return unavailable("context_size_invalid");
        Json weights=Json::array();
        for(uint32_t c=0;c<32;++c)
        {
            const float weight=top[row*64+32+c];
            if(!std::isfinite(weight)||weight<0.f)return unavailable("context_weight_invalid");
            weights.push_back(weight);
        }
        contexts.push_back({{"row",row},{"origin",vectorJson(origin)},{"normal",vectorJson(xyz(normals[row]))},
            {"sourceSize",sourceSize},{"topWeights",std::move(weights)}});
    }
    Json result={{"version",2},{"available",true},{"status","published_snapshot"},
        {"treeType","Heap"},{"sortBackend","Radix"},{"generation",mGeneration},{"geometryGeneration",mGeometryGeneration},
        {"activeCount",count},{"activeCapacity",mSettings.maxVoxels},{"geometryCapacity",cellCapacity()},
        {"clusterCount",mSettings.clusterCount},
        {"gridMin",vectorJson(mGridMin)},{"lodCamera",vectorJson(mLodCamera)},{"lodSceneScale",mSettings.lodSceneScale},
        {"sortMin",vectorJson(mpScene->getSceneBounds().minPoint)},{"sortExtent",vectorJson(mpScene->getSceneBounds().extent())},
        {"leaves",std::move(leaves)},{"sortedCompact",std::move(sortedCompact)},{"sortedKeys",std::move(sortedKeys)},
        {"tree",{{"nodes",std::move(nodeJson)},{"clusterInfo",std::move(infoJson)}}},
        {"clusters",std::move(clusterResults)},{"totals",std::move(totals)},{"contexts",std::move(contexts)},
        {"validContextRows",validRows.size()},
        {"definitions",{{"mortonGrouping","Within each Cluster; equal Morton in different Clusters is not a collision for this tree."},
            {"duplicateLeaves","All leaves in Morton runs of length >= 2."},{"duplicateExcess","Sum(runLength-1) over duplicate runs."},
            {"depth","Root-to-real-leaf edges; uniform over leaves, not weighted by queries."},
            {"nodeGeometry","Published center in lo and radius in hi.x; not raw AABBs."},
            {"bounds","CPU-expanded production formula; raw cellKey and local bound bits retained for exact GPU replay."},
            {"contexts","At most 64 evenly spaced valid SPixel rows; sourceSize follows production distance-LOD formula."}}}};
    return Properties(std::move(result));
}
}
