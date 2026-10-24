cmake_minimum_required(VERSION 3.19)

set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Universal binary")
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0 CACHE STRING "Minimum macOS version")

project(Zerhacker VERSION 0.9.0 LANGUAGES C CXX OBJCXX)

option(ZERHACKER_BUILD_TESTS "Build the offline DSP/UI test" ON)
set(VST3_SDK "" CACHE PATH "Path to a local VST3 SDK checkout (downloaded automatically if empty)")

# --- Steinberg VST3 SDK (MIT licensed) ---------------------------------------
if(NOT VST3_SDK)
    include(FetchContent)
    FetchContent_Declare(vst3sdk
        GIT_REPOSITORY https://github.com/steinbergmedia/vst3sdk.git
        GIT_TAG        master
        GIT_SHALLOW    TRUE
        GIT_SUBMODULES base pluginterfaces public.sdk cmake)
    FetchContent_GetProperties(vst3sdk)
    if(NOT vst3sdk_POPULATED)
        FetchContent_Populate(vst3sdk)
    endif()
    set(VST3_SDK ${vst3sdk_SOURCE_DIR})
endif()

# The SDK checks the Xcode version; with only the Command Line Tools installed there is none.
execute_process(COMMAND xcodebuild -version RESULT_VARIABLE XCODE_MISSING OUTPUT_QUIET ERROR_QUIET)
if(XCODE_MISSING)
    set(ENV{XCODE_VERSION} 16.0)
    set(XCODE_VERSION 16.0)
endif()

set(SMTG_ENABLE_VSTGUI_SUPPORT OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VST3_PLUGIN_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VST3_HOSTING_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ADD_VST3_PLUGINS_SAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ADD_VST3_HOSTING_SAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_CREATE_PLUGIN_LINK OFF CACHE BOOL "" FORCE)

add_subdirectory(${VST3_SDK} ${CMAKE_BINARY_DIR}/vst3sdk)
smtg_enable_vst3_sdk()

# --- Plug-in ------------------------------------------------------------------
smtg_add_vst3plugin(Zerhacker
    src/plugin.cpp
    src/editor.mm
    ${VST3_SDK}/public.sdk/source/vst/vstsinglecomponenteffect.cpp)
target_include_directories(Zerhacker PRIVATE src)
target_link_libraries(Zerhacker PRIVATE sdk "-framework Cocoa" "-framework QuartzCore")
set_source_files_properties(src/editor.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
smtg_target_set_bundle(Zerhacker BUNDLE_IDENTIFIER io.github.zerhacker COMPANY_NAME "Zerhacker")

# --- Offline test ---------------------------------------------------------------
if(ZERHACKER_BUILD_TESTS)
    enable_testing()
    add_executable(zerhacker_tests
        tests/offline_test.mm
        src/editor.mm
        ${VST3_SDK}/public.sdk/source/vst/vstsinglecomponenteffect.cpp
        ${VST3_SDK}/public.sdk/source/common/memorystream.cpp)
    target_include_directories(zerhacker_tests PRIVATE src ${VST3_SDK})
    target_compile_definitions(zerhacker_tests PRIVATE $<IF:$<CONFIG:Debug>,DEVELOPMENT=1,RELEASE=1>)
    target_compile_options(zerhacker_tests PRIVATE -fobjc-arc)
    target_link_libraries(zerhacker_tests PRIVATE sdk sdk_common base pluginterfaces "-framework Cocoa" "-framework QuartzCore")
    add_test(NAME offline_test COMMAND zerhacker_tests WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
endif()
