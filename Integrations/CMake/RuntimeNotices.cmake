# Exact upstream license bytes may be preseeded in this build-only cache for
# offline builds. Never silently archive a runtime without its license texts.
function(_s2k_license name url blob output)
  get_filename_component(_cache "${S2K_RUNTIME_CONFIG}" DIRECTORY)
  set(_path "${_cache}/runtime-notices/${name}")
  file(MAKE_DIRECTORY "${_cache}/runtime-notices")
  # A concurrent deployment must not hash a partially downloaded cache file.
  # This per-license lock is independent of the application copy lock and is
  # released on function return. The download itself remains bounded at 60 s.
  file(LOCK "${_path}.lock" GUARD FUNCTION TIMEOUT 120)
  if(NOT EXISTS "${_path}")
    file(DOWNLOAD "${url}" "${_path}" TLS_VERIFY ON STATUS _status TIMEOUT 60)
    list(GET _status 0 _code)
    if(NOT _code EQUAL 0)
      file(REMOVE "${_path}")
      message(FATAL_ERROR "Could not obtain ${name}: ${_status}; preseed ${_path} for offline packaging")
    endif()
  endif()
  execute_process(COMMAND "${S2K_GIT}" hash-object --no-filters "${_path}"
    OUTPUT_VARIABLE _actual OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  if(NOT _actual STREQUAL "${blob}")
    message(FATAL_ERROR "Altered or incorrect upstream license: ${_path}")
  endif()
  set(${output} "${_path}" PARENT_SCOPE)
endfunction()

macro(switch2kit_runtime_notices)
  if(NOT EXISTS "${S2K_SWIFT_LICENSE}")
    if(NOT S2K_SWIFT_TAG)
      message(FATAL_ERROR "Set SWITCH2KIT_SWIFT_LICENSE to the selected Swift distribution's LICENSE.txt")
    endif()
    _s2k_license(Swift-${S2K_SWIFT_TAG}.txt
      "https://raw.githubusercontent.com/swiftlang/swift/${S2K_SWIFT_TAG}/LICENSE.txt"
      "61b0c78195f2d00acaf658000eeca6ad406a3a29" S2K_SWIFT_LICENSE)
  endif()
  if(NOT S2K_ICU_LICENSE)
    if(NOT S2K_ICU_TAG OR NOT S2K_ICU_BLOB)
      message(FATAL_ERROR "Supply SWITCH2KIT_RUNTIME_ICU_LICENSE for this Swift distribution; automated deployment is qualified with 6.2.1 and 6.3.3")
    endif()
    _s2k_license(ICU-${S2K_ICU_TAG}.txt
      "https://raw.githubusercontent.com/unicode-org/icu/${S2K_ICU_TAG}/LICENSE"
      "${S2K_ICU_BLOB}" S2K_ICU_LICENSE)
  endif()
  if(NOT EXISTS "${S2K_ICU_LICENSE}")
    message(FATAL_ERROR "The runtime ICU license and third-party notices are required")
  endif()
endmacro()
