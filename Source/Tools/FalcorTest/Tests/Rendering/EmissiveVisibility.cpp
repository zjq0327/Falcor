#include "Testing/UnitTest.h"
#include "Scene/SceneBuilder.h"
#include "Scene/TriangleMesh.h"
#include "Scene/Material/StandardMaterial.h"
#include "Utils/Sampling/SampleGenerator.h"
#include <array>

namespace Falcor
{
namespace
{
const char kShaderFile[] = "Tests/Rendering/EmissiveVisibility.cs.slang";

struct VisibilityProbe
{
    float4 position;
    float4 normal;
    float4 lightPosition;
    float4 lightNormal;
};
static_assert(sizeof(VisibilityProbe) == 64);

void addFace(
    SceneBuilder& builder,
    const char* name,
    float3 origin,
    float3 u,
    float3 v,
    float3 normal,
    const ref<Material>& material
)
{
    auto mesh = TriangleMesh::create();
    mesh->addVertex(origin, normal, float2(0.f, 0.f));
    mesh->addVertex(origin + u, normal, float2(1.f, 0.f));
    mesh->addVertex(origin + v, normal, float2(0.f, 1.f));
    mesh->addVertex(origin + u + v, normal, float2(1.f, 1.f));
    mesh->addTriangle(0, 1, 2);
    mesh->addTriangle(1, 3, 2);
    SceneBuilder::Node node{};
    node.name = name;
    node.transform = float4x4::identity();
    node.meshBind = float4x4::identity();
    node.localToBindPose = float4x4::identity();
    builder.addMeshInstance(builder.addNode(node), builder.addTriangleMesh(mesh, material));
}

ref<Scene> createVisibilityScene(const ref<Device>& device)
{
    SceneBuilder builder(device, Settings(), SceneBuilder::Flags::DontMergeMaterials);
    auto receiver = StandardMaterial::create(device, "Receiver");
    auto box = StandardMaterial::create(device, "Box");
    auto back = StandardMaterial::create(device, "Back");
    auto emitter = StandardMaterial::create(device, "Emitter");
    emitter->setBaseColor(float4(0.f, 0.f, 0.f, 1.f));
    emitter->setEmissiveColor(float3(1.f));
    emitter->setEmissiveFactor(16.f);

    // These binary-exact surfaces reproduce the M6 shared scene, without an
    // external Python scene, environment variables, or imported assets.
    addFace(builder, "Floor", {-1.f, 0.f, 1.f}, {2.f, 0.f, 0.f}, {0.f, 0.f, -2.f}, {0.f, 1.f, 0.f}, receiver);
    addFace(builder, "Back", {-1.f, 0.f, -1.f}, {2.f, 0.f, 0.f}, {0.f, 2.f, 0.f}, {0.f, 0.f, 1.f}, back);
    addFace(builder, "Right", {1.f, 0.f, -1.f}, {0.f, 0.f, 2.f}, {0.f, 2.f, 0.f}, {-1.f, 0.f, 0.f}, receiver);
    addFace(builder, "BoxFront", {-0.625f, 0.f, 0.25f}, {0.5f, 0.f, 0.f}, {0.f, 0.75f, 0.f}, {0.f, 0.f, 1.f}, box);
    addFace(builder, "BoxBack", {-0.125f, 0.f, -0.25f}, {-0.5f, 0.f, 0.f}, {0.f, 0.75f, 0.f}, {0.f, 0.f, -1.f}, box);
    addFace(builder, "BoxLeft", {-0.625f, 0.f, -0.25f}, {0.f, 0.f, 0.5f}, {0.f, 0.75f, 0.f}, {-1.f, 0.f, 0.f}, box);
    addFace(builder, "BoxRight", {-0.125f, 0.f, 0.25f}, {0.f, 0.f, -0.5f}, {0.f, 0.75f, 0.f}, {1.f, 0.f, 0.f}, box);
    addFace(builder, "BoxTop", {-0.625f, 0.75f, 0.25f}, {0.5f, 0.f, 0.f}, {0.f, 0.f, -0.5f}, {0.f, 1.f, 0.f}, box);
    addFace(builder, "AreaLight", {-0.375f, 2.25f, 1.125f}, {0.75f, 0.f, 0.f}, {0.f, 0.f, 0.75f}, {0.f, -1.f, 0.f}, emitter);
    // Extra receiver behind the back wall provides an unambiguous occlusion control.
    addFace(builder, "BackProbe", {-0.5f, 0.5f, -1.5f}, {1.f, 0.f, 0.f}, {0.f, 1.f, 0.f}, {0.f, 0.f, 1.f}, receiver);
    return builder.getScene();
}
} // namespace

GPU_TEST(MyPTEmissiveVisibility, Device::Type::D3D12)
{
    auto scene = createVisibilityScene(ctx.getDevice());
    scene->update(ctx.getRenderContext(), 0.0);

    ProgramDesc desc;
    scene->getShaderModules(desc.shaderModules);
    desc.addTypeConformances(scene->getTypeConformances());
    desc.addShaderLibrary(kShaderFile).csEntry("main");
    desc.setShaderModel(ShaderModel::SM6_5);
    desc.setCompilerFlags(SlangCompilerFlags::FloatingPointModePrecise);
    DefineList defines = scene->getSceneDefines();
    defines.add("SAMPLE_GENERATOR_TYPE", std::to_string(SAMPLE_GENERATOR_TINY_UNIFORM));
    ctx.createProgram(desc, defines);

    const float4 lightPosition(0.125f, 2.25f, 1.5f, 0.f);
    const float4 lightNormal(0.f, -1.f, 0.f, 0.f);
    const std::array<VisibilityProbe, 5> probes = {{
        {{0.5f, 0.f, 0.5f, 0.f}, {0.f, 1.f, 0.f, 0.f}, lightPosition, lightNormal},
        {{-0.375f, 0.75f, 0.f, 0.f}, {0.f, 1.f, 0.f, 0.f}, lightPosition, lightNormal},
        {{1.f, 1.f, 0.5f, 0.f}, {-1.f, 0.f, 0.f, 0.f}, lightPosition, lightNormal},
        {{-0.375f, 0.f, -0.5f, 0.f}, {0.f, 1.f, 0.f, 0.f}, lightPosition, lightNormal},
        {{0.f, 1.f, -1.5f, 0.f}, {0.f, 0.f, 1.f, 0.f}, lightPosition, lightNormal},
    }};
    const std::array<const char*, 5> names = {"floor clear", "box top clear", "right wall clear", "box blocked", "back wall blocked"};
    const uint32_t count = uint32_t(probes.size());
    ctx.allocateStructuredBuffer("gProbes", count, probes.data(), sizeof(probes));
    ctx.allocateStructuredBuffer("gResults", count);
    ctx.allocateStructuredBuffer("gSegments", count);
    scene->bindShaderDataForRaytracing(ctx.getRenderContext(), ctx["gScene"]);
    ctx.runProgram(count);

    const auto results = ctx.readBuffer<uint4>("gResults");
    const auto segments = ctx.readBuffer<float4>("gSegments");
    ASSERT_EQ(results.size(), probes.size());
    ASSERT_EQ(segments.size(), probes.size());
    for (uint32_t i = 0; i < count; ++i)
    {
        EXPECT_EQ(segments[i].w, 1.f) << names[i] << ": production helper must construct a valid segment";
        EXPECT_GT(segments[i].z, 0.f) << names[i];
        EXPECT_EQ(results[i].y, i < 3 ? 1u : 0u) << names[i] << ": physical visibility";
        if (i >= 2) EXPECT_EQ(results[i].x, i == 2 ? 1u : 0u) << names[i] << ": old segment control";
        if (i < 3)
        {
            EXPECT_EQ(results[i].w, 0xffffffffu) << names[i] << ": new closest-hit query must miss";
        }
        else
        {
            ASSERT_LT(results[i].w, scene->getMaterialCount()) << names[i];
            EXPECT_EQ(scene->getMaterial(MaterialID(results[i].w))->getName(), std::string(i == 3 ? "Box" : "Back")) << names[i];
        }
        if (i < 2)
        {
            // Regression witness: the former offset-origin/original-distance ray
            // really hits the emitter, not a legitimate intervening occluder.
            EXPECT_EQ(results[i].x, 0u) << names[i] << ": old segment reproduces false occlusion";
            ASSERT_LT(results[i].z, scene->getMaterialCount()) << names[i];
            EXPECT_EQ(scene->getMaterial(MaterialID(results[i].z))->getName(), std::string("Emitter")) << names[i];
            EXPECT_LT(segments[i].y, segments[i].x) << names[i] << ": old emitter hit lies inside TMax";
        }
    }
}
} // namespace Falcor
