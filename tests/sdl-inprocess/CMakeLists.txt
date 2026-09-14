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
if(NOT APPLE)
  # These portable fixtures intentionally have no desktop video backend.
  set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "" FORCE)
  set(SDL_X11 OFF CACHE BOOL "" FORCE)
  set(SDL_WAYLAND OFF CACHE BOOL "" FORCE)
  set(SDL_ALSA OFF CACHE BOOL "" FORCE)
  set(SDL_PULSEAUDIO OFF CACHE BOOL "" FORCE)
  set(SDL_PIPEWIRE OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory("${S2K_SDL_SOURCE}" sdl EXCLUDE_FROM_ALL)
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../Integrations/SDL3" switch2kit)
get_filename_component(_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_fixture "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}S2KSDLFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
set(_args)
if(APPLE)
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE _sdk OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  execute_process(COMMAND uname -m OUTPUT_VARIABLE _arch OUTPUT_STRIP_TRAILING_WHITESPACE)
  list(APPEND _args -sdk "${_sdk}" -target "${_arch}-apple-macosx15.0")
else()
  list(APPEND _args -Xlinker -soname -Xlinker "${CMAKE_SHARED_LIBRARY_PREFIX}S2KSDLFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()
add_custom_command(OUTPUT "${_fixture}"
  COMMAND "${Python3_EXECUTABLE}" "${_root}/tests/support/compile-fixture.py"
    --description "${SWITCH2KIT_C_BINARY_DIR}/description.json"
    --compiler "${SWITCH2KIT_SWIFTC}" -- -swift-version 6 -warnings-as-errors -emit-library
    -module-name S2KSDLFixture ${_args}
    -I "${SWITCH2KIT_C_BINARY_DIR}/Modules" -I "${_root}/Sources/Switch2KitCABI/include"
    -L "${SWITCH2KIT_C_BINARY_DIR}" -lSwitch2KitC
    -Xlinker -rpath -Xlinker "${SWITCH2KIT_C_BINARY_DIR}"
    "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift" -o "${_fixture}"
  DEPENDS Switch2KitCBuild "${_root}/tests/support/compile-fixture.py" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift" VERBATIM)
add_custom_target(S2KSDLFixtureBuild DEPENDS "${_fixture}")
add_library(S2KSDLFixture SHARED IMPORTED GLOBAL)
set_target_properties(S2KSDLFixture PROPERTIES IMPORTED_LOCATION "${_fixture}")
add_dependencies(S2KSDLFixture S2KSDLFixtureBuild)
add_executable(sdl-inprocess main.cpp)
target_compile_features(c-consumer PRIVATE cxx_std_17)
target_compile_options(sdl-inprocess PRIVATE -Wall -Wextra -Werror -UNDEBUG)
target_compile_options(Switch2KitSDL3 PRIVATE -Wall -Wextra -Werror)
target_link_libraries(sdl-inprocess PRIVATE Switch2Kit::SDL3 S2KSDLFixture)
set_property(TARGET sdl-inprocess APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME sdl-inprocess COMMAND sdl-inprocess)
set_tests_properties(sdl-inprocess PROPERTIES TIMEOUT 45)
