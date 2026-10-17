add_plugin(RTPT)

target_sources(RTPT PRIVATE
    RTPT.cpp
    RTPT.h
    RTPT.cs.slang
    RTPTIntegrator.slang
    RTPTLighting.slang
    RTPTNRD.slang
    RTPTSharc.slang
    RTPTSharcUpdate.cs.slang
    RTPTSharcResolve.cs.slang
)

set(sharc_sdk_files
    ThirdParty/SHARC/HashGridCommon.h
    ThirdParty/SHARC/HashGridTypes.h
    ThirdParty/SHARC/SharcCommon.h
    ThirdParty/SHARC/SharcTypes.h
    ThirdParty/SHARC/License.md
    ThirdParty/SHARC/SOURCE.txt
)
target_sources(RTPT PRIVATE ${sharc_sdk_files})
foreach(file ${sharc_sdk_files})
    add_custom_command(
        OUTPUT ${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/RTPT/${file}
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/${file}
            ${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/RTPT/${file}
        MAIN_DEPENDENCY ${CMAKE_CURRENT_SOURCE_DIR}/${file}
        COMMENT "RTPT: Copying SHaRC SDK ${file}"
    )
endforeach()

target_copy_shaders(RTPT RenderPasses/RTPT)
target_source_group(RTPT "RenderPasses")
