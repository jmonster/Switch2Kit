cmake_minimum_required(VERSION 3.24)
project(Switch2KitSDLConsumer LANGUAGES C CXX)
enable_testing()
find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
if(NOT EXISTS "${S2K_SDL_SOURCE}/CMakeLists.txt")
  message(FATAL_ERROR "Set S2K_SDL_SOURCE to the pinned SDL3 source checkout")
endif()
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # These portable fixtures intentionally have no desktop video backend.
  set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "" FORCE)
  set(SDL_X11 OFF CACHE BOOL "" FORCE)
  set(SDL_WAYLAND OFF CACHE BOOL "" FORCE)
  set(SDL_ALSA OFF CACHE BOOL "" FORCE)
  set(SDL_PULSEAUDIO OFF CACHE BOOL "" FORCE)
  set(SDL_PIPEWIRE OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory("${S2K_SDL_SOURCE}" sdl EXCLUDE_FROM_ALL)
set(SWITCH2KIT_VERIFY_SDL ON)
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../Integrations/SDL3" switch2kit)
add_test(NAME sdl-version COMMAND Switch2KitSDLVersion ${S2K_EXPECT_SDL_VERSION})
add_custom_target(sdl-version-check ALL DEPENDS Switch2KitSDLVersion)
get_filename_component(_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_fixture "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}S2KSDLFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
set(_args)
set(_fixture_byproducts)
set(_rpath_args)
if(WIN32)
  set(_fixture_import "${CMAKE_CURRENT_BINARY_DIR}/S2KSDLFixture.lib")
  list(APPEND _fixture_byproducts "${_fixture_import}")
  list(APPEND _args -Xlinker "/IMPLIB:${_fixture_import}")
else()
  list(APPEND _rpath_args -Xlinker -rpath -Xlinker "${SWITCH2KIT_C_BINARY_DIR}")
endif()
if(APPLE)
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE _sdk OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  execute_process(COMMAND uname -m OUTPUT_VARIABLE _arch OUTPUT_STRIP_TRAILING_WHITESPACE)
  list(APPEND _args -sdk "${_sdk}" -target "${_arch}-apple-macosx15.0")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND _args -Xlinker -soname -Xlinker "${CMAKE_SHARED_LIBRARY_PREFIX}S2KSDLFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()
add_custom_command(OUTPUT "${_fixture}"
  BYPRODUCTS ${_fixture_byproducts}
  COMMAND "${Python3_EXECUTABLE}" "${_root}/tests/support/compile-fixture.py"
    --description "${SWITCH2KIT_C_BINARY_DIR}/description.json"
    --compiler "${SWITCH2KIT_SWIFTC}" -- -swift-version 6 -warnings-as-errors -emit-library
    -module-name S2KSDLFixture ${_args}
    -I "${SWITCH2KIT_C_BINARY_DIR}/Modules" -I "${_root}/Sources/Switch2KitCABI/include"
    -L "${SWITCH2KIT_C_BINARY_DIR}" -lSwitch2KitC
    ${_rpath_args}
    "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift" -o "${_fixture}"
  DEPENDS Switch2KitCBuild "${_root}/tests/support/compile-fixture.py" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift" VERBATIM)
add_custom_target(S2KSDLFixtureBuild DEPENDS "${_fixture}")
add_library(S2KSDLFixture SHARED IMPORTED GLOBAL)
set_target_properties(S2KSDLFixture PROPERTIES IMPORTED_LOCATION "${_fixture}")
if(WIN32)
  set_target_properties(S2KSDLFixture PROPERTIES IMPORTED_IMPLIB "${_fixture_import}")
endif()
add_dependencies(S2KSDLFixture S2KSDLFixtureBuild)
add_executable(sdl-inprocess main.cpp)
target_compile_features(sdl-inprocess PRIVATE cxx_std_17)
if(MSVC)
  set(_test_options /W4 /UNDEBUG)
  set(_force_include "/FI${CMAKE_CURRENT_LIST_DIR}/Clock.hpp")
else()
  set(_test_options -Wall -Wextra -Werror -UNDEBUG)
  set(_force_include -include "${CMAKE_CURRENT_LIST_DIR}/Clock.hpp")
  target_compile_options(Switch2KitSDL3 PRIVATE -Wall -Wextra -Werror)
endif()
target_compile_options(sdl-inprocess PRIVATE ${_test_options})
target_link_libraries(sdl-inprocess PRIVATE Switch2Kit::SDL3 S2KSDLFixture)
set_property(TARGET sdl-inprocess APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME sdl-inprocess COMMAND sdl-inprocess)
set_tests_properties(sdl-inprocess PROPERTIES TIMEOUT 45)

# Compile the SAME adapter source with test-only clock symbols. Do not
# replace SDL, the Swift facade, or the engine, and do not add a public test API.
# The normal Switch2Kit::SDL3 target and sdl-inprocess still use production clocks.
add_library(S2KSDLClockedAdapter STATIC "${_root}/Integrations/SDL3/Switch2KitSDL3.cpp")
target_compile_features(S2KSDLClockedAdapter PUBLIC cxx_std_17)
# Mirror the production target's private compile policy as well as its source.
# In particular, the host fixture disables exceptions globally but the adapter
# constructor still requires its existing target-local -fexceptions override.
target_compile_options(S2KSDLClockedAdapter PRIVATE
  "$<TARGET_PROPERTY:Switch2KitSDL3,COMPILE_OPTIONS>"
  ${_force_include})
target_compile_definitions(S2KSDLClockedAdapter PRIVATE
  SDL_GetTicksNS=s2k_test_ticks_ns s2k_monotonic_time=s2k_test_monotonic_time
  S2K_MOTION_CONTINUOUS_NS=s2k_test_continuous_ns)
target_include_directories(S2KSDLClockedAdapter PUBLIC "${_root}/Integrations/SDL3")
target_link_libraries(S2KSDLClockedAdapter PUBLIC Switch2Kit::C SDL3::SDL3)
add_executable(sdl-motion motion.cpp Clock.cpp)
target_compile_features(sdl-motion PRIVATE cxx_std_17)
target_compile_options(sdl-motion PRIVATE ${_test_options})
target_link_libraries(sdl-motion PRIVATE S2KSDLClockedAdapter S2KSDLFixture)
set_property(TARGET sdl-motion APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME sdl-motion COMMAND sdl-motion)
set_tests_properties(sdl-motion PROPERTIES TIMEOUT 45)

if(WIN32)
  foreach(_consumer sdl-inprocess sdl-motion)
    switch2kit_embed_windows(${_consumer})
    add_custom_command(TARGET ${_consumer} POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_fixture}" "$<TARGET_FILE_DIR:${_consumer}>" VERBATIM)
  endforeach()
endif()
