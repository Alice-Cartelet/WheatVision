cmake_minimum_required(VERSION 3.21)
project(WheatVision VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.5 REQUIRED COMPONENTS Widgets)

set(ONNXRUNTIME_ROOT "" CACHE PATH "ONNX Runtime C++ SDK directory")
set(onnxruntime_hints "${ONNXRUNTIME_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/.cpp-deps/ort")
find_path(ONNXRUNTIME_INCLUDE_DIR onnxruntime_cxx_api.h
    HINTS ${onnxruntime_hints} PATH_SUFFIXES include include/onnxruntime)
if(NOT ONNXRUNTIME_INCLUDE_DIR)
    message(FATAL_ERROR "Set ONNXRUNTIME_ROOT to an extracted ONNX Runtime C++ SDK.")
endif()

qt_add_executable(WheatVision WIN32
    src/main.cpp src/window.cpp src/window.h src/batch.cpp src/batch.h src/detector.cpp src/detector.h)
target_include_directories(WheatVision SYSTEM PRIVATE "${ONNXRUNTIME_INCLUDE_DIR}")
target_link_libraries(WheatVision PRIVATE Qt6::Widgets)
target_compile_options(WheatVision PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
qt_add_resources(WheatVision "wheatvision_assets" PREFIX "/" FILES style.qss)

add_custom_command(TARGET WheatVision POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:WheatVision>/models"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/models/wheat-qh.onnx"
        "$<TARGET_FILE_DIR:WheatVision>/models/wheat-qh.onnx")
if(WIN32)
    find_file(ONNXRUNTIME_DLL onnxruntime.dll
        HINTS ${onnxruntime_hints} PATH_SUFFIXES lib bin runtimes/win-x64/native)
    if(NOT ONNXRUNTIME_DLL)
        message(FATAL_ERROR "The Windows ONNX Runtime SDK must contain onnxruntime.dll.")
    endif()
    add_custom_command(TARGET WheatVision POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${ONNXRUNTIME_DLL}" "$<TARGET_FILE_DIR:WheatVision>")
endif()
