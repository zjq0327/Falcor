#include "RTPTNativePGTrain.h"
#include "Core/API/GFXAPI.h"
#include "Core/API/NativeHandleTraits.h"
#include "Core/Program/Program.h"
#include "Core/Program/ProgramVars.h"
#include "Core/Program/ProgramVersion.h"
#include <array>
#include <cstring>
#include <limits>

#if FALCOR_HAS_D3D12
#include "Core/API/Shared/D3D12RootSignature.h"
#include <wrl/client.h>
#endif

using namespace Falcor;

struct RTPTNativePGTrain::Impl
{
    ref<Device> device;
#if FALCOR_HAS_D3D12
    template<typename T> using ComPtr = Microsoft::WRL::ComPtr<T>;
    struct Slot
    {
        ComPtr<ID3D12CommandAllocator> allocator;
        ComPtr<ID3D12GraphicsCommandList> commands;
        // Retain every bound resource until this slot's dispatch has retired.
        std::array<ref<Buffer>, 8> resources;
        ComPtr<ID3D12QueryHeap> timestamps;
        uint64_t completeValue = 0;
    };

    ComPtr<ID3D12CommandQueue> commandQueue;
    ComPtr<ID3D12Fence> completion;
    ComPtr<ID3D12PipelineState> pipeline;
    ref<D3D12RootSignature> rootSignature;
    ref<Program> program;
    std::array<Slot, 3> slots;
    HANDLE completionEvent = nullptr;
    uint64_t submittedValue = 0;
    uint32_t nextSlot = 0;
    uint32_t recordedSlot = std::numeric_limits<uint32_t>::max();

    ~Impl()
    {
        if (completionEvent) CloseHandle(completionEvent);
    }

    void wait(uint64_t value)
    {
        if (!value || completion->GetCompletedValue() >= value) return;
        FALCOR_D3D_CALL(completion->SetEventOnCompletion(value, completionEvent));
        FALCOR_CHECK(WaitForSingleObject(completionEvent, INFINITE) == WAIT_OBJECT_0,
            "Waiting for native PGTrain completion failed.");
    }

    void initialize()
    {
        auto nativeDevice = device->getNativeHandle().as<ID3D12Device*>();
        D3D12_COMMAND_QUEUE_DESC queueDesc = {};
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_COMPUTE;
        FALCOR_D3D_CALL(nativeDevice->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(commandQueue.GetAddressOf())));
        commandQueue->SetName(L"RTPT PGTrain compute queue");
        FALCOR_D3D_CALL(nativeDevice->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(completion.GetAddressOf())));
        completionEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        FALCOR_CHECK(completionEvent != nullptr, "Creating the PGTrain completion event failed.");

        // Compile the same shader source and algorithm as the serial path.
        // Only its explicit native register declarations differ.
        ProgramDesc desc;
        desc.addShaderLibrary("RenderPasses/RTPT/RTPTPGTrain.cs.slang").csEntry("main");
        desc.setShaderModel(ShaderModel::SM6_6);
        DefineList defines;
        defines.add("ENABLE_PG", "1");
        defines.add("RTPT_PG_NATIVE", "1");
        program = Program::create(device, desc, defines);
        auto variables = ProgramVars::create(device, program.get());
        auto kernels = program->getActiveVersion()->getKernels(device.get(), variables.get());
        const auto* kernel = kernels->getKernel(ShaderType::Compute);
        FALCOR_CHECK(kernel != nullptr, "PGTrain compute kernel was not generated.");
        const auto bytecode = kernel->getBlobData();

        D3D12RootSignature::Desc rootDesc;
        for (uint32_t i = 0; i < 3; ++i)
            rootDesc.addRootDescriptor(ShaderResourceType::StructuredBufferSrv, i, 0);
        for (uint32_t i = 0; i < 5; ++i)
            rootDesc.addRootDescriptor(ShaderResourceType::StructuredBufferUav, i, 0);
        // Root constants implement the b0 constant buffer without upload-memory
        // lifetime management. The eight buffer descriptors cost 16 DWORDs;
        // settings add 28, staying within the 64-DWORD root-signature limit.
        rootDesc.addRootConstants(0, 0, 28);
        rootSignature = D3D12RootSignature::create(device, rootDesc);
        D3D12_COMPUTE_PIPELINE_STATE_DESC pipelineDesc = {};
        pipelineDesc.pRootSignature = rootSignature->getApiHandle().GetInterfacePtr();
        pipelineDesc.CS = {bytecode.data, bytecode.size};
        FALCOR_D3D_CALL(nativeDevice->CreateComputePipelineState(&pipelineDesc, IID_PPV_ARGS(pipeline.GetAddressOf())));

        for (auto& slot : slots)
        {
            FALCOR_D3D_CALL(nativeDevice->CreateCommandAllocator(
                D3D12_COMMAND_LIST_TYPE_COMPUTE, IID_PPV_ARGS(slot.allocator.GetAddressOf())));
            FALCOR_D3D_CALL(nativeDevice->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_COMPUTE,
                slot.allocator.Get(), pipeline.Get(), IID_PPV_ARGS(slot.commands.GetAddressOf())));
            FALCOR_D3D_CALL(slot.commands->Close());
        }
    }
#endif
};

RTPTNativePGTrain::RTPTNativePGTrain(ref<Device> device) : mpImpl(std::make_unique<Impl>())
{
    mpImpl->device = std::move(device);
#if FALCOR_HAS_D3D12
    FALCOR_CHECK(mpImpl->device->getType() == Device::Type::D3D12, "Native PGTrain requires D3D12.");
    mpImpl->initialize();
#else
    FALCOR_THROW("Native PGTrain requires a D3D12 build.");
#endif
}

RTPTNativePGTrain::~RTPTNativePGTrain()
{
    try { drain(); }
    catch (const std::exception& e) { logWarning("PGTrain compute queue shutdown: {}", e.what()); }
}

void RTPTNativePGTrain::record(const RTPTPG::Manager::NativeTrainingData& data, ID3D12QueryHeap* timestamps,
    uint32_t beginTimestamp, uint32_t endTimestamp)
{
#if FALCOR_HAS_D3D12
    auto& impl = *mpImpl;
    FALCOR_CHECK(impl.recordedSlot == std::numeric_limits<uint32_t>::max(), "PGTrain already has recorded work pending submission.");
    auto& slot = impl.slots[impl.nextSlot];
    impl.wait(slot.completeValue);
    FALCOR_D3D_CALL(slot.allocator->Reset());
    FALCOR_D3D_CALL(slot.commands->Reset(slot.allocator.Get(), impl.pipeline.Get()));
    slot.resources = data.buffers;
    slot.timestamps = timestamps;

    auto commands = slot.commands.Get();
    if (timestamps) commands->EndQuery(timestamps, D3D12_QUERY_TYPE_TIMESTAMP, beginTimestamp);
    commands->SetComputeRootSignature(impl.rootSignature->getApiHandle().GetInterfacePtr());
    commands->SetComputeRoot32BitConstants(8, uint32_t(data.constants.size()), data.constants.data(), 0);
    for (uint32_t i = 0; i < 3; ++i)
    {
        FALCOR_CHECK(slot.resources[i] != nullptr, "PGTrain SRV {} is missing.", i);
        commands->SetComputeRootShaderResourceView(i, slot.resources[i]->getGpuAddress());
    }
    for (uint32_t i = 0; i < 5; ++i)
    {
        FALCOR_CHECK(slot.resources[3 + i] != nullptr, "PGTrain UAV {} is missing.", i);
        commands->SetComputeRootUnorderedAccessView(3 + i, slot.resources[3 + i]->getGpuAddress());
    }
    const uint32_t pathCapacity = data.constants[4];
    if (pathCapacity) commands->Dispatch((pathCapacity + 63u) / 64u, 1, 1);
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    // Make all completed atomic writes visible before signaling the direct queue.
    commands->ResourceBarrier(1, &barrier);
    if (timestamps) commands->EndQuery(timestamps, D3D12_QUERY_TYPE_TIMESTAMP, endTimestamp);
    FALCOR_D3D_CALL(commands->Close());
    impl.recordedSlot = impl.nextSlot;
#else
    FALCOR_THROW("Native PGTrain requires a D3D12 build.");
#endif
}

void RTPTNativePGTrain::submit(Fence* inputsReady, uint64_t inputsValue, Fence* trainingDone, uint64_t doneValue)
{
#if FALCOR_HAS_D3D12
    auto& impl = *mpImpl;
    FALCOR_CHECK(impl.recordedSlot != std::numeric_limits<uint32_t>::max(), "PGTrain has no recorded work to submit.");
    FALCOR_CHECK(inputsReady && trainingDone, "PGTrain queue submission requires readiness and completion fences.");
    FALCOR_D3D_CALL(impl.commandQueue->Wait(inputsReady->getNativeHandle().as<ID3D12Fence*>(), inputsValue));
    auto& slot = impl.slots[impl.recordedSlot];
    ID3D12CommandList* lists[] = {slot.commands.Get()};
    impl.commandQueue->ExecuteCommandLists(1, lists);
    slot.completeValue = ++impl.submittedValue;
    FALCOR_D3D_CALL(impl.commandQueue->Signal(impl.completion.Get(), slot.completeValue));
    trainingDone->updateSignaledValue(doneValue);
    FALCOR_D3D_CALL(impl.commandQueue->Signal(trainingDone->getNativeHandle().as<ID3D12Fence*>(), doneValue));
    impl.nextSlot = (impl.recordedSlot + 1u) % uint32_t(impl.slots.size());
    impl.recordedSlot = std::numeric_limits<uint32_t>::max();
#else
    FALCOR_THROW("Native PGTrain requires a D3D12 build.");
#endif
}

void RTPTNativePGTrain::drain()
{
#if FALCOR_HAS_D3D12
    if (mpImpl->completion) mpImpl->wait(mpImpl->submittedValue);
#endif
}

void RTPTNativePGTrain::releaseCompletedBindings()
{
#if FALCOR_HAS_D3D12
    FALCOR_CHECK(mpImpl->recordedSlot == std::numeric_limits<uint32_t>::max(),
        "Cannot release PGTrain bindings while unsubmitted work is recorded.");
    drain();
    for (auto& slot : mpImpl->slots)
    {
        slot.resources = {};
        slot.timestamps.Reset();
    }
#endif
}

ID3D12CommandQueue* RTPTNativePGTrain::queue() const
{
#if FALCOR_HAS_D3D12
    return mpImpl->commandQueue.Get();
#else
    return nullptr;
#endif
}
