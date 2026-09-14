# The host signs the completed app. This function neither signs nor changes entitlements.
function(switch2kit_embed target)
  if(NOT APPLE)
    return()
  endif()
  get_target_property(_bundle "${target}" MACOSX_BUNDLE)
  if(NOT _bundle)
    message(FATAL_ERROR "switch2kit_embed requires a MACOSX_BUNDLE target")
  endif()
  # Resolve the host-supplied permission fragment while its CMake scope is alive.
  # Leave CMake's own bundle/version placeholders for the bundle generator.
  get_target_property(_plist "${target}" MACOSX_BUNDLE_INFO_PLIST)
  if(_plist AND DEFINED SWITCH2KIT_BLUETOOTH_USAGE)
    get_target_property(_source_dir "${target}" SOURCE_DIR)
    get_filename_component(_plist "${_plist}" ABSOLUTE BASE_DIR "${_source_dir}")
    file(READ "${_plist}" _template)
    string(REPLACE "\${SWITCH2KIT_BLUETOOTH_USAGE}" "${SWITCH2KIT_BLUETOOTH_USAGE}"
      _template "${_template}")
    set(_prepared "${CMAKE_CURRENT_BINARY_DIR}/${target}-Switch2Kit-Info.plist.in")
    file(WRITE "${_prepared}" "${_template}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_plist}")
    set_property(TARGET "${target}" PROPERTY MACOSX_BUNDLE_INFO_PLIST "${_prepared}")
  endif()

  add_custom_command(TARGET "${target}" POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:Switch2Kit::C>"
      "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks/"
    COMMAND "${CMAKE_COMMAND}"
      "-DS2K_BUNDLE_LIBRARY=$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks/$<TARGET_FILE_NAME:Switch2Kit::C>"
      -P "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/PrepareBundle.cmake"
    COMMAND xcrun swift-stdlib-tool --copy --platform macosx
      --scan-executable "$<TARGET_FILE:Switch2Kit::C>"
      --destination "$<TARGET_BUNDLE_CONTENT_DIR:${target}>/Frameworks"
    VERBATIM)
  set_property(TARGET "${target}" APPEND PROPERTY BUILD_RPATH "@executable_path/../Frameworks")
  set_property(TARGET "${target}" APPEND PROPERTY INSTALL_RPATH "@executable_path/../Frameworks")
endfunction()
