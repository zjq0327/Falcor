#include "NrcIntegration.h"
#include "Core/Platform/OS.h"
#include <algorithm>
#include <array>
#include <limits>
#include <mutex>
#include <cstdio>

#ifndef FALCOR_HAS_NRC
#define FALCOR_HAS_NRC 0
#endif

#if FALCOR_HAS_NRC
#include "Core/API/NativeHandleTraits.h"
#include <NrcD3d12.h>
#include <delayimp.h>
#include <d3d12sdklayers.h>
#include <wrl/client.h>
#endif

namespace Falcor
{
#if FALCOR_HAS_NRC
namespace
{
using Microsoft::WRL::ComPtr;
constexpr size_t kBufferCount = static_cast<size_t>(nrc::BufferIdx::Count);
static_assert(sizeof(NrcConstants) == 96, "NRC 0.14 constant layout changed");

bool environmentFlag(const char* name)
{
    std::array<char, 16> value = {};
    return GetEnvironmentVariableA(name, value.data(), static_cast<DWORD>(value.size())) > 0 && value[0] != '0';
}

void CALLBACK infoQueueCallback(D3D12_MESSAGE_CATEGORY, D3D12_MESSAGE_SEVERITY severity,
    D3D12_MESSAGE_ID id, LPCSTR description, void*)
{
    if (severity > D3D12_MESSAGE_SEVERITY_WARNING) return;
    std::fprintf(stderr, "NRC_D3D12 severity=%u id=%u %s\n", unsigned(severity), unsigned(id), description ? description : "");
    std::fflush(stderr);
}

const char* statusName(nrc::Status status)
{
    switch (status)
    {
    case nrc::Status::OK: return "OK";
    case nrc::Status::SDKVersionMismatch: return "SDK/header version mismatch";
    case nrc::Status::AlreadyInitialized: return "SDK already initialized by another integration";
    case nrc::Status::SDKNotInitialized: return "SDK not initialized";
    case nrc::Status::InternalError: return "SDK internal error (see NRC log)";
    case nrc::Status::MemoryNotProvided: return "required GPU memory not provided";
    case nrc::Status::OutOfMemory: return "GPU out of memory";
    case nrc::Status::AllocationFailed: return "GPU allocation failed";
    case nrc::Status::ErrorParsingJSON: return "network configuration error";
    case nrc::Status::WrongParameter: return "invalid SDK parameter";
    case nrc::Status::UnsupportedDriver: return "unsupported NVIDIA driver";
    case nrc::Status::UnsupportedHardware: return "unsupported GPU";
    default: return "unknown SDK error";
    }
}

void sdkLogger(const char* message, nrc::LogLevel level)
{
    if (!message) return;
    if (environmentFlag("MYPT_NRC_DIAGNOSTICS"))
    {
        std::fprintf(stderr, "NRC_SDK level=%u %s\n", unsigned(level), message);
        std::fflush(stderr);
    }
    if (level == nrc::LogLevel::Error) logError("NRC: {}", message);
    else if (level == nrc::LogLevel::Warning) logWarning("NRC: {}", message);
    else if (level == nrc::LogLevel::Info) logInfo("NRC: {}", message);
}

struct Runtime
{
    std::mutex mutex;
    uint32_t contexts = 0;
    bool importsReady = false;
    std::wstring directory;
    // Delay-import pointers remain valid until the MyPT module unloads. Keep the
    // libraries resident across graph recreation and mode changes.
    std::vector<HMODULE> modules;
};
Runtime& runtime() { static Runtime state; return state; }

HRESULT resolveDelayImports()
{
    // Isolate SEH from C++ stack objects. A missing export must not terminate MyPT.
    __try { return __HrLoadAllImportsForDll("NRC_D3D12.dll"); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return E_FAIL; }
}

bool loadRuntime(Runtime& state, std::string& error)
{
    if (state.importsReady) return true;
    const std::array<const wchar_t*, 4> dllNames = {
        L"cudart64_12.dll", L"nvrtc-builtins64_128.dll", L"nvrtc64_120_0.dll", L"NRC_D3D12.dll"
    };
    std::filesystem::path directory = getRuntimeDirectory() / "nrc";
    if (!std::filesystem::is_regular_file(directory / L"NRC_D3D12.dll"))
        directory = std::filesystem::path(FALCOR_NRC_RUNTIME_DIR);
    for (auto name : dllNames)
    {
        if (!std::filesystem::is_regular_file(directory / name))
        {
            error = "NRC runtime is missing: " + (directory / name).string();
            return false;
        }
    }
    state.directory = directory.wstring();
    for (auto name : dllNames)
    {
        const auto path = std::filesystem::weakly_canonical(directory / name);
        if (HMODULE existing = GetModuleHandleW(name))
        {
            std::array<wchar_t, 32768> loadedPath = {};
            GetModuleFileNameW(existing, loadedPath.data(), static_cast<DWORD>(loadedPath.size()));
            if (!std::filesystem::equivalent(path, std::filesystem::path(loadedPath.data())))
            {
                error = "A different NRC/CUDA runtime is already loaded: " + std::filesystem::path(loadedPath.data()).string();
                return false;
            }
        }
        HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module)
        {
            error = "Cannot load NRC dependency " + path.string() + " (Windows error " + std::to_string(GetLastError()) + ")";
            return false;
        }
        state.modules.push_back(module);
    }
    const HRESULT result = resolveDelayImports();
    if (FAILED(result))
    {
        error = "NRC import resolution failed; the runtime does not match the linked SDK";
        return false;
    }
    state.importsReady = true;
    return true;
}

Resource::State resourceState(D3D12_RESOURCE_STATES state)
{
    switch (state)
    {
    case D3D12_RESOURCE_STATE_COMMON: return Resource::State::Common;
    case D3D12_RESOURCE_STATE_UNORDERED_ACCESS: return Resource::State::UnorderedAccess;
    case D3D12_RESOURCE_STATE_COPY_DEST: return Resource::State::CopyDest;
    case D3D12_RESOURCE_STATE_COPY_SOURCE: return Resource::State::CopySource;
    case D3D12_RESOURCE_STATE_GENERIC_READ: return Resource::State::GenericRead;
    case D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE: return Resource::State::NonPixelShader;
    default: FALCOR_THROW("Unsupported NRC initial resource state {}", static_cast<uint32_t>(state));
    }
}
}
#endif

struct NrcIntegration::Impl
{
    explicit Impl(ref<Device> d) : device(std::move(d)) {}
    ref<Device> device;
    std::string error;
    uint2 trainingDimensions = {0, 0};
    uint64_t publicBufferBytes = 0;
    uint64_t framesCompleted = 0;
    float trainingLoss = 0.f;
#if FALCOR_HAS_NRC
    nrc::d3d12::Context* sdk = nullptr;
    nrc::ContextSettings configuration;
    NrcConstants constants = {};
    nrc::BuffersAllocationInfo allocations = {};
    nrc::d3d12::Buffers nativeBuffers = {};
    std::array<ref<Buffer>, kBufferCount> buffers;
    std::array<Resource::State, kBufferCount> initialStates;
    bool configured = false;
    bool frameOpen = false;
    ID3D12CommandQueue* frameQueue = nullptr;
    bool diagnosticsEnabled = false;
    bool diagnosticWaits = false;
    ComPtr<ID3D12InfoQueue> infoQueue;
    ComPtr<ID3D12InfoQueue1> infoQueue1;
    DWORD callbackCookie = 0;
    bool callbackRegistered = false;
    uint64_t messagesRead = 0;

    void initializeDiagnostics()
    {
        diagnosticsEnabled = environmentFlag("MYPT_NRC_DIAGNOSTICS");
        diagnosticWaits = diagnosticsEnabled && environmentFlag("MYPT_NRC_DIAGNOSTICS_SYNC");
        if (!diagnosticsEnabled || infoQueue) return;
        auto* native = device->getNativeHandle().as<ID3D12Device*>();
        if (SUCCEEDED(native->QueryInterface(IID_PPV_ARGS(&infoQueue))))
        {
            if (!IsDebuggerPresent())
            {
                infoQueue->SetBreakOnID(D3D12_MESSAGE_ID_DEVICE_REMOVAL_PROCESS_AT_FAULT, FALSE);
                infoQueue->SetBreakOnSeverity(D3D12_MESSAGE_SEVERITY_CORRUPTION, FALSE);
                infoQueue->SetBreakOnSeverity(D3D12_MESSAGE_SEVERITY_ERROR, FALSE);
                infoQueue->SetBreakOnSeverity(D3D12_MESSAGE_SEVERITY_WARNING, FALSE);
            }
            if (SUCCEEDED(native->QueryInterface(IID_PPV_ARGS(&infoQueue1))))
                callbackRegistered = SUCCEEDED(infoQueue1->RegisterMessageCallback(
                    infoQueueCallback, D3D12_MESSAGE_CALLBACK_FLAG_NONE, nullptr, &callbackCookie));
        }
        std::fprintf(stderr, "NRC_DIAG enabled sync=%d infoQueue=%d callback=%d debugger=%d\n",
            diagnosticWaits, infoQueue != nullptr, callbackRegistered, IsDebuggerPresent());
        std::fflush(stderr);
    }

    void releaseDiagnostics()
    {
        if (callbackRegistered && infoQueue1) infoQueue1->UnregisterMessageCallback(callbackCookie);
        callbackRegistered = false;
        infoQueue1.Reset();
        infoQueue.Reset();
        messagesRead = 0;
    }

    void diagnostic(const char* stage, RenderContext* context = nullptr)
    {
        if (!diagnosticsEnabled) return;
        std::fprintf(stderr, "NRC_DIAG stage=%s frame=%llu open=%d pending=%d removed=0x%08lx\n", stage,
            static_cast<unsigned long long>(framesCompleted), frameOpen, context ? context->hasPendingCommands() : 0,
            static_cast<unsigned long>(device->getNativeHandle().as<ID3D12Device*>()->GetDeviceRemovedReason()));
        std::fflush(stderr);
        if (infoQueue && !callbackRegistered)
        {
            const auto count = infoQueue->GetNumStoredMessagesAllowedByRetrievalFilter();
            if (count < messagesRead) messagesRead = 0;
            for (; messagesRead < count; ++messagesRead)
            {
                SIZE_T size = 0;
                if (FAILED(infoQueue->GetMessage(messagesRead, nullptr, &size))) continue;
                std::vector<uint8_t> storage(size);
                auto* message = reinterpret_cast<D3D12_MESSAGE*>(storage.data());
                if (SUCCEEDED(infoQueue->GetMessage(messagesRead, message, &size)))
                    infoQueueCallback(message->Category, message->Severity, message->ID, message->pDescription, nullptr);
            }
        }
        if (context && diagnosticWaits)
        {
            std::fprintf(stderr, "NRC_DIAG waiting=%s\n", stage);
            std::fflush(stderr);
            context->submit(true);
            std::fprintf(stderr, "NRC_DIAG completed=%s removed=0x%08lx\n", stage,
                static_cast<unsigned long>(device->getNativeHandle().as<ID3D12Device*>()->GetDeviceRemovedReason()));
            std::fflush(stderr);
        }
    }

    bool check(nrc::Status status, const char* operation)
    {
        if (status == nrc::Status::OK) return true;
        error = std::string(operation) + ": " + statusName(status);
        logWarning("NRC: {}", error);
        return false;
    }

    void prepareBuffers(RenderContext* context)
    {
        for (size_t i = 0; i < kBufferCount; ++i)
        {
            if (!buffers[i]) continue;
            if (allocations.allocationInfo[i].allowUAV && buffers[i]->getGlobalState() == Resource::State::UnorderedAccess)
                context->uavBarrier(buffers[i].get());
            context->resourceBarrier(buffers[i].get(), initialStates[i]);
        }
    }

    ComPtr<ID3D12GraphicsCommandList4> nativeList(RenderContext* context)
    {
        FALCOR_CHECK(context && context->getDevice() == device, "NRC context belongs to a different graphics device");
        auto* low = context->getLowLevelData();
        auto* queue = low->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>();
        FALCOR_CHECK(!frameOpen || queue == frameQueue, "NRC frame must use one command queue");
        low->closeEncoders();
        ComPtr<ID3D12GraphicsCommandList4> commandList;
        FALCOR_CHECK(SUCCEEDED(low->getCommandBufferNativeHandle().as<ID3D12GraphicsCommandList*>()->QueryInterface(IID_PPV_ARGS(&commandList))),
            "D3D12 command list does not support ID3D12GraphicsCommandList4");
        return commandList;
    }

    void finishNative(RenderContext* context)
    {
        context->setPendingCommands(true);
        context->getLowLevelData()->closeEncoders();
        // NRC changes native heaps/root signatures/PSOs behind gfx's state cache.
        // Closing only the encoder is insufficient in the bundled Slang gfx version.
        // Submit without a CPU wait so the next Falcor pass gets a fresh command
        // buffer with fully reset bindings. All submissions use the same queue.
        context->unbindCustomGPUDescriptorPool();
        context->submit(false);
    }

    void bindBuffer(const ShaderVar& root, const char* name, nrc::BufferIdx index) const
    {
        auto var = root.findMember(name);
        if (var.isValid()) var = buffers[static_cast<size_t>(index)];
    }
#endif
};

NrcIntegration::NrcIntegration(ref<Device> device) : mpImpl(std::make_unique<Impl>(std::move(device))) {}
NrcIntegration::~NrcIntegration()
{
    try { shutdown(); }
    catch (const std::exception& e) { logWarning("NRC shutdown: {}", e.what()); }
}
bool NrcIntegration::isCompiled() { return FALCOR_HAS_NRC != 0; }
std::string NrcIntegration::getBuildStatus()
{
#if FALCOR_HAS_NRC
    return "NVIDIA NRC 0.14 (D3D12); runtime checked on first use";
#else
    return "NRC was not built. Configure FALCOR_ENABLE_NRC=ON with NRC_SDK_ROOT pointing to NVIDIA NRC 0.14.";
#endif
}

bool NrcIntegration::initialize()
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    if (p.sdk) return true;
    if (p.device->getType() != Device::Type::D3D12)
    {
        p.error = "NRC mode requires a D3D12 device";
        return false;
    }
    try
    {
        p.initializeDiagnostics();
        p.diagnostic("Initialize.enter");
        auto& rt = runtime();
        std::lock_guard<std::mutex> lock(rt.mutex);
        if (!loadRuntime(rt, p.error)) return false;
        ComPtr<ID3D12Device5> nativeDevice;
        if (FAILED(p.device->getNativeHandle().as<ID3D12Device*>()->QueryInterface(IID_PPV_ARGS(&nativeDevice))))
        {
            p.error = "The graphics device does not support ID3D12Device5";
            return false;
        }
        if (rt.contexts == 0)
        {
            nrc::GlobalSettings settings;
            settings.enableGPUMemoryAllocation = false;
            settings.enableDebugBuffers = true;
            settings.maxNumFramesInFlight = 4;
            settings.loggerFn = sdkLogger;
            settings.depsDirectoryPath = rt.directory.c_str();
            if (!p.check(nrc::d3d12::Initialize(settings), "Initialize")) return false;
            p.diagnostic("Initialize.sdkComplete");
        }
        nrc::d3d12::Context* newContext = nullptr;
        if (!p.check(nrc::d3d12::Context::Create(nativeDevice.Get(), newContext), "Create"))
        {
            if (newContext) nrc::d3d12::Context::Destroy(*newContext);
            if (rt.contexts == 0) nrc::d3d12::Shutdown();
            return false;
        }
        p.sdk = newContext;
        ++rt.contexts;
        p.diagnostic("Initialize.contextCreated");
        p.error.clear();
        return true;
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus();
    return false;
#endif
}

bool NrcIntegration::configure(RenderContext* context, const Configuration& settings)
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    if (!initialize()) return false;
    try
    {
        FALCOR_CHECK(!p.frameOpen, "Cannot configure NRC during an open frame");
        FALCOR_CHECK(settings.frameDimensions.x && settings.frameDimensions.y, "NRC dimensions must be positive");
        FALCOR_CHECK(settings.samplesPerPixel && settings.maxPathVertices, "NRC SPP and path vertices must be positive");
        nrc::ContextSettings configuration;
        configuration.frameDimensions = {settings.frameDimensions.x, settings.frameDimensions.y};
        configuration.trainingDimensions = {settings.trainingDimensions.x, settings.trainingDimensions.y};
        if (!configuration.trainingDimensions.x || !configuration.trainingDimensions.y)
            configuration.trainingDimensions = nrc::ComputeIdealTrainingDimensions(configuration.frameDimensions, settings.trainingIterations);
        configuration.trainingDimensions.x = std::clamp(configuration.trainingDimensions.x, 1u, settings.frameDimensions.x);
        configuration.trainingDimensions.y = std::clamp(configuration.trainingDimensions.y, 1u, settings.frameDimensions.y);
        configuration.sceneBoundsMin = {settings.sceneBoundsMin.x, settings.sceneBoundsMin.y, settings.sceneBoundsMin.z};
        configuration.sceneBoundsMax = {settings.sceneBoundsMax.x, settings.sceneBoundsMax.y, settings.sceneBoundsMax.z};
        configuration.smallestResolvableFeatureSize = settings.smallestResolvableFeatureSize;
        configuration.samplesPerPixel = settings.samplesPerPixel;
        configuration.maxPathVertices = settings.maxPathVertices;
        configuration.includeDirectLighting = false;
        configuration.learnIrradiance = false;
        configuration.requestReset = settings.requestReset;
        if (p.configured && !settings.requestReset && p.configuration == configuration) return true;
        p.diagnostic("Configure.beforePriorWorkWait", context);
        // Configure imports/reallocates CUDA external memory. Finish prior GPU users first.
        context->submit(true);
        nrc::BuffersAllocationInfo allocations = {};
        if (!p.check(nrc::d3d12::Context::GetBuffersAllocationInfo(configuration, allocations), "GetBuffersAllocationInfo")) return false;
        const uint64_t queryPaths = uint64_t(settings.frameDimensions.x) * settings.frameDimensions.y * settings.samplesPerPixel;
        const uint64_t trainingPaths = uint64_t(configuration.trainingDimensions.x) * configuration.trainingDimensions.y;
        auto capacity = [&](nrc::BufferIdx index) { return allocations.allocationInfo[size_t(index)].elementCount; };
        FALCOR_CHECK(capacity(nrc::BufferIdx::QueryPathInfo) >= queryPaths &&
            capacity(nrc::BufferIdx::QueryRadianceParams) >= queryPaths + trainingPaths &&
            capacity(nrc::BufferIdx::QueryRadiance) >= queryPaths + trainingPaths &&
            capacity(nrc::BufferIdx::TrainingPathVertices) >= trainingPaths * settings.maxPathVertices,
            "NRC SDK allocation does not cover render and QueryOnly bootstrap queries");
        std::array<ref<Buffer>, kBufferCount> buffers;
        nrc::d3d12::Buffers nativeBuffers = {};
        std::array<Resource::State, kBufferCount> initialStates;
        uint64_t bytes = 0;
        for (size_t i = 0; i < kBufferCount; ++i)
        {
            const auto& allocation = allocations.allocationInfo[i];
            if (!allocation.elementCount) continue;
            FALCOR_CHECK(allocation.elementSize && allocation.elementCount <= std::numeric_limits<uint32_t>::max(), "Invalid NRC allocation size");
            FALCOR_CHECK(allocation.elementSize <= std::numeric_limits<uint32_t>::max() &&
                allocation.elementCount <= (1ull << 32) / allocation.elementSize, "NRC buffer exceeds Falcor's 4 GiB buffer limit");
            ResourceBindFlags flags = allocation.useReadbackHeap ? ResourceBindFlags::None : ResourceBindFlags::ShaderResource;
            if (allocation.allowUAV) flags |= ResourceBindFlags::UnorderedAccess;
            if (allocation.isOnSharedHeap) flags |= ResourceBindFlags::Shared;
            const MemoryType memory = allocation.useReadbackHeap ? MemoryType::ReadBack : MemoryType::DeviceLocal;
            buffers[i] = p.device->createStructuredBuffer(static_cast<uint32_t>(allocation.elementSize),
                static_cast<uint32_t>(allocation.elementCount), flags, memory);
            if (allocation.debugName) buffers[i]->setName(allocation.debugName);
            initialStates[i] = resourceState(p.sdk->GetInitialBufferState(allocation));
            context->resourceBarrier(buffers[i].get(), initialStates[i]);
            nativeBuffers.buffers[i].resource = buffers[i]->getNativeHandle().as<ID3D12Resource*>();
            nativeBuffers.buffers[i].allocatedSize = allocation.elementCount * allocation.elementSize;
            if (p.diagnosticsEnabled)
            {
                D3D12_HEAP_PROPERTIES heap = {};
                D3D12_HEAP_FLAGS heapFlags = D3D12_HEAP_FLAG_NONE;
                nativeBuffers.buffers[i].resource->GetHeapProperties(&heap, &heapFlags);
                std::fprintf(stderr, "NRC_DIAG buffer=%zu name=%s count=%zu stride=%zu shared=%d heapFlags=0x%x initial=%u gpu=0x%llx\n", i,
                    allocation.debugName ? allocation.debugName : "", allocation.elementCount, allocation.elementSize, allocation.isOnSharedHeap,
                    unsigned(heapFlags), unsigned(p.sdk->GetInitialBufferState(allocation)),
                    static_cast<unsigned long long>(nativeBuffers.buffers[i].resource->GetGPUVirtualAddress()));
                std::fflush(stderr);
            }
            bytes += nativeBuffers.buffers[i].allocatedSize;
        }
        // SDK Configure can operate on resources immediately, outside our command list.
        context->submit(true);
        p.diagnostic("Configure.beforeSDK", context);
        const auto configureResult = p.sdk->Configure(configuration, &nativeBuffers);
        p.diagnostic("Configure.afterSDK", context);
        if (!p.check(configureResult, "Configure"))
        {
            // Keep both old and new buffers alive until all partial SDK imports are destroyed.
            const auto originalError = p.error;
            shutdown();
            p.error = originalError;
            return false;
        }
        p.buffers = std::move(buffers);
        p.nativeBuffers = nativeBuffers;
        p.allocations = allocations;
        p.initialStates = initialStates;
        p.configuration = configuration;
        p.configuration.requestReset = false;
        p.configured = true;
        p.trainingDimensions = {configuration.trainingDimensions.x, configuration.trainingDimensions.y};
        p.publicBufferBytes = bytes;
        p.framesCompleted = 0;
        p.error.clear();
        return true;
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus(); return false;
#endif
}

bool NrcIntegration::beginFrame(RenderContext* context, const FrameSettings& settings)
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    try
    {
        FALCOR_CHECK(p.configured && !p.frameOpen, "NRC BeginFrame requires a configured idle context");
        p.diagnostic("BeginFrame.beforePrepare", context);
        nrc::FrameSettings frame;
        frame.trainTheCache = settings.trainTheCache;
        frame.skipDeltaVertices = settings.skipDeltaVertices;
        frame.terminationHeuristicThreshold = settings.terminationThreshold;
        frame.trainingTerminationHeuristicThreshold = settings.terminationThreshold;
        frame.maxExpectedAverageRadianceValue = settings.maxExpectedAverageRadiance;
        frame.selfTrainingAttenuation = settings.selfTrainingAttenuation;
        frame.proportionUnbiased = 0.f; // QueryPT supplies all training records; no independent long paths.
        frame.numTrainingIterations = settings.trainingIterations;
        frame.resolveMode = static_cast<NrcResolveMode>(settings.resolveMode);
        p.prepareBuffers(context);
        p.diagnostic("BeginFrame.afterPrepare", context);
        auto commandList = p.nativeList(context);
        const auto result = p.sdk->BeginFrame(commandList.Get(), frame);
        p.finishNative(context);
        if (!p.check(result, "BeginFrame")) return false;
        p.frameOpen = true;
        p.frameQueue = context->getLowLevelData()->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>();
        p.diagnostic("BeginFrame.afterSDK", context);
        if (!p.check(p.sdk->PopulateShaderConstants(p.constants), "PopulateShaderConstants")) return false;
        p.diagnostic("BeginFrame.constantsReady", context);
        p.error.clear();
        return true;
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus(); return false;
#endif
}

void NrcIntegration::prepareForPathTracing(RenderContext* context)
{
#if FALCOR_HAS_NRC
    FALCOR_CHECK(mpImpl->frameOpen, "NRC path tracing requires BeginFrame");
    mpImpl->diagnostic("PathTracing.beforePrepare", context);
    mpImpl->prepareBuffers(context);
    mpImpl->diagnostic("PathTracing.afterPrepare", context);
#endif
}

void NrcIntegration::bindShaderData(const ShaderVar& root) const
{
#if FALCOR_HAS_NRC
    auto cb = root.findMember("NrcCB");
    if (cb.isValid())
    {
        auto constants = cb.findMember("gNrcConstants");
        if (constants.isValid()) constants.setBlob(mpImpl->constants);
    }
    mpImpl->bindBuffer(root, "gNrcQueryPathInfo", nrc::BufferIdx::QueryPathInfo);
    mpImpl->bindBuffer(root, "gNrcTrainingPathInfo", nrc::BufferIdx::TrainingPathInfo);
    mpImpl->bindBuffer(root, "gNrcTrainingPathVertices", nrc::BufferIdx::TrainingPathVertices);
    mpImpl->bindBuffer(root, "gNrcQueryRadianceParams", nrc::BufferIdx::QueryRadianceParams);
    mpImpl->bindBuffer(root, "gNrcCountersData", nrc::BufferIdx::Counter);
#endif
}

void NrcIntegration::bindResolveData(const ShaderVar& root) const
{
    bindShaderData(root);
#if FALCOR_HAS_NRC
    mpImpl->bindBuffer(root, "gNrcQueryRadiance", nrc::BufferIdx::QueryRadiance);
#endif
}

void NrcIntegration::diagnosticCheckpoint(RenderContext* context, const char* stage)
{
#if FALCOR_HAS_NRC
    mpImpl->diagnostic(stage, context);
#endif
}

bool NrcIntegration::queryAndTrain(RenderContext* context, bool calculateTrainingLoss)
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    try
    {
        FALCOR_CHECK(p.frameOpen, "NRC QueryAndTrain requires BeginFrame");
        p.diagnostic("QueryAndTrain.beforePrepare", context);
        p.prepareBuffers(context);
        p.diagnostic("QueryAndTrain.afterPrepare", context);
        auto commandList = p.nativeList(context);
        auto result = p.sdk->QueryAndTrain(commandList.Get(), calculateTrainingLoss ? &p.trainingLoss : nullptr);
        p.finishNative(context);
        p.diagnostic("QueryAndTrain.afterSDK", context);
        if (!p.check(result, "QueryAndTrain")) return false;
        p.prepareBuffers(context);
        p.diagnostic("QueryAndTrain.complete", context);
        return true;
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus(); return false;
#endif
}

bool NrcIntegration::resolve(RenderContext* context, const ref<Texture>& output)
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    try
    {
        FALCOR_CHECK(p.frameOpen && output, "NRC Resolve requires an open frame and output texture");
        p.diagnostic("Resolve.beforePrepare", context);
        p.prepareBuffers(context);
        context->resourceBarrier(output.get(), Resource::State::UnorderedAccess);
        auto commandList = p.nativeList(context);
        auto result = p.sdk->Resolve(commandList.Get(), output->getNativeHandle().as<ID3D12Resource*>());
        p.finishNative(context);
        p.diagnostic("Resolve.afterSDK", context);
        context->uavBarrier(output.get());
        return p.check(result, "Resolve");
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus(); return false;
#endif
}

bool NrcIntegration::endFrame(RenderContext* context)
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    try
    {
        FALCOR_CHECK(p.frameOpen, "NRC EndFrame requires BeginFrame");
        p.diagnostic("EndFrame.beforePrepare", context);
        auto* queue = context->getLowLevelData()->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>();
        FALCOR_CHECK(queue == p.frameQueue, "NRC EndFrame must use the frame's command queue");
        p.prepareBuffers(context);
        context->submit(false);
        p.diagnostic("EndFrame.afterSubmit", context);
        const auto result = p.sdk->EndFrame(queue);
        p.frameOpen = false;
        p.frameQueue = nullptr;
        p.diagnostic("EndFrame.afterSDK", context);
        if (!p.check(result, "EndFrame")) return false;
        ++p.framesCompleted;
        return true;
    }
    catch (const std::exception& e) { p.error = e.what(); return false; }
#else
    mpImpl->error = getBuildStatus(); return false;
#endif
}

void NrcIntegration::shutdown()
{
#if FALCOR_HAS_NRC
    auto& p = *mpImpl;
    if (!p.sdk) { p.releaseDiagnostics(); return; }
    p.diagnostic("Shutdown.enter");
    auto* context = p.device->getRenderContext();
    if (p.frameOpen) endFrame(context);
    context->submit(true);
    p.diagnostic("Shutdown.afterWait");
    auto& rt = runtime();
    std::lock_guard<std::mutex> lock(rt.mutex);
    p.check(nrc::d3d12::Context::Destroy(*p.sdk), "Destroy");
    p.sdk = nullptr;
    p.buffers = {};
    p.nativeBuffers = {};
    p.configured = false;
    p.frameOpen = false;
    p.publicBufferBytes = 0;
    p.framesCompleted = 0;
    if (--rt.contexts == 0) nrc::d3d12::Shutdown();
    p.diagnostic("Shutdown.complete");
    p.releaseDiagnostics();
#endif
}

uint2 NrcIntegration::getTrainingDimensions() const { return mpImpl->trainingDimensions; }
uint64_t NrcIntegration::getPublicBufferBytes() const { return mpImpl->publicBufferBytes; }
uint64_t NrcIntegration::getFramesCompleted() const { return mpImpl->framesCompleted; }
float NrcIntegration::getTrainingLoss() const { return mpImpl->trainingLoss; }
const std::string& NrcIntegration::getError() const { return mpImpl->error; }
bool NrcIntegration::isInitialized() const
{
#if FALCOR_HAS_NRC
    return mpImpl->sdk != nullptr;
#else
    return false;
#endif
}
ref<Buffer> NrcIntegration::getCounterBuffer() const
{
#if FALCOR_HAS_NRC
    return mpImpl->buffers[static_cast<size_t>(nrc::BufferIdx::Counter)];
#else
    return nullptr;
#endif
}
}
