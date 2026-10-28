cmake_minimum_required(VERSION 3.29)

set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "Minimum macOS version")
project(tapdrag VERSION 0.1.0 LANGUAGES Swift)

# Swift needs the Ninja (or Xcode) generator: cmake -G Ninja -B build

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "/Applications" CACHE PATH "Where `cmake --install` puts tapdrag.app" FORCE)
endif()
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(TAPDRAG_BUNDLE_ID local.tapdrag CACHE STRING "Bundle identifier")
set(TAPDRAG_SIGN_IDENTITY "-" CACHE STRING
  "codesign identity. \"-\" (ad-hoc) means Accessibility must be granted again after every rebuild. \
A real certificate (e.g. \"Apple Development: …\") keeps the grant.")

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

add_executable(tapdrag MACOSX_BUNDLE main.swift App.swift "${bridge_stamp}")
target_compile_options(tapdrag PRIVATE
  "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/MTBridge.h")
set_target_properties(tapdrag PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${TAPDRAG_BUNDLE_ID}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")

add_custom_command(TARGET tapdrag POST_BUILD
  COMMAND "${CODESIGN}" --force --sign "${TAPDRAG_SIGN_IDENTITY}" "$<TARGET_BUNDLE_DIR:tapdrag>"
  VERBATIM)

# `cmake --install build` copies the bundle byte for byte, so the signature
# stays valid. The old bundle is removed first: overwriting a signed binary in
# place can make macOS kill the new one when it launches.
set(app_dest "${CMAKE_INSTALL_PREFIX}/tapdrag.app")
install(CODE "file(REMOVE_RECURSE \"\$ENV{DESTDIR}${app_dest}\")")
install(DIRECTORY "$<TARGET_BUNDLE_DIR:tapdrag>" DESTINATION . USE_SOURCE_PERMISSIONS)

add_custom_target(uninstall
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${app_dest}"
  COMMENT "Removing ${app_dest}"
  VERBATIM)

# `cmake --build build --target dmg`: a disk image with tapdrag.app and an
# Applications link, for drag-and-drop installs.
set(dmg_root "${CMAKE_CURRENT_BINARY_DIR}/dmg-root")
set(dmg "${CMAKE_CURRENT_BINARY_DIR}/tapdrag-${PROJECT_VERSION}.dmg")
add_custom_target(dmg
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${dmg_root}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${dmg_root}"
  COMMAND ditto "$<TARGET_BUNDLE_DIR:tapdrag>" "${dmg_root}/tapdrag.app"
  COMMAND "${CMAKE_COMMAND}" -E create_symlink /Applications "${dmg_root}/Applications"
  COMMAND hdiutil create -quiet -ov -volname tapdrag -fs HFS+ -format UDZO
          -srcfolder "${dmg_root}" "${dmg}"
  COMMENT "Creating ${dmg}"
  DEPENDS tapdrag
  VERBATIM)
