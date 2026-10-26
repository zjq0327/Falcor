add_plugin(RTPT)

target_sources(RTPT PRIVATE
    RTPT.cpp
    RTPT.h
    VXPG/RTPTVXPG.h
    VXPG/RTPTVXPG.cpp
    VXPG/RTPTVXPGResources.cpp
    VXPG/RTPTVXPGSettings.cpp
    VXPG/RTPTVXPGDiagnostics.cpp
    RTPTCamera.slang
    VXPG/RTPTVXPGMath.slang
    VXPG/RTPTVXPGGeometry.slang
    VXPG/RTPTVXPGTypes.slang
    VXPG/RTPTVXPGDiagnostics.slang
    VXPG/RTPTVXPGHistory.slang
    VXPG/RTPTVXPGHistoryResolve.slang
    VXPG/RTPTVXPGGrid.slang
    VXPG/RTPTVXPGDebug.cs.slang
    VXPG/RTPTVXPGPrimary.cs.slang
    VXPG/RTPTVXPGTraining.slang
    VXPG/RTPTVXPGLocal.cs.slang
    VXPG/RTPTVXPGObservation.slang
    VXPG/RTPTVXPGIncremental.cs.slang
    VXPG/RTPTVXPGPrepare.cs.slang
    VXPG/RTPTVXPGSampling.slang
    VXPG/RTPTVXPGIntegrator.slang
    VXPG/RTPTVXPGDistribution.slang
    VXPG/RTPTVXPGVisibility.cs.slang
    VXPG/RTPTVXPGTree.cs.slang
    RTPTSparseUpdate.cs.slang
    RTPT.cs.slang
    RTPTIntegrator.slang
    RTPTLighting.slang
    RTPTNRD.slang
    RTPTSharc.slang
    RTPTSharcPairCommon.slang
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
