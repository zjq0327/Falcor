#include "Testing/UnitTest.h"
#include "Core/API/Device.h"
#include "Core/Platform/OS.h"
#include "Core/Program/ProgramManager.h"
#include <chrono>
#include <fstream>

namespace Falcor
{
namespace
{
ProgramDesc cacheDesc(const std::string& extra = "")
{
    ProgramDesc desc;
    desc.addShaderModule("CacheGenerated").addString(
        "#ifndef CACHE_COUNT\n#define CACHE_COUNT 2\n#endif\n"
        "struct CachePayload { uint values[CACHE_COUNT]; uint tail; };\n"
        "RWStructuredBuffer<CachePayload> result;\n"
        "[numthreads(1,1,1)] void main(uint3 i:SV_DispatchThreadID) { result[i.x].tail = i.x; }\n" + extra,
        "Tests/Slang/CacheGenerated.slang");
    desc.csEntry("main");
    return desc;
}

uint32_t cacheArrayCount(const ProgramReflection& reflection)
{
    auto payload = reflection.findType("CachePayload");
    FALCOR_CHECK(payload != nullptr, "CachePayload was not reflected.");
    auto values = payload->findMember("values");
    FALCOR_CHECK(values != nullptr, "CachePayload.values was not reflected.");
    const auto array = values->getType()->asArrayType();
    FALCOR_CHECK(array != nullptr, "CachePayload.values must be an array.");
    // findType() supplies a uniform layout, whose scalar arrays need not be
    // tightly packed. Test the source-dependent array count, not an assumed
    // StructuredBuffer member offset in that different layout context.
    return array->getElementCount();
}

struct CacheFiles
{
    std::filesystem::path directory = std::filesystem::temp_directory_path() / getTempFilePath().filename();
    std::filesystem::path mainFile = directory / "CacheMain.slang";
    std::filesystem::path dependency = directory / "CacheDependency.slang";
    CacheFiles()
    {
        FALCOR_CHECK(std::filesystem::create_directory(directory), "Cannot create cache-test directory {}", directory);
        write(mainFile,
            "import CacheDependency;\nRWStructuredBuffer<CachePayload> result;\n"
            "[numthreads(1,1,1)] void main(uint3 i:SV_DispatchThreadID) { result[i.x].tail = i.x; }\n");
    }
    ~CacheFiles()
    {
        std::error_code error;
        std::filesystem::remove(mainFile, error);
        std::filesystem::remove(dependency, error);
        std::filesystem::remove(directory, error);
    }
    static void write(const std::filesystem::path& path, const std::string& source)
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        stream << source;
        stream.close();
        FALCOR_CHECK(bool(stream), "Cannot write cache-test source {}", path);
    }
    ProgramDesc desc() const
    {
        ProgramDesc value;
        value.addShaderLibrary(mainFile).csEntry("main");
        return value;
    }
};
} // namespace

// These tests need Falcor's Device/ProgramManager but do not dispatch shaders.
GPU_TEST(CompileSessionCacheReuseAndIsolation)
{
    auto device = ctx.getDevice();
    auto first = Program::create(device, cacheDesc());
    auto original = first->getActiveVersion();
    Slang::ComPtr<slang::ISession> session(original->getSlangSession());
    first = nullptr;
    original = nullptr;
    auto repeated = Program::create(device, cacheDesc());
    EXPECT(repeated->getActiveVersion()->getSlangSession() == session.get());

    auto defined = Program::create(device, cacheDesc(), {{"CACHE_COUNT", "5"}});
    auto definedVersion = defined->getActiveVersion();
    EXPECT(definedVersion->getSlangSession() != session.get());
    EXPECT_EQ(cacheArrayCount(*definedVersion->getReflector()), 5u);

    auto argumentDesc = cacheDesc();
    argumentDesc.compilerArguments = {"-DCACHE_COUNT=3"};
    auto argument = Program::create(device, argumentDesc);
    auto argumentVersion = argument->getActiveVersion();
    EXPECT(argumentVersion->getSlangSession() != session.get());
    EXPECT_EQ(cacheArrayCount(*argumentVersion->getReflector()), 3u);

    // Equal generated module names and virtual paths must not hide source changes.
    auto changed = Program::create(device, cacheDesc("struct OnlyInSecondRecipe { uint value; };\n"));
    EXPECT(changed->getActiveVersion()->getSlangSession() != session.get());
    EXPECT(changed->getReflector()->findType("OnlyInSecondRecipe") != nullptr);
    EXPECT(repeated->getReflector()->findType("OnlyInSecondRecipe") == nullptr);

    auto renamedDesc = cacheDesc();
    renamedDesc.entryPointGroups[0].entryPoints[0].exportName = "anotherExport";
    auto renamed = Program::create(device, renamedDesc);
    EXPECT(renamed->getActiveVersion()->getSlangSession() != session.get());

    auto preciseDesc = cacheDesc();
    preciseDesc.compilerFlags = SlangCompilerFlags::FloatingPointModePrecise;
    auto precise = Program::create(device, preciseDesc);
    EXPECT(precise->getActiveVersion()->getSlangSession() != session.get());
}

GPU_TEST(CompileSessionCacheDependencyAndFailureRecovery)
{
    auto device = ctx.getDevice();
    auto manager = device->getProgramManager();
    CacheFiles files;
    CacheFiles::write(files.dependency, "struct CachePayload { uint values[2]; uint tail; };\n");
    auto first = Program::create(device, files.desc());
    auto version = first->getActiveVersion();
    Slang::ComPtr<slang::ISession> session(version->getSlangSession());
    auto oldLayout = version->getReflector();
    first = nullptr;
    // The detached version stays live, but no Program remains in the reload list.

    const auto before = std::filesystem::last_write_time(files.dependency);
    CacheFiles::write(files.dependency, "struct CachePayload { uint values[5]; uint tail; };\n");
    // Equal-sized edit within a second: cache metadata must retain higher precision.
    std::filesystem::last_write_time(files.dependency, before + std::chrono::milliseconds(1));
    auto changed = Program::create(device, files.desc());
    auto changedVersion = changed->getActiveVersion();
    EXPECT(changedVersion->getSlangSession() != session.get());
    EXPECT_EQ(cacheArrayCount(*changedVersion->getReflector()), 5u);
    EXPECT_EQ(cacheArrayCount(*oldLayout), 2u);

    const std::string bad = "struct CachePayload { uint values[5]; uint tail; };\nfloat broken() { return noSuchCacheName; }\n";
    CacheFiles::write(files.dependency, bad);
    auto invalid = Program::create(device, files.desc());
    std::string log;
    EXPECT(manager->createProgramVersion(*invalid, log) == nullptr);
    EXPECT(log.find("noSuchCacheName") != std::string::npos);
    const auto failedTime = std::filesystem::last_write_time(files.dependency);
    std::string repaired = "struct CachePayload { uint values[5]; uint tail; };\nfloat broken() { return 0.f; }\n";
    repaired.resize(bad.size(), ' ');
    CacheFiles::write(files.dependency, repaired);
    std::filesystem::last_write_time(files.dependency, failedTime);
    // Same recipe and failed-file metadata: recovery must not reuse poisoned imports.
    auto recovered = Program::create(device, files.desc());
    EXPECT(recovered->getActiveVersion() != nullptr);
    EXPECT_EQ(cacheArrayCount(*recovered->getReflector()), 5u);

    Slang::ComPtr<slang::ISession> recoveredSession(recovered->getActiveVersion()->getSlangSession());
    CacheFiles::write(files.dependency, "struct CachePayload { uint values[3]; uint tail; };\n");
    EXPECT(manager->reloadAllPrograms());
    EXPECT(recovered->getActiveVersion()->getSlangSession() != recoveredSession.get());
    EXPECT_EQ(cacheArrayCount(*recovered->getReflector()), 3u);
}

GPU_TEST(CompileSessionCacheGlobalInvalidation)
{
    auto device = ctx.getDevice();
    auto manager = device->getProgramManager();
    const auto arguments = manager->getGlobalCompilerArguments();
    const bool debug = manager->isGenerateDebugInfoEnabled();
    const auto flags = manager->getForcedCompilerFlags();
    const auto prelude = manager->getHlslLanguagePrelude();
    struct Restore
    {
        ProgramManager* manager;
        std::vector<std::string> arguments;
        bool debug;
        ProgramManager::ForcedCompilerFlags flags;
        std::string prelude;
        ~Restore()
        {
            manager->setGlobalCompilerArguments(arguments);
            manager->setGenerateDebugInfoEnabled(debug);
            manager->setForcedCompilerFlags(flags);
            manager->setHlslLanguagePrelude(prelude);
            manager->removeGlobalDefines({{"CACHE_GLOBAL_TEST", ""}});
        }
    } restore{manager, arguments, debug, flags, prelude};

    auto program = Program::create(device, cacheDesc());
    Slang::ComPtr<slang::ISession> session(program->getActiveVersion()->getSlangSession());
    manager->setGlobalCompilerArguments(arguments);
    manager->setGenerateDebugInfoEnabled(debug);
    manager->setForcedCompilerFlags(flags);
    manager->setHlslLanguagePrelude(prelude);
    EXPECT(program->getActiveVersion()->getSlangSession() == session.get());

    auto changedArguments = arguments;
    changedArguments.push_back("-DCACHE_GLOBAL_ARG=1");
    manager->setGlobalCompilerArguments(changedArguments);
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    manager->setGenerateDebugInfoEnabled(!debug);
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    manager->setHlslLanguagePrelude(prelude + "\n// CompileSessionCacheGlobalInvalidation\n");
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    auto changedFlags = flags;
    const auto columnMajor = SlangCompilerFlags::MatrixLayoutColumnMajor;
    if (is_set(changedFlags.enabled, columnMajor)) changedFlags.enabled &= ~columnMajor;
    else changedFlags.enabled |= columnMajor;
    changedFlags.disabled &= ~columnMajor;
    manager->setForcedCompilerFlags(changedFlags);
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    manager->addGlobalDefines({{"CACHE_GLOBAL_TEST", "1"}});
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    manager->addGlobalDefines({{"CACHE_GLOBAL_TEST", "1"}});
    EXPECT(program->getActiveVersion()->getSlangSession() == session.get());
    manager->removeGlobalDefines({{"CACHE_GLOBAL_TEST", ""}});
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
    session = program->getActiveVersion()->getSlangSession();
    manager->reloadAllPrograms(true);
    EXPECT(program->getActiveVersion()->getSlangSession() != session.get());
}
} // namespace Falcor
