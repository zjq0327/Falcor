#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdint>
#include <cstdio>
#include <array>
#include "Include/NrcD3d12.h"
using Microsoft::WRL::ComPtr;
static void logger(const char* text, nrc::LogLevel level) { std::printf("NRC[%d] %s\n", int(level), text); }
int main()
{
    ComPtr<IDXGIFactory4> factory;
    if (FAILED(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory)))) return 1;
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i)
    {
        DXGI_ADAPTER_DESC1 desc = {};
        adapter->GetDesc1(&desc);
        if (desc.VendorId == 0x10de) break;
        adapter.Reset();
    }
    if (!adapter) return 2;
    ComPtr<ID3D12Device5> device;
    if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_1, IID_PPV_ARGS(&device)))) return 3;
    nrc::GlobalSettings global;
    global.enableGPUMemoryAllocation = false;
    global.enableDebugBuffers = true;
    global.loggerFn = logger;
    auto status = nrc::d3d12::Initialize(global);
    std::printf("Initialize=%d\n", int(status));
    if (status != nrc::Status::OK) return 4;
    nrc::d3d12::Context* context = nullptr;
    status = nrc::d3d12::Context::Create(device.Get(), context);
    std::printf("Create=%d\n", int(status));
    if (status != nrc::Status::OK) { nrc::d3d12::Shutdown(); return 5; }
    nrc::ContextSettings config;
    config.frameDimensions = {64, 64};
    config.trainingDimensions = {64, 64};
    config.sceneBoundsMin = {-1.f, -1.f, -1.f};
    config.sceneBoundsMax = {1.f, 1.f, 1.f};
    config.maxPathVertices = 9;
    nrc::BuffersAllocationInfo allocation = {};
    status = nrc::d3d12::Context::GetBuffersAllocationInfo(config, allocation);
    std::printf("GetBuffersAllocationInfo=%d\n", int(status));
    std::array<ComPtr<ID3D12Resource>, size_t(nrc::BufferIdx::Count)> resources;
    nrc::d3d12::Buffers buffers;
    for (size_t i = 0; i < resources.size(); ++i)
    {
        const auto& info = allocation.allocationInfo[i];
        std::printf("buffer[%zu] %s count=%zu stride=%zu shared=%d uav=%d readback=%d state=%u\n", i,
            info.debugName, info.elementCount, info.elementSize, info.isOnSharedHeap, info.allowUAV,
            info.useReadbackHeap, unsigned(context->GetInitialBufferState(info)));
        if (!info.elementCount) continue;
        D3D12_HEAP_PROPERTIES heap = {};
        heap.Type = info.useReadbackHeap ? D3D12_HEAP_TYPE_READBACK : D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC desc = {};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = info.elementCount * info.elementSize;
        desc.Height = desc.DepthOrArraySize = desc.MipLevels = 1;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        desc.Flags = info.allowUAV ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE;
        auto result = device->CreateCommittedResource(&heap, info.isOnSharedHeap ? D3D12_HEAP_FLAG_SHARED : D3D12_HEAP_FLAG_NONE,
            &desc, context->GetInitialBufferState(info), nullptr, IID_PPV_ARGS(&resources[i]));
        if (FAILED(result)) { std::printf("allocation HRESULT=%lx\n", result); return 6; }
        buffers.buffers[i].resource = resources[i].Get();
        buffers.buffers[i].allocatedSize = desc.Width;
    }
    status = context->Configure(config, &buffers);
    std::printf("Configure=%d\n", int(status));
    const bool success = status == nrc::Status::OK;
    nrc::d3d12::Context::Destroy(*context);
    nrc::d3d12::Shutdown();
    return success ? 0 : 7;
}
