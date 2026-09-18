# Native Linux installation. Bundle the compiler-selected Swift runtime closure;
# libc, desktop libraries, graphics drivers and BlueZ remain OS prerequisites.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  include("${CMAKE_CURRENT_LIST_DIR}/Runtime.cmake")
endif()
function(switch2kit_install_linux target)
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "switch2kit_install_linux requires a Linux target")
  endif()
  include(GNUInstallDirs)
  get_filename_component(_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../.." ABSOLUTE)
  file(RELATIVE_PATH _library_from_bin "${CMAKE_INSTALL_FULL_BINDIR}" "${CMAKE_INSTALL_FULL_LIBDIR}")
  set_property(TARGET "${target}" APPEND PROPERTY INSTALL_RPATH "$ORIGIN/${_library_from_bin}")
  install(CODE "
    execute_process(COMMAND \"${CMAKE_COMMAND}\"
      \"-DS2K_LIBRARY=$<TARGET_FILE:Switch2Kit::C>\"
      \"-DS2K_DESTINATION=\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}\"
      \"-DS2K_NOTICES=\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_DATADIR}/Switch2KitNotices\"
      \"-DS2K_RUNTIME_CONFIG=${SWITCH2KIT_RUNTIME_CONFIG}\"
      -P \"${SWITCH2KIT_RUNTIME_SCRIPT}\" COMMAND_ERROR_IS_FATAL ANY)
  ")
  install(FILES "${_root}/CREDITS.md" DESTINATION "${CMAKE_INSTALL_DATADIR}/Switch2KitNotices")
  install(DIRECTORY "${_root}/LICENSES" DESTINATION "${CMAKE_INSTALL_DATADIR}/Switch2KitNotices")
endfunction()
