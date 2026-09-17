# Native Linux installation. Swift runtime libraries remain distribution/host
# dependencies; unlike a macOS bundle, this does not claim a self-contained app.
function(switch2kit_install_linux target)
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "switch2kit_install_linux requires a Linux target")
  endif()
  include(GNUInstallDirs)
  get_filename_component(_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../.." ABSOLUTE)
  file(RELATIVE_PATH _library_from_bin "${CMAKE_INSTALL_FULL_BINDIR}" "${CMAKE_INSTALL_FULL_LIBDIR}")
  set_property(TARGET "${target}" APPEND PROPERTY INSTALL_RPATH "$ORIGIN/${_library_from_bin}")
  install(FILES "$<TARGET_FILE:Switch2Kit::C>" DESTINATION "${CMAKE_INSTALL_LIBDIR}")
  install(FILES "${_root}/CREDITS.md" DESTINATION "${CMAKE_INSTALL_DATADIR}/Switch2KitNotices")
  install(DIRECTORY "${_root}/LICENSES" DESTINATION "${CMAKE_INSTALL_DATADIR}/Switch2KitNotices")
endfunction()
