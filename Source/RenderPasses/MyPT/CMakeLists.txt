add_plugin(MyPT)

target_sources(MyPT PRIVATE
    MyPT.cpp
    MyPT.h
    MyPTGRIS.cpp
    MyPT.rt.slang
    MyPTCommon.slang
    GRIS/Params.slang
    GRIS/PathState.slang
    GRIS/PathReservoir.slang
    GRIS/PathBuilder.slang
    GRIS/BSDF.slang
    GRIS/PathTracer.slang
    GRIS/Shift.slang
    GRIS/ReuseHelpers.slang
    GRIS/SpatialPathRetrace.cs.slang
    GRIS/TemporalPathRetrace.cs.slang
    GRIS/ValidateShift.cs.slang
    GRIS/SpatialReuse.cs.slang
    GRIS/TemporalReuse.cs.slang
    GRIS/GeneratePaths.cs.slang
    GRIS/TracePaths.cs.slang
    GRIS/Resolve.cs.slang
)

target_copy_shaders(MyPT RenderPasses/MyPT)

target_source_group(MyPT "RenderPasses")
