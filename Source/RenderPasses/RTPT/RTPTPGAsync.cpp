#include "RTPT.h"
#include "Core/API/NativeHandleTraits.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#if FALCOR_HAS_D3D12
#include <wrl/client.h>
#endif

struct RTPTPGTimingResources
{
#if FALCOR_HAS_D3D12
    Microsoft::WRL::ComPtr<ID3D12QueryHeap> queries;
    Microsoft::WRL::ComPtr<ID3D12Resource> readback;
#endif
};

RTPT::~RTPT()
{
    try
    {
        drainPGAsync();
        // Read-tree resources can still be referenced by submitted main work.
        mpDevice->getRenderContext()->submit(true);
    }
    catch (const std::exception& e)
    {
        logWarning("RTPT async shutdown: {}", e.what());
    }
}

bool RTPT::preparePGAsync()
{
    if (!mPGAsyncTraining || mPGAsyncFailed) return false;
    if (mpDevice->getType() != Device::Type::D3D12)
    {
        mPGAsyncFallbackReason = "Independent PG training currently supports D3D12 only.";
        return false;
    }
    if (!mpPGAsyncTrainer)
    {
        try
        {
            mpPGAsyncTrainer = std::make_unique<RTPTNativePGTrain>(mpDevice);
            mpPGInputsReady = mpDevice->createFence();
            mpPGTrainingDone = mpDevice->createFence();
        }
        catch (const std::exception& e)
        {
            mPGAsyncFallbackReason = e.what();
            mPGAsyncFailed = true;
            mpPGAsyncTrainer.reset();
            logWarning("PG will use serial training: {}", mPGAsyncFallbackReason);
            return false;
        }
    }
    return true;
}

void RTPT::drainPGAsync()
{
    if (mPGAsyncRecorded)
    {
        mPGTrainingDoneValue = mpPGTrainingDone->updateSignaledValue();
        mpPGAsyncTrainer->submit(mpPGInputsReady.get(), mPGInputsReadyValue, mpPGTrainingDone.get(), mPGTrainingDoneValue);
        mPGAsyncRecorded = false;
    }
    if (mpPGTrainingDone && mPGTrainingDoneValue)
        mpPGTrainingDone->wait(mPGTrainingDoneValue);
}

Properties RTPT::getPGAsyncStatistics() const
{
    Properties result = mPGLastAsyncTiming;
    result["requestedEnabled"] = mPGAsyncTraining;
    result["active"] = mEnablePG && mPGSettings.enabled && mPGSettings.trainingEnabled &&
        mPGAsyncTraining && mpPGAsyncTrainer != nullptr && !mPGAsyncFailed;
    bool independentQueues = false;
#if FALCOR_HAS_D3D12
    if (mpPGAsyncTrainer && mpDevice->getType() == Device::Type::D3D12)
        independentQueues = mpPGAsyncTrainer->queue() !=
            mpDevice->getRenderContext()->getLowLevelData()->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>();
#endif
    result["independentQueues"] = independentQueues;
    result["queueType"] = "Compute";
    result["measurementEnabled"] = mPGAsyncMeasure;
    result["timingsValid"] = mPGMeasuredFrames != 0;
    result["submissions"] = mPGAsyncSubmissions;
    result["measuredFrames"] = mPGMeasuredFrames;
    result["overlappingFrames"] = mPGOverlappingFrames;
    result["maxOverlapMs"] = mPGMaxOverlapMs;
    result["fallbackReason"] = mPGAsyncFallbackReason;
    return result;
}

void RTPT::collectPGAsyncTiming()
{
#if FALCOR_HAS_D3D12
    for (auto& timing : mPGAsyncTimings)
    {
        if (!timing.completeValue || timing.complete->getCurrentValue() < timing.completeValue) continue;
        uint64_t stamps[4];
        void* data = nullptr;
        D3D12_RANGE range = {0, sizeof(stamps)};
        FALCOR_CHECK(SUCCEEDED(timing.resources->readback->Map(0, &range, &data)), "Cannot map PG timestamps.");
        std::memcpy(stamps, data, sizeof(stamps));
        D3D12_RANGE written = {0, 0};
        timing.resources->readback->Unmap(0, &written);
        timing.completeValue = 0;
        if (stamps[1] < stamps[0] || stamps[3] < stamps[2]) continue;
        auto toQpc = [](uint64_t stamp, uint64_t gpu, uint64_t cpu, uint64_t frequency, uint64_t qpcFrequency)
        {
            // Subtract in floating point to handle timestamps preceding calibration.
            return double(cpu) + (double(stamp) - double(gpu)) * double(qpcFrequency) / double(frequency);
        };
        const double ts = toQpc(stamps[0], timing.trainGpu, timing.trainCpu, timing.trainFrequency, timing.qpcFrequency);
        const double te = toQpc(stamps[1], timing.trainGpu, timing.trainCpu, timing.trainFrequency, timing.qpcFrequency);
        const double ms = toQpc(stamps[2], timing.mainGpu, timing.mainCpu, timing.mainFrequency, timing.qpcFrequency);
        const double me = toQpc(stamps[3], timing.mainGpu, timing.mainCpu, timing.mainFrequency, timing.qpcFrequency);
        const double overlapTicks = std::max(0., std::min(te, me) - std::max(ts, ms));
        const double scale = 1000. / double(timing.qpcFrequency);
        const double overlapMs = overlapTicks * scale;
        ++mPGMeasuredFrames;
        if (overlapTicks > double(timing.calibrationError)) ++mPGOverlappingFrames;
        mPGMaxOverlapMs = std::max(mPGMaxOverlapMs, overlapMs);
        if (timing.frameIndex < mPGLastTimingSequence) continue;
        mPGLastTimingSequence = timing.frameIndex;
        mPGLastAsyncTiming["frameIndex"] = timing.frameIndex;
        mPGLastAsyncTiming["trainStartQpc"] = ts;
        mPGLastAsyncTiming["trainEndQpc"] = te;
        mPGLastAsyncTiming["mainStartQpc"] = ms;
        mPGLastAsyncTiming["mainEndQpc"] = me;
        mPGLastAsyncTiming["qpcFrequency"] = timing.qpcFrequency;
        mPGLastAsyncTiming["timestampCalibrationErrorQpc"] = timing.calibrationError;
        mPGLastAsyncTiming["trainMs"] = (te - ts) * scale;
        mPGLastAsyncTiming["mainMs"] = (me - ms) * scale;
        mPGLastAsyncTiming["overlapMs"] = overlapMs;
    }
#endif
}

void RTPT::beginPGAsyncTiming(RenderContext* pMain, RenderContext* pTrain)
{
    mPGTimingThisFrame = false;
#if FALCOR_HAS_D3D12
    if (!mPGAsyncMeasure || mpDevice->getType() != Device::Type::D3D12) return;
    auto& timing = mPGAsyncTimings[mPGAsyncTimingSlot];
    if (timing.completeValue) return; // Never overwrite an in-flight measurement.
    if (!timing.resources)
    {
        timing.resources = std::make_shared<RTPTPGTimingResources>();
        auto device = mpDevice->getNativeHandle().as<ID3D12Device*>();
        D3D12_QUERY_HEAP_DESC queries = {};
        queries.Count = 4;
        queries.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP;
        FALCOR_CHECK(SUCCEEDED(device->CreateQueryHeap(&queries, IID_PPV_ARGS(&timing.resources->queries))),
            "Cannot create PG timestamp queries.");
        D3D12_HEAP_PROPERTIES heap = {};
        heap.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC buffer = {};
        buffer.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        buffer.Width = 32;
        buffer.Height = 1;
        buffer.DepthOrArraySize = 1;
        buffer.MipLevels = 1;
        buffer.SampleDesc.Count = 1;
        buffer.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        FALCOR_CHECK(SUCCEEDED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&timing.resources->readback))),
            "Cannot create PG timestamp readback.");
        timing.complete = mpDevice->createFence();
    }
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    timing.qpcFrequency = uint64_t(frequency.QuadPart);
    auto calibrate = [](ID3D12CommandQueue* queue, uint64_t& gpu, uint64_t& cpu, uint64_t& hz, uint64_t& span)
    {
        LARGE_INTEGER before, after;
        QueryPerformanceCounter(&before);
        const HRESULT a = queue->GetTimestampFrequency(&hz);
        const HRESULT b = queue->GetClockCalibration(&gpu, &cpu);
        QueryPerformanceCounter(&after);
        span = uint64_t(after.QuadPart - before.QuadPart);
        return SUCCEEDED(a) && SUCCEEDED(b) && hz != 0;
    };
    uint64_t mainSpan = 0, trainSpan = 0;
    auto mainQueue = pMain->getLowLevelData()->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>();
    auto trainQueue = pTrain ? pTrain->getLowLevelData()->getCommandQueueNativeHandle().as<ID3D12CommandQueue*>()
                             : mpPGAsyncTrainer->queue();
    if (!calibrate(mainQueue, timing.mainGpu, timing.mainCpu, timing.mainFrequency, mainSpan) ||
        !calibrate(trainQueue, timing.trainGpu, timing.trainCpu, timing.trainFrequency, trainSpan)) return;
    // Conservatively require more overlap than both calibration call durations.
    timing.calibrationError = mainSpan + trainSpan + timing.qpcFrequency / 1000000;
    timing.frameIndex = ++mPGTimingSequence;
    mPGAsyncCurrentTimingSlot = mPGAsyncTimingSlot;
    mPGAsyncTimingSlot = (mPGAsyncTimingSlot + 1) % uint32_t(mPGAsyncTimings.size());
    mPGTimingThisFrame = true;
#endif
}

void RTPT::writePGAsyncTimestamp(RenderContext* pContext, uint32_t index)
{
#if FALCOR_HAS_D3D12
    if (!mPGTimingThisFrame) return;
    pContext->getLowLevelData()->closeEncoders();
    auto commands = pContext->getLowLevelData()->getCommandBufferNativeHandle().as<ID3D12GraphicsCommandList*>();
    commands->EndQuery(mPGAsyncTimings[mPGAsyncCurrentTimingSlot].resources->queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, index);
    pContext->setPendingCommands(true);
#endif
}

void RTPT::recordPGAsyncTraining(RenderContext* pMain)
{
    mpPG->prepareNativeTraining(pMain);
    pMain->submit(false);
    mPGInputsReadyValue = pMain->signal(mpPGInputsReady.get());
    beginPGAsyncTiming(pMain, nullptr);
#if FALCOR_HAS_D3D12
    auto queries = mPGTimingThisFrame ? mPGAsyncTimings[mPGAsyncCurrentTimingSlot].resources->queries.Get() : nullptr;
    mpPGAsyncTrainer->record(mpPG->getNativeTrainingData(mpScene->getCamera()->getPosition(), mSHARCSceneScale,
        mPGFrameIndex, true), queries, 0, 1);
#endif
    mPGAsyncRecorded = true;
}

void RTPT::finishPGAsync(RenderContext* pMain)
{
    if (mPGAsyncRecorded)
    {
        // Submit the main work first, then the already-recorded training work.
        // This avoids training finishing while the CPU is still recording Main.
        pMain->submit(false);
        mPGTrainingDoneValue = mpPGTrainingDone->updateSignaledValue();
        mpPGAsyncTrainer->submit(mpPGInputsReady.get(), mPGInputsReadyValue, mpPGTrainingDone.get(), mPGTrainingDoneValue);
        pMain->wait(mpPGTrainingDone.get(), mPGTrainingDoneValue);
        ++mPGAsyncSubmissions;
        mPGAsyncRecorded = false;
    }
    if (mPGTimingThisFrame)
    {
        auto& timing = mPGAsyncTimings[mPGAsyncCurrentTimingSlot];
        // The main queue's wait is ordered before this resolve/readback.
#if FALCOR_HAS_D3D12
        pMain->getLowLevelData()->closeEncoders();
        auto commands = pMain->getLowLevelData()->getCommandBufferNativeHandle().as<ID3D12GraphicsCommandList*>();
        commands->ResolveQueryData(timing.resources->queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 0, 4,
            timing.resources->readback.Get(), 0);
        pMain->setPendingCommands(true);
#endif
        pMain->submit(false);
        timing.completeValue = pMain->signal(timing.complete.get());
        mPGTimingThisFrame = false;
    }
}
