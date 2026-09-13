/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "Testing/UnitTest.h"
#include "Core/API/Device.h"
#include "Core/Program/ProgramManager.h"
#include "Core/Program/ProgramVersion.h"
#include <slang.h>
#include <random>

namespace Falcor
{
namespace
{
const char kShaderModuleA[] =
    "struct A\n"
    "{\n"
    "    ByteAddressBuffer buf;\n"
    "    uint c;\n"
    "    uint f(uint i)\n"
    "    {\n"
    "        return c * buf.Load(i * 4);\n"
    "    }\n"
    "}\n";

const char kShaderModuleB[] =
    "import ShaderStringUtil;\n"
    "uint f(uint i)\n"
    "{\n"
    "    return test(i);\n"
    "}\n";

const char kShaderModuleC[] =
    "import Tests.Slang.ShaderStringUtil;\n"
    "uint f(uint i)\n"
    "{\n"
    "    return test(i);\n"
    "}\n";

const char kShaderModuleD[] =
    "uint f(uint i)\n"
    "{\n"
    "    return i * 997;\n"
    "}\n";

const uint32_t kSize = 32;
} // namespace

GPU_TEST(ShaderStringInline)
{
    ref<Device> pDevice = ctx.getDevice();

    // Create program with generated code placed inline in the same translation
    // unit as the entry point.
    ProgramDesc desc;
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringInline.cs.slang").addString(kShaderModuleA);
    desc.csEntry("main");

    ctx.createProgram(desc, DefineList());
    ctx.allocateStructuredBuffer("result", kSize);

    // Create and bind test data.
    std::mt19937 r;
    std::vector<uint32_t> values(kSize);
    for (auto& v : values)
        v = r();

    auto buf =
        pDevice->createBuffer(values.size() * sizeof(uint32_t), ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, values.data());
    auto var = ctx.vars().getRootVar();
    var["gTest"]["moduleA"]["buf"] = buf;
    var["gTest"]["moduleA"]["c"] = 991u;

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], values[i] * 991);
    }
}

GPU_TEST(ShaderStringModule)
{
    // Create program with generated code placed in another translation unit.
    // The generated code is imported as a module using a relative path.
    ProgramDesc desc;
    desc.addShaderModule("GeneratedModule").addString(kShaderModuleD, "Tests/Slang/GeneratedModule.slang");
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringModule.cs.slang");
    desc.csEntry("main");

    ctx.createProgram(desc, DefineList());
    ctx.allocateStructuredBuffer("result", kSize);

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], i * 997);
    }
}

GPU_TEST(ShaderStringImport)
{
    // Create program with generated code placed inline in the same translation
    // unit as the entry point. The generated code imports another module using an absolute path.
    ProgramDesc desc;
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringImport.cs.slang").addString(kShaderModuleC);
    desc.csEntry("main");

    ctx.createProgram(desc, DefineList());
    ctx.allocateStructuredBuffer("result", kSize);

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], i * 993);
    }
}

GPU_TEST(ShaderStringImportDuplicate, "Duplicate import not working")
{
    // Create program with generated code placed inline in the same translation
    // unit as the entry point. The generated code imports another module using an absolute path.
    // The main translation unit imports the same module. This currently does not work.
    ProgramDesc desc;
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringImport.cs.slang").addString(kShaderModuleC);
    desc.csEntry("main");

    ctx.createProgram(desc, {{"IMPORT_FROM_MAIN", "1"}});
    ctx.allocateStructuredBuffer("result", kSize);

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], i * 993);
    }
}

GPU_TEST(ShaderStringImported)
{
    // Create program with generated code placed in a new translation unit.
    // The program imports a module that imports the generated module.
    ProgramDesc desc;
    desc.addShaderModule("GeneratedModule").addString(kShaderModuleD, "Tests/Slang/GeneratedModule.slang");
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringImported.cs.slang");
    desc.csEntry("main");

    ctx.createProgram(desc, DefineList());
    ctx.allocateStructuredBuffer("result", kSize);

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], i * 997);
    }
}

GPU_TEST(ShaderStringDynamicObject)
{
    const uint32_t typeID = 55;

    // Create program with generated code placed in a new translation unit.
    // The program imports a module that imports the generated module.
    // The generated code is called from a dynamically created object.
    ProgramDesc desc;
    desc.addShaderModule("GeneratedModule").addString(kShaderModuleD);
    desc.addShaderModule().addFile("Tests/Slang/ShaderStringDynamic.cs.slang");
    desc.csEntry("main");

    TypeConformanceList typeConformances = TypeConformanceList{{{"DynamicType", "IDynamicType"}, typeID}};
    desc.addTypeConformances(typeConformances);

    ctx.createProgram(desc, DefineList());
    ctx.allocateStructuredBuffer("result", kSize);

    auto var = ctx.vars().getRootVar();
    var["CB"]["type"] = typeID;

    // Run program and validate results.
    ctx.runProgram(kSize, 1, 1);

    std::vector<uint32_t> result = ctx.readBuffer<uint32_t>("result");
    for (uint32_t i = 0; i < kSize; i++)
    {
        EXPECT_EQ(result[i], i * 997);
    }
}

GPU_TEST(ShaderStringCompileRequestLifetime)
{
    const char source[] = R"(
        struct RetainedPayload { uint value; uint tag; };
        RWStructuredBuffer<RetainedPayload> result;
        [numthreads(1, 1, 1)]
        void main(uint3 tid : SV_DispatchThreadID)
        {
            RetainedPayload p;
            p.value = tid.x * 17 + 3;
            p.tag = tid.x ^ 0x5a;
            result[tid.x] = p;
        }
    )";
    ProgramDesc desc;
    desc.addShaderModule().addString(source);
    desc.csEntry("main");
    auto pDevice = ctx.getDevice();
    auto pManager = pDevice->getProgramManager();
    auto pProgram = Program::create(pDevice, desc);
    std::string log;
    auto pVersion = pManager->createProgramVersion(*pProgram, log);
    ASSERT_MSG(pVersion != nullptr, log);

    // Exercise both failure exits directly, without Program::link's interactive retry path.
    {
        ProgramDesc missingDesc;
        missingDesc.addShaderLibrary("Tests/Slang/CompileRequestLifetime_MissingFile.cs.slang").csEntry("main");
        auto pMissing = Program::create(pDevice, missingDesc);
        std::string missingLog;
        EXPECT_THROW_AS(pManager->createProgramVersion(*pMissing, missingLog), RuntimeError);
    }
    {
        ProgramDesc invalidDesc;
        invalidDesc.addShaderModule().addString("[numthreads(1,1,1)] void main() { undeclaredLifetimeTestSymbol; }");
        invalidDesc.csEntry("main");
        auto pInvalid = Program::create(pDevice, invalidDesc);
        std::string invalidLog;
        EXPECT(pManager->createProgramVersion(*pInvalid, invalidLog) == nullptr);
        EXPECT(invalidLog.find("undeclaredLifetimeTestSymbol") != std::string::npos);
    }

    // Components borrow session-owned code. Exercise the session after the successful request
    // and unrelated failed requests have been destroyed, without retaining a session in this test.
    {
        auto pSession = pVersion->getSlangSession();
        ASSERT(pSession != nullptr);
        EXPECT(pSession == pVersion->getSlangGlobalScope()->getSession());
        EXPECT(pSession == pVersion->getSlangEntryPoint(0)->getSession());
        slang::IComponentType* components[] = {pVersion->getSlangGlobalScope(), pVersion->getSlangEntryPoint(0)};
        Slang::ComPtr<slang::IComponentType> pComposite;
        ASSERT(SLANG_SUCCEEDED(pSession->createCompositeComponentType(components, 2, pComposite.writeRef())));
        ASSERT(pComposite != nullptr);
        auto pLayout = pComposite->getLayout();
        ASSERT(pLayout != nullptr);
        EXPECT(pLayout->findTypeByName("RetainedPayload") != nullptr);
        EXPECT_EQ(pLayout->getEntryPointCount(), 1);
    }

    // The successful request has left scope. This first findType lookup consults the retained
    // Slang reflector instead of its name cache, after unrelated failed requests were destroyed.
    auto pType = pVersion->getReflector()->findType("RetainedPayload");
    ASSERT(pType != nullptr);
    EXPECT_EQ(pType->getByteSize(), 8);
    auto pTag = pType->findMember("tag");
    ASSERT(pTag != nullptr);
    EXPECT_EQ(pTag->getByteOffset(), 4);
    auto pGlobalLayout = pVersion->getSlangGlobalScope()->getLayout();
    ASSERT(pGlobalLayout != nullptr);
    EXPECT(pGlobalLayout->findTypeByName("RetainedPayload") != nullptr);
    auto pEntryLayout = pVersion->getSlangEntryPoint(0)->getLayout()->getEntryPointByIndex(0);
    ASSERT(pEntryLayout != nullptr);
    EXPECT_EQ(uint32_t(pEntryLayout->getStage()), uint32_t(SLANG_STAGE_COMPUTE));

    // A subsequent compile must recover, and kernels must still specialize and execute after
    // their frontend request has been released. Buffer allocation also consumes reflected stride.
    ctx.createProgram(desc);
    ctx.allocateStructuredBuffer("result", kSize);
    ctx.runProgram(kSize, 1, 1);
    const auto values = ctx.readBuffer<uint2>("result");
    ASSERT_EQ(values.size(), kSize);
    for (uint32_t i = 0; i < kSize; ++i)
    {
        EXPECT_EQ(values[i].x, i * 17 + 3);
        EXPECT_EQ(values[i].y, i ^ 0x5a);
    }
}

GPU_TEST(ShaderStringSpecializedReflectionLifetime)
{
    const char source[] = R"(
        struct SpecializedPayload { float4 color; uint tag; };
        RWStructuredBuffer<SpecializedPayload> result;
        [numthreads(1, 1, 1)]
        void main(uint3 tid : SV_DispatchThreadID)
        {
            SpecializedPayload p;
            p.color = float4(tid, 1);
            p.tag = tid.x + 19;
            result[tid.x] = p;
        }
    )";
    ProgramDesc desc;
    desc.addShaderModule().addString(source);
    desc.csEntry("main");
    auto pDevice = ctx.getDevice();
    auto pProgram = Program::create(pDevice, desc);
    auto pVersion = pProgram->getActiveVersion();
    auto pVars = ProgramVars::create(pDevice, pProgram.get());
    ref<const ProgramReflection> pSpecializedReflector;
    {
        std::string log;
        // Bypass the version's kernel cache so only the returned reflector survives this scope.
        auto pKernels = pDevice->getProgramManager()->createProgramKernels(*pProgram, *pVersion, *pVars, log);
        ASSERT_MSG(pKernels != nullptr, log);
        pSpecializedReflector = pKernels->getReflector();
    }

    // Force other exact composites/layouts to be allocated and released in the same session.
    // This exposes a raw layout borrowed from createProgramKernels' destroyed local composite.
    auto pSession = pVersion->getSlangSession();
    for (uint32_t i = 0; i < 64; ++i)
    {
        Slang::ComPtr<slang::IComponentType> pRenamedEntry, pComposite;
        std::string entryName = "replacement_" + std::to_string(i);
        ASSERT(SLANG_SUCCEEDED(pVersion->getSlangEntryPoint(0)->renameEntryPoint(entryName.c_str(), pRenamedEntry.writeRef())));
        slang::IComponentType* components[] = {pVersion->getSlangGlobalScope(), pRenamedEntry.get()};
        ASSERT(SLANG_SUCCEEDED(pSession->createCompositeComponentType(components, 2, pComposite.writeRef())));
        ASSERT(pComposite->getLayout() != nullptr);
    }

    // This first name lookup must reach the retained specialized Slang layout, not a Falcor cache.
    auto pType = pSpecializedReflector->findType("SpecializedPayload");
    ASSERT(pType != nullptr);
    EXPECT_EQ(pType->getByteSize(), 20);
    auto pTag = pType->findMember("tag");
    ASSERT(pTag != nullptr);
    EXPECT_EQ(pTag->getByteOffset(), 16);
    EXPECT_EQ(pType->getSlangTypeLayout()->getSize(), 20);
}
} // namespace Falcor
