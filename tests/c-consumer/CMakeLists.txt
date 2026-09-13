cmake_minimum_required(VERSION 3.24)
project(Switch2KitCConsumer LANGUAGES C CXX)
enable_testing()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../Integrations/CMake" switch2kit)
get_filename_component(_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_fixture "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}S2KFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
# Uses package-scoped fake boundaries, but compiles separately from the distribution library.
set(_fixture_args)
if(APPLE)
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE _sdk OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  if(CMAKE_OSX_ARCHITECTURES)
    list(LENGTH CMAKE_OSX_ARCHITECTURES _narch)
    if(NOT _narch EQUAL 1)
      message(FATAL_ERROR "Run native consumer tests once per architecture; the facade itself supports universal builds")
    endif()
    set(_arch "${CMAKE_OSX_ARCHITECTURES}")
  else()
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _arch OUTPUT_STRIP_TRAILING_WHITESPACE)
  endif()
  list(APPEND _fixture_args -sdk "${_sdk}" -target "${_arch}-apple-macosx15.0")
endif()
add_custom_command(OUTPUT "${_fixture}"
  COMMAND "${SWITCH2KIT_SWIFTC}" -swift-version 6 -warnings-as-errors -emit-library
    -package-name switch2kit -module-name S2KFixture ${_fixture_args}
    -I "${SWITCH2KIT_C_BINARY_DIR}/Modules" -I "${_root}/Sources/Switch2KitCABI/include"
    -L "${SWITCH2KIT_C_BINARY_DIR}" -lSwitch2KitC
    -Xlinker -rpath -Xlinker "${SWITCH2KIT_C_BINARY_DIR}"
    "${_root}/Tests/Switch2KitCTests/TestSource.swift" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift"
    -o "${_fixture}"
  DEPENDS Switch2KitCBuild "${_root}/Tests/Switch2KitCTests/TestSource.swift" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift"
  VERBATIM)
add_custom_target(S2KFixtureBuild DEPENDS "${_fixture}")
add_library(S2KFixture SHARED IMPORTED)
set_target_properties(S2KFixture PROPERTIES IMPORTED_LOCATION "${_fixture}")
add_dependencies(S2KFixture S2KFixtureBuild)
add_executable(c-consumer main.cpp header.c)
target_compile_features(c-consumer PRIVATE cxx_std_17 c_std_11)
target_compile_options(c-consumer PRIVATE -Wall -Wextra -Werror -UNDEBUG)
target_link_libraries(c-consumer PRIVATE Switch2Kit::C S2KFixture)
add_test(NAME c-consumer COMMAND c-consumer)
set_tests_properties(c-consumer PROPERTIES TIMEOUT 20)
