cmake_minimum_required(VERSION 3.25)
project(nfscarbon LANGUAGES C CXX OBJC OBJCXX ASM)

if(IOS OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_subdirectory(ios)
else()
    set(CMAKE_CXX_STANDARD 23)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)

    # Core Carbon source files
    set(NFSCARBON_SOURCES
        src/main.cpp
        src/dispatch_tolerance.cpp
        src/render_mode_hook.cpp
        src/ring_wait_hook.cpp
    )

    if(WIN32)
        list(APPEND NFSCARBON_SOURCES src/crash_diag.cpp)
        add_executable(nfscarbon WIN32 ${NFSCARBON_SOURCES})
        target_link_libraries(nfscarbon PRIVATE dbghelp)
        target_link_options(nfscarbon PRIVATE "LINKER:/force:multiple")
    else()
        add_executable(nfscarbon ${NFSCARBON_SOURCES})
    endif()

    option(NFSCARBON_BUILD_CARBON_GPU "Build the rexgpu-carbon native renderer plugin" ON)
    if(NFSCARBON_BUILD_CARBON_GPU)
        add_subdirectory(renderer)
        add_dependencies(nfscarbon rexgpu-carbon)
    endif()
endif()
