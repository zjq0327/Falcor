add_plugin(MyPT)

target_sources(MyPT PRIVATE
    MyPT.cpp
    MyPT.h
    MyPT.rt.slang
)

target_copy_shaders(MyPT RenderPasses/MyPT)

target_source_group(MyPT "RenderPasses")
