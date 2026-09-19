# NRC is optional. A missing SDK must never remove the existing MyPT plugin.
option(FALCOR_ENABLE_NRC "Build the optional NVIDIA NRC 0.14 D3D12 backend" ON)
set(NRC_SDK_ROOT "${CMAKE_SOURCE_DIR}/external/nrc-sdk" CACHE PATH "NVIDIA NRC 0.14 SDK root (Include, Lib, Bin)")

function(target_enable_nrc target)
    set(nrc_available OFF)
    if(FALCOR_ENABLE_NRC AND WIN32 AND MSVC AND FALCOR_HAS_D3D12)
        if(EXISTS "${NRC_SDK_ROOT}/Include/NrcD3d12.h" AND EXISTS "${NRC_SDK_ROOT}/Lib/NRC_D3D12.lib")
            file(STRINGS "${NRC_SDK_ROOT}/Include/NrcCommon.h" nrc_major REGEX "^#define NRC_VERSION_MAJOR ")
            file(STRINGS "${NRC_SDK_ROOT}/Include/NrcCommon.h" nrc_minor REGEX "^#define NRC_VERSION_MINOR ")
            if(nrc_major STREQUAL "#define NRC_VERSION_MAJOR 0" AND nrc_minor STREQUAL "#define NRC_VERSION_MINOR 14")
                set(nrc_available ON)
            else()
                message(WARNING "NRC headers are not version 0.14; the optional NRC backend is disabled")
            endif()
        else()
            message(STATUS "NRC SDK headers/import library not found; PT and ReSTIR remain available")
        endif()
    endif()

    if(nrc_available)
        target_compile_definitions(${target} PRIVATE FALCOR_HAS_NRC=1
            FALCOR_NRC_RUNTIME_DIR="${NRC_SDK_ROOT}/Bin"
            FALCOR_NRC_SDK_INCLUDE_DIR="${NRC_SDK_ROOT}/Include")
        target_include_directories(${target} PRIVATE "${NRC_SDK_ROOT}/Include")
        target_link_libraries(${target} PRIVATE "${NRC_SDK_ROOT}/Lib/NRC_D3D12.lib" delayimp)
        target_link_options(${target} PRIVATE /DELAYLOAD:NRC_D3D12.dll)
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_OUTPUT_DIRECTORY}/nrc"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/MyPT/NRC/SDK"
            COMMAND ${CMAKE_COMMAND} -E copy_directory "${NRC_SDK_ROOT}/Include"
                "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/MyPT/NRC/SDK"
            VERBATIM)
        foreach(dll NRC_D3D12.dll cudart64_12.dll nvrtc-builtins64_128.dll nvrtc64_120_0.dll)
            if(EXISTS "${NRC_SDK_ROOT}/Bin/${dll}")
                add_custom_command(TARGET ${target} POST_BUILD
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${NRC_SDK_ROOT}/Bin/${dll}" "${FALCOR_OUTPUT_DIRECTORY}/nrc/${dll}"
                    VERBATIM)
            else()
                message(STATUS "Optional NRC runtime missing: ${dll}; NRC will report unavailable at runtime")
            endif()
        endforeach()
        message(STATUS "NRC 0.14 enabled with delay loading: ${NRC_SDK_ROOT}")
    else()
        target_compile_definitions(${target} PRIVATE FALCOR_HAS_NRC=0)
    endif()
endfunction()
