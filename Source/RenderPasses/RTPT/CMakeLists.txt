add_plugin(RTPT)

target_sources(RTPT PRIVATE
    RTPT.cpp
    RTPT.h
    RTPTStages.cpp
    RTPTDirectLighting.cpp
    RTPTReGIR.cpp
    ReGIR/RTPTReGIRResources.slang
    ReGIR/RTPTReGIRGrid.slang
    ReGIR/RTPTReGIRCulling.slang
    ReGIR/RTPTReGIRBuild.cs.slang
    ReGIR/RTPTReGIRCellLists.slang
    ReGIR/RTPTReGIRUpdate.cs.slang
    ReGIR/RTPTReGIRTransport.slang
    RTPTDIReuse.cpp
    RTPTPG.h
    RTPTPG.cpp
    RTPTPGAsync.cpp
    RTPTNativePGTrain.h
    RTPTNativePGTrain.cpp
    RTPTGrid.slang
    RTPTPGTypes.slang
    RTPTPG.slang
    RTPTSampling.slang
    RTPTPGPrepare.cs.slang
    RTPTPGTrain.cs.slang
    RTPTSparseUpdate.cs.slang
    RTPTParams.slangh
    RTPT.cs.slang
    RTPTIntegrator.slang
    RTPTLighting.slang
    RTPTNRD.slang
    GRIS/RTPTGRISGenerate.cs.slang
    GRIS/RTPTGRISGenerate.slang
    GRIS/RTPTGRISPublishHistory.cs.slang
    GRIS/RTPTGRISReuse.slang
    GRIS/RTPTGRISShade.cs.slang
    GRIS/RTPTGRISSpatial.cs.slang
    GRIS/RTPTGRISSpatial.slang
    GRIS/RTPTGRISSupport.slang
    GRIS/RTPTGRISTemporal.cs.slang
    GRIS/RTPTGRISTemporal.slang
    GRIS/RTPTGRISTypes.slang
    GRIS/RTPTGRISTerminalPicker.slang
    PrimarySurface/RTPTCamera.slang
    PrimarySurface/RTPTPrimarySurfaceTypes.slang
    PrimarySurface/RTPTPrimarySurface.slang
    PrimarySurface/RTPTPrimarySurface.cs.slang
    Signal/RTPTSignalTypes.slang
    Signal/RTPTSignalResolve.slang
    Signal/RTPTFinalSignalResolve.cs.slang
    DirectLighting/RTPTDITypes.slang
    DirectLighting/RTPTDIResources.slang
    ReSTIRDI/RTPTDIBridge.slangh
    ReSTIRDI/RTPTDISDK.slangh
    ReSTIRDI/RTPTDIInitial.cs.slang
    ReSTIRDI/RTPTDIShade.cs.slang
    ReSTIRDI/RTPTDIReprojection.slangh
    ReSTIRDI/RTPTDIReuseSDK.slangh
    ReSTIRDI/RTPTDITemporal.cs.slang
    ReSTIRDI/RTPTDISpatial.cs.slang
    RTPTSharc.slang
    RTPTSharcResolve.cs.slang
)

target_link_libraries(RTPT PRIVATE rtxdi)

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
