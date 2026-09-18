cmake_minimum_required(VERSION 3.24)
project(Switch2KitCConsumer LANGUAGES C CXX)
enable_testing()
find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../Integrations/CMake" switch2kit)
get_filename_component(_root "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_fixture "${CMAKE_CURRENT_BINARY_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}S2KFixture${CMAKE_SHARED_LIBRARY_SUFFIX}")
# Uses package-scoped fake boundaries, but compiles separately from the distribution library.
set(_fixture_args)
set(_fixture_byproducts)
set(_rpath_args)
if(WIN32)
  set(_fixture_import "${CMAKE_CURRENT_BINARY_DIR}/S2KFixture.lib")
  list(APPEND _fixture_byproducts "${_fixture_import}")
  list(APPEND _fixture_args -Xlinker "/IMPLIB:${_fixture_import}")
else()
  list(APPEND _rpath_args -Xlinker -rpath -Xlinker "${SWITCH2KIT_C_BINARY_DIR}")
endif()
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
  BYPRODUCTS ${_fixture_byproducts}
  COMMAND "${Python3_EXECUTABLE}" "${_root}/tests/support/compile-fixture.py"
    --description "${SWITCH2KIT_C_BINARY_DIR}/description.json"
    --compiler "${SWITCH2KIT_SWIFTC}" -- -swift-version 6 -warnings-as-errors -emit-library
    -module-name S2KFixture ${_fixture_args}
    -I "${SWITCH2KIT_C_BINARY_DIR}/Modules" -I "${_root}/Sources/Switch2KitCABI/include"
    -L "${SWITCH2KIT_C_BINARY_DIR}" -lSwitch2KitC
    ${_rpath_args}
    "${_root}/Tests/Switch2KitCTests/TestSource.swift" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift"
    -o "${_fixture}"
  DEPENDS Switch2KitCBuild "${_root}/tests/support/compile-fixture.py" "${_root}/Tests/Switch2KitCTests/TestSource.swift" "${CMAKE_CURRENT_LIST_DIR}/Fixture.swift"
  VERBATIM)
add_custom_target(S2KFixtureBuild DEPENDS "${_fixture}")
add_library(S2KFixture SHARED IMPORTED)
set_target_properties(S2KFixture PROPERTIES IMPORTED_LOCATION "${_fixture}")
if(WIN32)
  set_target_properties(S2KFixture PROPERTIES IMPORTED_IMPLIB "${_fixture_import}")
endif()
add_dependencies(S2KFixture S2KFixtureBuild)
add_executable(c-consumer main.cpp header.c)
target_compile_features(c-consumer PRIVATE cxx_std_17 c_std_11)
if(MSVC)
  target_compile_options(c-consumer PRIVATE /W4 /UNDEBUG)
else()
  target_compile_options(c-consumer PRIVATE -Wall -Wextra -Werror -UNDEBUG)
endif()
target_link_libraries(c-consumer PRIVATE Switch2Kit::C S2KFixture)
set_property(TARGET c-consumer APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}" "${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME c-consumer COMMAND c-consumer)
set_tests_properties(c-consumer PROPERTIES TIMEOUT 20)

if(WIN32)
  switch2kit_embed_windows(c-consumer)
  add_custom_command(TARGET c-consumer POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_fixture}" "$<TARGET_FILE_DIR:c-consumer>" VERBATIM)
endif()

# Compile the production settings/profile reader on every native consumer host.
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../host-file" host-file)

# Native dependency graphs exercise the deployment boundary and missing-DLL
# failures independently of Swift/Bluetooth; real consumers above test the SDK.
add_test(NAME desktop-runtime-staging
  COMMAND "${Python3_EXECUTABLE}" "${_root}/tests/desktop-runtime/test_staging.py")
set_tests_properties(desktop-runtime-staging PROPERTIES TIMEOUT 300)
