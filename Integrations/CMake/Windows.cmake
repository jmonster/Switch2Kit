# Native x64 Windows C ABI. SwiftPM owns the Swift and C++/WinRT compilation.
if(NOT WIN32 OR NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8 OR CMAKE_CROSSCOMPILING)
  message(FATAL_ERROR "Switch2Kit Windows requires a native x64 MSVC-compatible host build")
endif()
execute_process(COMMAND "${SWITCH2KIT_SWIFTC}" -print-target-info
  OUTPUT_VARIABLE _s2k_target_info COMMAND_ERROR_IS_FATAL ANY)
string(JSON _s2k_triple GET "${_s2k_target_info}" target triple)
if(NOT _s2k_triple MATCHES "^x86_64-.*windows-msvc$" OR
   CMAKE_CXX_COMPILER_ARCHITECTURE_ID MATCHES "ARM" OR
   (CMAKE_GENERATOR_PLATFORM AND NOT CMAKE_GENERATOR_PLATFORM STREQUAL "x64"))
  message(FATAL_ERROR "Use the x64 Swift toolchain and an x64 C/C++ build; Windows cross-compilation is not supported")
endif()
set(_s2k_args --package-path "${SWITCH2KIT_SOURCE_ROOT}"
  --scratch-path "${CMAKE_CURRENT_BINARY_DIR}/swift"
  --configuration "${SWITCH2KIT_SWIFT_CONFIGURATION}")
execute_process(COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --show-bin-path
  OUTPUT_VARIABLE _s2k_bin OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
set(_s2k_library "${_s2k_bin}/Switch2KitC.dll")
set(_s2k_import "${_s2k_bin}/Switch2KitC.lib")
add_custom_command(OUTPUT "${_s2k_library}" "${_s2k_import}"
  COMMAND "${SWITCH2KIT_SWIFT}" build ${_s2k_args} --product Switch2KitC
  DEPENDS ${_s2k_sources} "${SWITCH2KIT_SOURCE_ROOT}/Package.swift"
    "${CMAKE_CURRENT_LIST_FILE}"
  COMMENT "Building Switch2Kit C and native WinRT transport (x64)" VERBATIM)
add_custom_target(Switch2KitCBuild DEPENDS "${_s2k_library}" "${_s2k_import}")
add_library(Switch2Kit::C SHARED IMPORTED GLOBAL)
set_target_properties(Switch2Kit::C PROPERTIES
  IMPORTED_LOCATION "${_s2k_library}" IMPORTED_IMPLIB "${_s2k_import}"
  INTERFACE_INCLUDE_DIRECTORIES "${SWITCH2KIT_SOURCE_ROOT}/Sources/Switch2KitCABI/include")
add_dependencies(Switch2Kit::C Switch2KitCBuild)
set(SWITCH2KIT_C_BINARY_DIR "${_s2k_bin}" CACHE INTERNAL "Built C facade directory")

include("${CMAKE_CURRENT_LIST_DIR}/Runtime.cmake")

# Copy the facade and its compiler-selected Swift runtime closure. System DLLs
# and graphics/Bluetooth drivers remain operating-system prerequisites.
function(switch2kit_embed_windows target)
  get_filename_component(_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../.." ABSOLUTE)
  add_custom_command(TARGET "${target}" POST_BUILD
    COMMAND "${CMAKE_COMMAND}"
      "-DS2K_LIBRARY=$<TARGET_FILE:Switch2Kit::C>"
      "-DS2K_DESTINATION=$<TARGET_FILE_DIR:${target}>"
      "-DS2K_NOTICES=$<TARGET_FILE_DIR:${target}>/Switch2KitNotices"
      "-DS2K_RUNTIME_CONFIG=${SWITCH2KIT_RUNTIME_CONFIG}"
      -P "${SWITCH2KIT_RUNTIME_SCRIPT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_FILE_DIR:${target}>/Switch2KitNotices"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_root}/CREDITS.md"
      "$<TARGET_FILE_DIR:${target}>/Switch2KitNotices/CREDITS.md"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${_root}/LICENSES"
      "$<TARGET_FILE_DIR:${target}>/Switch2KitNotices/LICENSES"
    VERBATIM)
endfunction()
