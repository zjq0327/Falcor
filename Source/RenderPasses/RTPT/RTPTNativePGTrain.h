#pragma once

#include "RTPTPG.h"
#include <memory>

struct ID3D12CommandQueue;
struct ID3D12QueryHeap;

/** Executes the existing PGTrain shader on a native D3D12 COMPUTE queue.
    Resource transitions and input readiness belong to the caller's direct queue.
    This runner owns its allocators, command lists and completion fence.
*/
class RTPTNativePGTrain
{
public:
    explicit RTPTNativePGTrain(Falcor::ref<Falcor::Device> device);
    ~RTPTNativePGTrain();

    RTPTNativePGTrain(const RTPTNativePGTrain&) = delete;
    RTPTNativePGTrain& operator=(const RTPTNativePGTrain&) = delete;

    void record(const RTPTPG::Manager::NativeTrainingData& data, ID3D12QueryHeap* timestamps = nullptr,
        uint32_t beginTimestamp = 0, uint32_t endTimestamp = 1);
    void submit(Falcor::Fence* inputsReady, uint64_t inputsValue, Falcor::Fence* trainingDone, uint64_t doneValue);
    void drain();
    // Release retired buffer references before a bounded PG pool migration.
    void releaseCompletedBindings();
    ID3D12CommandQueue* queue() const;

private:
    struct Impl;
    std::unique_ptr<Impl> mpImpl;
};
