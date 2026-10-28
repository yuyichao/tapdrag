cmake_minimum_required(VERSION 3.29)
project(tapdrag LANGUAGES Swift)

# Swift needs the Ninja (or Xcode) generator: cmake -G Ninja -B build

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "$ENV{HOME}/.local" CACHE PATH "Install prefix" FORCE)
endif()
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TAPDRAG_INSTALL_AGENT "Install the LaunchAgent and (re)start it on install" ON)

include(GNUInstallDirs)

find_program(CODESIGN codesign REQUIRED)

set(CMAKE_Swift_COMPILATION_MODE "$<IF:$<CONFIG:Debug>,incremental,wholemodule>")

# CMake's Swift rule doesn't track the bridging header (OBJECT_DEPENDS is
# ignored for Swift). This empty generated source is touched whenever the
# header changes, and that forces the module to recompile.
set(bridge_stamp "${CMAKE_CURRENT_BINARY_DIR}/MTBridgeStamp.swift")
add_custom_command(OUTPUT "${bridge_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E touch "${bridge_stamp}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/MTBridge.h"
  VERBATIM)

add_executable(tapdrag main.swift "${bridge_stamp}")
target_compile_options(tapdrag PRIVATE
  "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/MTBridge.h")

# A stable signing identifier. The Accessibility grant still has to be
# renewed after each rebuild, because the ad-hoc signature changes.
add_custom_command(TARGET tapdrag POST_BUILD
  COMMAND "${CODESIGN}" -s - -f --identifier local.tapdrag "$<TARGET_FILE:tapdrag>"
  VERBATIM)

# Install

set(TAPDRAG_LABEL local.tapdrag)
set(TAPDRAG_BIN "${CMAKE_INSTALL_FULL_BINDIR}/tapdrag")
set(TAPDRAG_PLIST "$ENV{HOME}/Library/LaunchAgents/${TAPDRAG_LABEL}.plist")
set(TAPDRAG_LOG "$ENV{HOME}/Library/Logs/tapdrag.log")

configure_file(cmake/launchagent.plist.in "${TAPDRAG_LABEL}.plist" @ONLY)
configure_file(cmake/launchagent.cmake.in launchagent.cmake @ONLY)
set(launchagent_script "${CMAKE_CURRENT_BINARY_DIR}/launchagent.cmake")

# Stop the running agent and remove the old binary before copying the new one.
install(CODE "set(ACTION stop)\ninclude(\"${launchagent_script}\")")
# install(PROGRAMS) copies the file byte for byte. install(TARGETS) may rewrite
# rpaths, and that would break the signature.
install(PROGRAMS "$<TARGET_FILE:tapdrag>" DESTINATION "${CMAKE_INSTALL_BINDIR}")
if(TAPDRAG_INSTALL_AGENT)
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${TAPDRAG_LABEL}.plist"
    DESTINATION "$ENV{HOME}/Library/LaunchAgents")
  install(CODE "set(ACTION start)\ninclude(\"${launchagent_script}\")")
endif()

add_custom_target(uninstall
  COMMAND "${CMAKE_COMMAND}" -DACTION=uninstall -P "${launchagent_script}"
  VERBATIM)
