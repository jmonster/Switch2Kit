cmake_minimum_required(VERSION 3.24)
project(Switch2KitEmulatorHost LANGUAGES C CXX)
enable_testing()
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../sdl-inprocess" sdl-consumer)
add_executable(emulator-host main.cpp)
target_compile_features(emulator-host PRIVATE cxx_std_17)
target_compile_options(emulator-host PRIVATE -Wall -Wextra -Werror -UNDEBUG)
target_include_directories(emulator-host PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../Integrations/Emulators")
target_link_libraries(emulator-host PRIVATE Switch2Kit::SDL3 S2KSDLFixture)
set_property(TARGET emulator-host APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}")
add_test(NAME emulator-host COMMAND emulator-host)
set_tests_properties(emulator-host PROPERTIES TIMEOUT 30)
add_executable(emulator-motion-profile profile.cpp)
target_compile_features(emulator-motion-profile PRIVATE cxx_std_17)
target_compile_options(emulator-motion-profile PRIVATE -Wall -Wextra -Werror -UNDEBUG)
target_include_directories(emulator-motion-profile PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../Integrations/Emulators")
target_link_libraries(emulator-motion-profile PRIVATE Switch2Kit::SDL3 S2KSDLFixture)
set_property(TARGET emulator-motion-profile APPEND PROPERTY BUILD_RPATH "${SWITCH2KIT_C_BINARY_DIR}")
add_test(NAME emulator-motion-profile COMMAND emulator-motion-profile)
set_tests_properties(emulator-motion-profile PROPERTIES TIMEOUT 30)
add_executable(emulator-motion-pair motion-pair.cpp)
target_compile_features(emulator-motion-pair PRIVATE cxx_std_17)
target_compile_options(emulator-motion-pair PRIVATE -Wall -Wextra -Werror -UNDEBUG)
target_include_directories(emulator-motion-pair PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../Integrations/Emulators")
target_link_libraries(emulator-motion-pair PRIVATE Switch2Kit::SDL3)
add_test(NAME emulator-motion-pair COMMAND emulator-motion-pair)
set_tests_properties(emulator-motion-pair PROPERTIES TIMEOUT 30)

# Compile actual pinned emulator motion processing when its source is supplied.
# No rewritten sensor/fusion implementation is used by this consumer. The same
# adapter source uses live clocks except for an explicit simulated system suspend.
if(S2K_CEMU_SOURCE)
  if(NOT EXISTS "${S2K_CEMU_SOURCE}/src/input/motion/MotionHandler.h")
    message(FATAL_ERROR "S2K_CEMU_SOURCE must contain the pinned Cemu source")
  endif()
  find_package(Boost 1.70 REQUIRED)
  add_executable(cemu-native-motion cemu-motion.cpp ../sdl-inprocess/Clock.cpp)
  target_compile_features(cemu-native-motion PRIVATE cxx_std_20)
  target_compile_options(cemu-native-motion PRIVATE -Wall -Wextra -Werror -UNDEBUG)
  target_include_directories(cemu-native-motion PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../Integrations/Emulators")
  target_include_directories(cemu-native-motion SYSTEM PRIVATE "${S2K_CEMU_SOURCE}/src" ${Boost_INCLUDE_DIRS})
  target_link_libraries(cemu-native-motion PRIVATE S2KSDLClockedAdapter S2KSDLFixture)
  add_test(NAME cemu-native-motion COMMAND cemu-native-motion)
  set_tests_properties(cemu-native-motion PROPERTIES TIMEOUT 30)
endif()

if(S2K_DOLPHIN_SOURCE)
  if(NOT EXISTS "${S2K_DOLPHIN_SOURCE}/Source/Core/Core/HW/WiimoteEmu/Dynamics.cpp")
    message(FATAL_ERROR "S2K_DOLPHIN_SOURCE must contain the patched pinned Dolphin source")
  endif()
  find_path(S2K_DOLPHIN_FMT_INCLUDE fmt/format.h REQUIRED)
  add_executable(dolphin-native-motion dolphin-motion.cpp ../sdl-inprocess/Clock.cpp
    "${S2K_DOLPHIN_SOURCE}/Source/Core/Core/HW/WiimoteEmu/Dynamics.cpp"
    "${S2K_DOLPHIN_SOURCE}/Source/Core/Common/Matrix.cpp"
    "${S2K_DOLPHIN_SOURCE}/Source/Core/Common/IniFile.cpp"
    "${S2K_DOLPHIN_SOURCE}/Source/Core/Common/StringUtil.cpp")
  # The pinned upstream StringUtil has a deliberate no-op parameter outside Windows.
  # Keep the consumer and motion processor strict without editing unrelated upstream code.
  set_source_files_properties("${S2K_DOLPHIN_SOURCE}/Source/Core/Common/StringUtil.cpp"
    PROPERTIES COMPILE_OPTIONS "-Wno-unused-parameter")
  target_compile_features(dolphin-native-motion PRIVATE cxx_std_23)
  target_compile_definitions(dolphin-native-motion PRIVATE HAVE_SWITCH2KIT FMT_HEADER_ONLY)
  target_compile_options(dolphin-native-motion PRIVATE -Wall -Wextra -Werror -UNDEBUG -ffunction-sections -fdata-sections)
  # Link the actual motion processor, without pulling unrelated application methods
  # from the same upstream translation unit. Full app builds test those methods.
  if(APPLE)
    target_link_options(dolphin-native-motion PRIVATE -Wl,-dead_strip)
  else()
    target_link_options(dolphin-native-motion PRIVATE -Wl,--gc-sections)
  endif()
  target_include_directories(dolphin-native-motion PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../Integrations/Emulators")
  target_include_directories(dolphin-native-motion SYSTEM PRIVATE
    "${S2K_DOLPHIN_SOURCE}/Source/Core" "${S2K_DOLPHIN_FMT_INCLUDE}")
  target_link_libraries(dolphin-native-motion PRIVATE S2KSDLClockedAdapter S2KSDLFixture)
  add_test(NAME dolphin-native-motion COMMAND dolphin-native-motion)
  set_tests_properties(dolphin-native-motion PROPERTIES TIMEOUT 30)
endif()
