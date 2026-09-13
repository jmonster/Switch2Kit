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
set(_s2k_args --package-path "${SWITCH2KIT_SOURCE_ROOT}"
    --scratch-path "${CMAKE_CURRENT_BINARY_DIR}/swift"
    --configuration "${SWITCH2KIT_SWIFT_CONFIGURATION}")
if(APPLE)
  foreach(_arch IN LISTS CMAKE_OSX_ARCHITECTURES)
    list(APPEND _s2k_args --arch "${_arch}")
  endforeach()
endif()
execute_process(COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --show-bin-path
  OUTPUT_VARIABLE _s2k_bin OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _s2k_result COMMAND_ERROR_IS_FATAL ANY)
if(APPLE)
  set(_s2k_library "${_s2k_bin}/libSwitch2KitC.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(_s2k_library "${_s2k_bin}/libSwitch2KitC.so")
else()
  message(FATAL_ERROR "Switch2Kit supports macOS hosts and Linux ABI tests only")
endif()
file(GLOB_RECURSE _s2k_sources CONFIGURE_DEPENDS
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2Kit/*.swift"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitC/*.swift"
  "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitCABI/*")
add_custom_command(OUTPUT "${_s2k_library}"
  COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --product Switch2KitC
  DEPENDS ${_s2k_sources} "${SWITCH2KIT_SOURCE_ROOT}/Package.swift"
  COMMENT "Building the Switch2Kit C binding with SwiftPM" VERBATIM)
add_custom_target(Switch2KitCBuild DEPENDS "${_s2k_library}")
add_library(Switch2Kit::C SHARED IMPORTED GLOBAL)
set_target_properties(Switch2Kit::C PROPERTIES
  IMPORTED_LOCATION "${_s2k_library}"
  INTERFACE_INCLUDE_DIRECTORIES "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitCABI/include")
add_dependencies(Switch2Kit::C Switch2KitCBuild)
set(SWITCH2KIT_C_BINARY_DIR "${_s2k_bin}" CACHE INTERNAL "Built C facade directory")

# The host signs the completed app. This function neither signs nor changes entitlements.
function(switch2kit_embed target)
  if(NOT APPLE)
    return()
  endif()
  get_target_property(_bundle "${target}" MACOSX_BUNDLE)
  if(NOT _bundle)
    message(FATAL_ERROR "switch2kit_embed requires a MACOSX_BUNDLE target")
  endif()
  add_custom_command(TARGET "${target}" POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:Switch2Kit::C>"
      "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks/"
    COMMAND xcrun swift-stdlib-tool --copy --platform macosx
      --scan-executable "$<TARGET_FILE:Switch2Kit::C>"
      --destination "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks"
    VERBATIM)
  set_property(TARGET "${target}" APPEND PROPERTY BUILD_RPATH "@executable_path/../Frameworks")
  set_property(TARGET "${target}" APPEND PROPERTY INSTALL_RPATH "@executable_path/../Frameworks")
endfunction()
