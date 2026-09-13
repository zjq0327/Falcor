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
 # PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "Testing/UnitTest.h"
#include "Core/Pass/ComputePass.h"
#include "Core/Program/ProgramVersion.h"
#include <array>
#include <slang.h>

namespace Falcor
{
namespace
{
const char kSource[] = R"(
    struct SessionPayload
    {
        uint tag;
        uint coefficients[COUNT];
        uint tail;
        ByteAddressBuffer inputs[COUNT];
    };
    struct SessionBlock
    {
        uint bias;
        ConstantBuffer<SessionPayload> nested;
        ParameterBlock<SessionPayload> isolated;
        RWStructuredBuffer<uint4> output;
    };
    ParameterBlock<SessionBlock> gBlock;
    [numthreads(1, 1, 1)]
    void main(uint3 tid : SV_DispatchThreadID)
    {
        uint nestedValue = gBlock.nested.tag + 7 * gBlock.nested.tail;
        uint isolatedValue = gBlock.isolated.tag + 7 * gBlock.isolated.tail;
        for (uint j = 0; j < COUNT; ++j)
        {
            nestedValue += gBlock.nested.coefficients[j] * gBlock.nested.inputs[j].Load(tid.x * 4);
            isolatedValue += gBlock.isolated.coefficients[j] * gBlock.isolated.inputs[j].Load(tid.x * 4);
        }
        gBlock.output[tid.x] = uint4(nestedValue, isolatedValue, COUNT, gBlock.bias);
    }
)";

// Compare the program's original layout with the canonical type layout returned by
// createMutableShaderObject2. In particular, array packing and binding-range offsets
// must remain compatible with ShaderVar's offsets into the existing reflection tree.
void checkLayout(GPUUnitTestContext& ctx, slang::TypeLayoutReflection* expected, slang::TypeLayoutReflection* actual)
{
    ASSERT(expected != nullptr);
    ASSERT(actual != nullptr);
    ASSERT_EQ(uint32_t(actual->getKind()), uint32_t(expected->getKind()));
    EXPECT_EQ(actual->getSize(), expected->getSize());
    EXPECT_EQ(actual->getAlignment(), expected->getAlignment());
    ASSERT_EQ(actual->getBindingRangeCount(), expected->getBindingRangeCount());
    for (SlangInt i = 0; i < expected->getBindingRangeCount(); ++i)
    {
        EXPECT_EQ(uint32_t(actual->getBindingRangeType(i)), uint32_t(expected->getBindingRangeType(i)));
        EXPECT_EQ(actual->getBindingRangeBindingCount(i), expected->getBindingRangeBindingCount(i));
    }
    switch (expected->getKind())
    {
    case slang::TypeReflection::Kind::Struct:
        ASSERT_EQ(actual->getFieldCount(), expected->getFieldCount());
        for (uint32_t i = 0; i < expected->getFieldCount(); ++i)
        {
            auto expectedField = expected->getFieldByIndex(i);
            auto actualField = actual->getFieldByIndex(i);
            EXPECT_EQ(std::string(actualField->getName()), std::string(expectedField->getName()));
            EXPECT_EQ(actualField->getOffset(), expectedField->getOffset());
            EXPECT_EQ(actual->getFieldBindingRangeOffset(i), expected->getFieldBindingRangeOffset(i));
            checkLayout(ctx, expectedField->getTypeLayout(), actualField->getTypeLayout());
        }
        break;
    case slang::TypeReflection::Kind::Array:
        EXPECT_EQ(actual->getElementCount(), expected->getElementCount());
        EXPECT_EQ(
            actual->getElementStride(SLANG_PARAMETER_CATEGORY_UNIFORM),
            expected->getElementStride(SLANG_PARAMETER_CATEGORY_UNIFORM)
        );
        checkLayout(ctx, expected->getElementTypeLayout(), actual->getElementTypeLayout());
        break;
    case slang::TypeReflection::Kind::ConstantBuffer:
    case slang::TypeReflection::Kind::ParameterBlock:
        checkLayout(ctx, expected->getElementTypeLayout(), actual->getElementTypeLayout());
        break;
    default:
        break;
    }
}

void checkBlockLayout(GPUUnitTestContext& ctx, const ref<ParameterBlock>& block)
{
    ASSERT(block != nullptr);
    checkLayout(ctx, block->getReflection()->getElementType()->getSlangTypeLayout(), block->getShaderObject()->getElementTypeLayout());
}
} // namespace

GPU_TEST(ParameterBlockSessionLayoutAndMutation)
{
    constexpr uint32_t kElementCount = 4;
    const std::array<uint32_t, 2> counts = {2, 5};
    auto pDevice = ctx.getDevice();
    std::array<ref<ComputePass>, 2> passes;
    for (uint32_t i = 0; i < passes.size(); ++i)
    {
        ProgramDesc desc;
        desc.addShaderModule().addString(kSource);
        desc.csEntry("main");
        passes[i] = ComputePass::create(pDevice, desc, {{"COUNT", std::to_string(counts[i])}});
    }

    // Identical type names with different uniform/resource array lengths must belong
    // to different sessions. Keep both programs alive while exercising their objects.
    auto firstSession = passes[0]->getProgram()->getActiveVersion()->getSlangSession();
    auto secondSession = passes[1]->getProgram()->getActiveVersion()->getSlangSession();
    ASSERT(firstSession != secondSession);

    for (uint32_t variant = 0; variant < passes.size(); ++variant)
    {
        const uint32_t count = counts[variant];
        auto pass = passes[variant];
        auto root = pass->getRootVar();
        auto reflection = pass->getProgram()->getReflector()->getParameterBlock("gBlock");
        ASSERT(reflection != nullptr);

        // Cover both automatically created nested blocks and independently created
        // blocks later bound into the program, as used by Scene and MaterialSystem.
        for (uint32_t standalone = 0; standalone < 2; ++standalone)
        {
            auto block = standalone ? ParameterBlock::create(pDevice, reflection) : root["gBlock"].getParameterBlock();
            root["gBlock"] = block;
            auto var = block->getRootVar();
            checkBlockLayout(ctx, block);
            checkBlockLayout(ctx, var["nested"].getParameterBlock());
            checkBlockLayout(ctx, var["isolated"].getParameterBlock());

            var["bias"] = 101u + count;
            const std::array<const char*, 2> names = {"nested", "isolated"};
            for (uint32_t branch = 0; branch < names.size(); ++branch)
            {
                auto payload = var[names[branch]];
                payload["tag"] = 13u + branch;
                payload["tail"] = 29u + branch;
                for (uint32_t j = 0; j < count; ++j)
                    payload["coefficients"][j] = (j + 1) * (branch + 2);
            }

            std::array<ref<Buffer>, 2> outputs;
            std::array<std::vector<uint4>, 2> expected;
            std::vector<ref<Buffer>> inputs;
            // Submit both dispatches without readback/flush between them. The second
            // changes only SRV/UAV bindings: no setData call may invalidate a stale
            // descriptor cache on our behalf, including the nested ParameterBlock.
            for (uint32_t dispatch = 0; dispatch < 2; ++dispatch)
            {
                outputs[dispatch] = pDevice->createStructuredBuffer(
                    sizeof(uint4), kElementCount, ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal
                );
                var["output"] = outputs[dispatch];
                expected[dispatch].assign(kElementCount, uint4(0));
                for (uint32_t branch = 0; branch < names.size(); ++branch)
                {
                    for (uint32_t x = 0; x < kElementCount; ++x)
                        expected[dispatch][x][branch] = 13 + branch + 7 * (29 + branch);
                    for (uint32_t j = 0; j < count; ++j)
                    {
                        std::array<uint32_t, kElementCount> data;
                        for (uint32_t x = 0; x < kElementCount; ++x)
                        {
                            data[x] = 1000 * dispatch + 100 * branch + 10 * j + x + 1;
                            expected[dispatch][x][branch] += (j + 1) * (branch + 2) * data[x];
                        }
                        auto input = pDevice->createBuffer(
                            sizeof(data), ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, data.data()
                        );
                        inputs.push_back(input);
                        var[names[branch]]["inputs"][j] = input;
                    }
                }
                pass->execute(ctx.getRenderContext(), kElementCount, 1);
            }
            for (uint32_t dispatch = 0; dispatch < 2; ++dispatch)
            {
                const auto actual = outputs[dispatch]->getElements<uint4>();
                ASSERT_EQ(actual.size(), kElementCount);
                for (uint32_t x = 0; x < kElementCount; ++x)
                {
                    EXPECT_EQ(actual[x].x, expected[dispatch][x].x);
                    EXPECT_EQ(actual[x].y, expected[dispatch][x].y);
                    EXPECT_EQ(actual[x].z, count);
                    EXPECT_EQ(actual[x].w, 101u + count);
                }
            }
        }
    }
}
} // namespace Falcor
