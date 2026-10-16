# =============================================================================
#  NFS Carbon Recompiled - iOS app (arm64, iOS 16+)
#
#  Configure with the preset in ios/CMakePresets.json:
#      cmake --preset ios
#      cmake --build --preset ios                 the app
#      cmake --build --preset ios --target ipa    ios/build/NFSCarbon.ipa, for LiveContainer
#
#  Builds:
#    librexruntime.dylib     the patched SDK (tools/prepare_sdk.py)
#    librexgpu-xenos.dylib   the GPU plugin, which the SDK loads with dlopen
#    NFSCarbon               the app executable
#
#  and packages them into NFSCarbon.app with MoltenVK.framework:
#    NFSCarbon.app/
#      NFSCarbon, Info.plist
#      Frameworks/librexruntime.dylib
#      Frameworks/librexgpu-xenos.dylib
#      Frameworks/MoltenVK.framework
# =============================================================================

cmake_minimum_required(VERSION 3.25)
project(nfscarbon_ios LANGUAGES C CXX OBJC OBJCXX ASM)

if(NOT IOS)
    message(FATAL_ERROR "This is for iOS: configure with  cmake --preset ios")
endif()

set(NFSCARBON_REPO "${CMAKE_CURRENT_SOURCE_DIR}/.." CACHE PATH "NFS Carbon Recompiled repository root")
set(NFSCARBON_SDK "${NFSCARBON_REPO}/../rexglue-sdk-ios" CACHE PATH
    "ReXGlue SDK prepared for iOS (tools/prepare_sdk.py)")
set(NFSCARBON_BUNDLE_ID "com.antigravity.nfscarbonios" CACHE STRING "App bundle identifier")
set(NFSCARBON_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated/default" CACHE PATH
    "Generated code for iOS (tools/generate_code.py)")
set(NFSCARBON_JOBS_RECOMP "4" CACHE STRING "Generated files compiled at once")
get_filename_component(NFSCARBON_REPO "${NFSCARBON_REPO}" ABSOLUTE)
get_filename_component(NFSCARBON_SDK "${NFSCARBON_SDK}" ABSOLUTE)

# The SDK must be prepared for iOS with MoltenVK ready
set(_mvk_marker "${NFSCARBON_SDK}/.nfsmw-ios/MoltenVK/v1.4.1.ready")
if(NOT EXISTS "${_mvk_marker}")
    set(_mvk_marker "${NFSCARBON_SDK}/.nfscarbon-ios/MoltenVK/v1.4.1.ready")
endif()
if(NOT EXISTS "${_mvk_marker}")
    message(FATAL_ERROR
        "No SDK prepared for iOS in:\n  ${NFSCARBON_SDK}\n"
        "Run first:  python3 tools/prepare_sdk.py")
endif()
file(READ "${NFSCARBON_SDK}/include/rex/platform.h" _platform_h)
if(NOT _platform_h MATCHES "REX_PLATFORM_IOS")
    message(FATAL_ERROR "The SDK lacks the iOS patches. Run: python3 tools/prepare_sdk.py")
endif()
file(STRINGS "${_mvk_marker}" _mvk_rel LIMIT_COUNT 1)
set(NFSCARBON_MOLTENVK_FW "${NFSCARBON_SDK}/.nfsmw-ios/MoltenVK/${_mvk_rel}/ios-arm64/MoltenVK.framework")
if(NOT EXISTS "${NFSCARBON_MOLTENVK_FW}/MoltenVK")
    set(NFSCARBON_MOLTENVK_FW "${NFSCARBON_SDK}/.nfscarbon-ios/MoltenVK/${_mvk_rel}/ios-arm64/MoltenVK.framework")
endif()
if(NOT EXISTS "${NFSCARBON_MOLTENVK_FW}/MoltenVK")
    message(FATAL_ERROR "Cannot find MoltenVK.framework in ${NFSCARBON_MOLTENVK_FW}")
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_BUILD_WITH_INSTALL_RPATH ON)

set(REXGLUE_ENABLE_TRACY OFF CACHE BOOL "" FORCE)
set(REXGLUE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(REXGLUE_USE_VULKAN ON CACHE BOOL "" FORCE)
set(REXGLUE_USE_D3D12 OFF CACHE BOOL "" FORCE)
set(REXGLUE_ENABLE_DESKTOP_SDL_BACKENDS OFF CACHE BOOL "" FORCE)

add_compile_definitions(
    $<$<NOT:$<STREQUAL:$<TARGET_PROPERTY:NAME>,nfscarbon_recomp>>:REX_HAS_FIDELITYFX_SDK=1>)

add_subdirectory("${NFSCARBON_SDK}" rexglue-sdk)

add_library(nfscarbon_headers INTERFACE)
target_include_directories(nfscarbon_headers INTERFACE
    $<TARGET_PROPERTY:imgui,INTERFACE_INCLUDE_DIRECTORIES>)
target_link_libraries(nfscarbon_headers INTERFACE
    renderdoc
    Vulkan::Headers
    GPUOpen::VulkanMemoryAllocator
    spirv-tools-headers)

# -----------------------------------------------------------------------------
#  Generated game code, if any
# -----------------------------------------------------------------------------
set(NFSCARBON_WITH_GAME OFF)
if(EXISTS "${NFSCARBON_GEN_DIR}/sources.cmake")
    set(NFSCARBON_WITH_GAME ON)
    include("${NFSCARBON_GEN_DIR}/sources.cmake")

    add_library(nfscarbon_recomp STATIC ${GENERATED_SOURCES})
    target_include_directories(nfscarbon_recomp PRIVATE
        "${NFSCARBON_REPO}/src"
        "${NFSCARBON_GEN_DIR}")
    target_link_libraries(nfscarbon_recomp PUBLIC rex::runtime nfscarbon_headers)
    rexglue_apply_target_settings(nfscarbon_recomp)
    if(EXISTS "${NFSCARBON_GEN_DIR}/nfscarbon_pch.h")
        target_precompile_headers(nfscarbon_recomp PRIVATE "${NFSCARBON_GEN_DIR}/nfscarbon_pch.h")
    endif()
    target_compile_options(nfscarbon_recomp PRIVATE -gline-tables-only -Wno-unused-variable)
    set_property(GLOBAL APPEND PROPERTY JOB_POOLS recomp=${NFSCARBON_JOBS_RECOMP})
    set_target_properties(nfscarbon_recomp PROPERTIES JOB_POOL_COMPILE recomp)
    message(STATUS "NFSCarbon: compiling with game code (${NFSCARBON_GEN_DIR})")
else()
    message(STATUS "NFSCarbon: no generated code in ${NFSCARBON_GEN_DIR}: probe only. "
                   "To generate the game code: python3 tools/generate_code.py")
endif()

# -----------------------------------------------------------------------------
#  The app executable
# -----------------------------------------------------------------------------
set(NFSCARBON_VERSION "0.3.3")
set(NFSCARBON_VERSION_CODE "4")
set(NFSCARBON_DISPLAY_NAME "NFS Carbon")
set(NFSCARBON_IOS_MIN "${CMAKE_OSX_DEPLOYMENT_TARGET}")
set(NFSCARBON_EXECUTABLE "NFSCarbon")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

add_executable(nfscarbon MACOSX_BUNDLE
    src/ios_main.mm
    src/launcher.mm
    src/save_manager.mm
    src/boot_trace.cpp
    src/probe.cpp
    src/probe_apple.mm
    src/probe_memory.cpp
    src/touch_controls.mm
    src/battery.mm
    src/display_rate.mm
    src/lifecycle.mm
    src/memory_report.mm
    src/gpu_capture.mm
    src/achievements_export.cpp
    src/audio/coreaudio_driver.mm)

set_target_properties(nfscarbon PROPERTIES
    OUTPUT_NAME "${NFSCARBON_EXECUTABLE}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    INSTALL_RPATH "@loader_path/Frameworks")

target_compile_options(nfscarbon PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_include_directories(nfscarbon PRIVATE
    "${NFSCARBON_SDK}/include"
    "${NFSCARBON_REPO}/src")

target_link_libraries(nfscarbon PRIVATE rex::runtime nfscarbon_headers
    "-framework Foundation" "-framework UIKit" "-framework Metal" "-framework MetalFX"
    "-framework QuartzCore" "-framework CoreImage" "-framework UniformTypeIdentifiers"
    "-framework AudioToolbox" "-framework AVFoundation" "-framework GameController")

target_compile_definitions(nfscarbon PRIVATE
    REXGLUE_BUILD_CONFIG="$<CONFIG>"
    NFSCARBON_WITH_GAME=$<BOOL:${NFSCARBON_WITH_GAME}>
    NFSMW_WITH_GAME=$<BOOL:${NFSCARBON_WITH_GAME}>
    NFSMW_GAME_LANGUAGE="1"
    NFSMW_GAME_COUNTRY="103"
    NFSCARBON_GAME_LANGUAGE="1"
    NFSCARBON_GAME_COUNTRY="103")

if(NFSCARBON_WITH_GAME)
    # Carbon engine hooks & runtime extensions
    set(NFSCARBON_GAME_SOURCES
        "${NFSCARBON_REPO}/src/render_mode_hook.cpp"
        "${NFSCARBON_REPO}/src/ring_wait_hook.cpp"
        "${NFSCARBON_REPO}/src/dispatch_tolerance.cpp"
        "${NFSCARBON_SDK}/src/ui/rex_app.cpp")

    target_sources(nfscarbon PRIVATE ${NFSCARBON_GAME_SOURCES})
    target_include_directories(nfscarbon PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${NFSCARBON_REPO}/src"
        "${NFSCARBON_GEN_DIR}"
        "${NFSCARBON_SDK}/src/ui")
    target_link_libraries(nfscarbon PRIVATE nfscarbon_recomp)
endif()

# The Xenos GPU plugin is loaded via dlopen at runtime
add_dependencies(nfscarbon rexgpu-xenos)

# -----------------------------------------------------------------------------
#  Packaging: the libraries into Frameworks/, and signing
# -----------------------------------------------------------------------------
set(_app "$<TARGET_BUNDLE_DIR:nfscarbon>")
set(_fw "${_app}/Frameworks")

add_custom_target(nfscarbon_package ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_fw}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:rexruntime>" "$<TARGET_FILE:rexgpu-xenos>" "${_fw}/"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${NFSCARBON_MOLTENVK_FW}" "${_fw}/MoltenVK.framework"
    COMMAND /bin/sh -c "xcrun actool '${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets' --compile '${_app}' --platform iphoneos --minimum-deployment-target '${CMAKE_OSX_DEPLOYMENT_TARGET}' --target-device iphone --target-device ipad --app-icon AppIcon --output-partial-info-plist '${CMAKE_CURRENT_BINARY_DIR}/actool-partial.plist' --output-format human-readable-text || true"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
            "${_app}/AppIcon.png"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets/AppIcon.appiconset/AppIcon60x60@2x.png"
            "${_app}/AppIcon60x60@2x.png"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/Assets.xcassets/AppIcon.appiconset/AppIcon76x76@2x~ipad.png"
            "${_app}/AppIcon76x76@2x~ipad.png"
    COMMAND xattr -cr "${_app}"
    COMMAND codesign --force --sign - --timestamp=none "${_fw}/MoltenVK.framework"
    COMMAND codesign --force --sign - --timestamp=none "${_fw}/$<TARGET_FILE_NAME:rexruntime>"
    COMMAND codesign --force --sign - --timestamp=none "${_fw}/$<TARGET_FILE_NAME:rexgpu-xenos>"
    COMMAND codesign --force --sign - --timestamp=none
            --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/nfscarbon.entitlements" "${_app}"
    COMMENT "NFSCarbon: packaging and signing NFSCarbon.app"
    VERBATIM)
add_dependencies(nfscarbon_package nfscarbon rexruntime rexgpu-xenos)

# -----------------------------------------------------------------------------
#  Target: ipa -> generates NFSCarbon.ipa for sideloading
# -----------------------------------------------------------------------------
add_custom_target(ipa
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_CURRENT_BINARY_DIR}/ipa"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/ipa/Payload"
    COMMAND ditto "${_app}" "${CMAKE_CURRENT_BINARY_DIR}/ipa/Payload/NFSCarbon.app"
    COMMAND ${CMAKE_COMMAND} -E rm -f "${CMAKE_CURRENT_BINARY_DIR}/NFSCarbon.ipa"
    COMMAND ${CMAKE_COMMAND} -E chdir "${CMAKE_CURRENT_BINARY_DIR}/ipa"
            ditto -c -k --sequesterRsrc --keepParent Payload "${CMAKE_CURRENT_BINARY_DIR}/NFSCarbon.ipa"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/build"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_BINARY_DIR}/NFSCarbon.ipa"
            "${CMAKE_CURRENT_SOURCE_DIR}/build/NFSCarbon.ipa"
    COMMENT "NFSCarbon: Created NFSCarbon.ipa"
    VERBATIM)
add_dependencies(ipa nfscarbon_package)
