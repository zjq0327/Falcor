add_plugin(RTPT)

target_sources(RTPT PRIVATE
    RTPT.cpp
    RTPT.h
    RTPT.cs.slang
    RTPTIntegrator.slang
    RTPTLighting.slang
    RTPTNRD.slang
)

target_copy_shaders(RTPT RenderPasses/RTPT)
target_source_group(RTPT "RenderPasses")
