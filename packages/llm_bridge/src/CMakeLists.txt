# Builds llm_bridge as ONE shared library with llama.cpp and ggml linked in
# statically, so Flutter has a single file per ABI to bundle.
#
# Called by hook/build.dart, which passes LLB_LLAMA_CPP_DIR (the pinned
# checkout) and the platform toolchain flags. Can also be used by hand:
#   cmake -S src -B build -DLLB_LLAMA_CPP_DIR=/path/to/llama.cpp
cmake_minimum_required(VERSION 3.18)
project(llm_bridge LANGUAGES C CXX)

if(NOT LLB_LLAMA_CPP_DIR)
  message(FATAL_ERROR "Set -DLLB_LLAMA_CPP_DIR=<llama.cpp checkout>")
endif()
set(LLB_LLAMA_CPP_TAG "unknown" CACHE STRING "llama.cpp tag, for llb_version()")

set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# Only the library. No tools, tests, server, curl/openssl, web UI.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
# CPU only, with ggml's own thread pool: no OpenMP runtime to bundle, no GPU
# driver to trust. The same model then runs the same way on both phones.
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_RPC OFF CACHE BOOL "" FORCE)

add_subdirectory("${LLB_LLAMA_CPP_DIR}" llama.cpp EXCLUDE_FROM_ALL)

add_library(llm_bridge SHARED llm_bridge.cpp)
target_link_libraries(llm_bridge PRIVATE llama)
target_compile_definitions(llm_bridge PRIVATE LLB_LLAMA_CPP_TAG="${LLB_LLAMA_CPP_TAG}")
target_include_directories(llm_bridge PRIVATE "${LLB_LLAMA_CPP_DIR}/include" "${LLB_LLAMA_CPP_DIR}/ggml/include")

# Keep the file small and the exported surface to the llb_* functions.
if(APPLE)
  target_link_options(llm_bridge PRIVATE -Wl,-dead_strip)
elseif(UNIX)
  target_link_options(llm_bridge PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)
endif()
if(ANDROID)
  # Android 15+ devices may use 16 KB pages; Google Play requires aligned libs.
  target_link_options(llm_bridge PRIVATE -Wl,-z,max-page-size=16384)
endif()

# One predictable place for the hook to pick the result up from.
set_target_properties(llm_bridge PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
