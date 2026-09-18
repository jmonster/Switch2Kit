cmake_minimum_required(VERSION 3.24)
# add_subdirectory this directory from a C or C++ host; Swift is built by SwiftPM.
if(TARGET Switch2Kit::C)
  return()
endif()
get_filename_component(SWITCH2KIT_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
find_program(SWITCH2KIT_SWIFT swift REQUIRED)
find_program(SWITCH2KIT_SWIFTC swiftc REQUIRED)
set(SWITCH2KIT_SWIFT_CONFIGURATION release CACHE STRING "SwiftPM configuration: debug or release")
if(NOT SWITCH2KIT_SWIFT_CONFIGURATION MATCHES "^(debug|release)$")
  message(FATAL_ERROR "SWITCH2KIT_SWIFT_CONFIGURATION must be debug or release")
endif()
if(APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS 15.0)
  message(FATAL_ERROR "Switch2Kit C requires macOS 15+. Disable this optional backend or explicitly target 15.0+.")
endif()
file(GLOB_RECURSE _s2k_sources CONFIGURE_DEPENDS
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2Kit/*.swift"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitC/*.swift"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitCABI/*"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitDBus/*"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitWinRT/*")
if(WIN32)
  include("${CMAKE_CURRENT_LIST_DIR}/Windows.cmake")
  return()
endif()
if(APPLE)
  set(_s2k_archs "${CMAKE_OSX_ARCHITECTURES}")
  if(NOT _s2k_archs)
    set(_s2k_archs "${CMAKE_HOST_SYSTEM_PROCESSOR}")
  endif()
  list(REMOVE_DUPLICATES _s2k_archs)
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE _s2k_sdk
    OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  set(_s2k_slices)
  foreach(_arch IN LISTS _s2k_archs)
    if(NOT _arch MATCHES "^(arm64|x86_64)$")
      message(FATAL_ERROR "Unsupported Switch2Kit architecture: ${_arch}")
    endif()
    set(_s2k_args --package-path "${SWITCH2KIT_SOURCE_ROOT}"
      --scratch-path "${CMAKE_CURRENT_BINARY_DIR}/swift-${_arch}"
      --configuration "${SWITCH2KIT_SWIFT_CONFIGURATION}"
      --triple "${_arch}-apple-macosx15.0" --sdk "${_s2k_sdk}")
    execute_process(COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --show-bin-path
      OUTPUT_VARIABLE _s2k_bin OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
    set(_slice "${_s2k_bin}/libSwitch2KitC.dylib")
    add_custom_command(OUTPUT "${_slice}"
      COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --product Switch2KitC
      DEPENDS ${_s2k_sources} "${SWITCH2KIT_SOURCE_ROOT}/Package.swift"
      COMMENT "Building Switch2Kit C (${_arch})" VERBATIM)
    list(APPEND _s2k_slices "${_slice}")
  endforeach()
  list(LENGTH _s2k_archs _s2k_arch_count)
  if(_s2k_arch_count GREATER 1)
    set(_s2k_bin "${CMAKE_CURRENT_BINARY_DIR}/universal")
    set(_s2k_library "${_s2k_bin}/libSwitch2KitC.dylib")
    add_custom_command(OUTPUT "${_s2k_library}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${_s2k_bin}"
      COMMAND xcrun lipo -create ${_s2k_slices} -output "${_s2k_library}"
      DEPENDS ${_s2k_slices} VERBATIM)
  else()
    list(GET _s2k_slices 0 _s2k_library)
  endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(_s2k_args --package-path "${SWITCH2KIT_SOURCE_ROOT}"
    --scratch-path "${CMAKE_CURRENT_BINARY_DIR}/swift"
    --configuration "${SWITCH2KIT_SWIFT_CONFIGURATION}")
  execute_process(COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --show-bin-path
    OUTPUT_VARIABLE _s2k_bin OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  set(_s2k_library "${_s2k_bin}/libSwitch2KitC.so")
  add_custom_command(OUTPUT "${_s2k_library}"
    # Give the ELF facade an actual SONAME. Imported-target metadata alone
    # cannot prevent an absolute DT_NEEDED when a host links its file directly.
    COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --product Switch2KitC
      -Xlinker -soname -Xlinker libSwitch2KitC.so
    DEPENDS ${_s2k_sources} "${SWITCH2KIT_SOURCE_ROOT}/Package.swift"
      "${CMAKE_CURRENT_LIST_FILE}" VERBATIM)
else()
  message(FATAL_ERROR "Switch2Kit supports macOS, Linux and Windows desktop hosts")
endif()
add_custom_target(Switch2KitCBuild DEPENDS "${_s2k_library}")
add_library(Switch2Kit::C SHARED IMPORTED GLOBAL)
set_target_properties(Switch2Kit::C PROPERTIES
  IMPORTED_LOCATION "${_s2k_library}"
  INTERFACE_INCLUDE_DIRECTORIES "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitCABI/include")
if(APPLE)
  # Generated imported libraries do not exist when CMake first configures.
  # State the install name so runtime paths do not depend on configure-time inspection.
  set_target_properties(Switch2Kit::C PROPERTIES IMPORTED_SONAME "@rpath/libSwitch2KitC.dylib")
else()
  # Match the SONAME supplied to the Linux library's linker above.
  set_target_properties(Switch2Kit::C PROPERTIES IMPORTED_SONAME "libSwitch2KitC.so")
endif()
add_dependencies(Switch2Kit::C Switch2KitCBuild)
set(SWITCH2KIT_C_BINARY_DIR "${_s2k_bin}" CACHE INTERNAL "Built C facade directory")

include("${CMAKE_CURRENT_LIST_DIR}/Bundle.cmake")

include("${CMAKE_CURRENT_LIST_DIR}/Linux.cmake")
