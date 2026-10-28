cmake_minimum_required(VERSION 3.29)

set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "Minimum macOS version")
# Bump the version here. It isn't a cache variable, so existing build folders
# pick up a new value. TAPDRAG_VERSION overrides it; the release workflow sets
# that from the git tag (v1.2.3 -> 1.2.3).
set(default_version 0.2.0)
set(TAPDRAG_VERSION "" CACHE STRING "Override the version (empty: the default in CMakeLists.txt)")
if(TAPDRAG_VERSION)
  set(version "${TAPDRAG_VERSION}")
else()
  set(version "${default_version}")
endif()
project(tapdrag VERSION ${version} LANGUAGES Swift)

# Swift needs the Ninja (or Xcode) generator: cmake -G Ninja -B build

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "/Applications" CACHE PATH "Where `cmake --install` puts tapdrag.app" FORCE)
endif()
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(TAPDRAG_BUNDLE_ID local.tapdrag CACHE STRING "Bundle identifier")
set(TAPDRAG_SIGN_IDENTITY "" CACHE STRING
  "codesign identity. Empty: \"tapdrag Code Signing\" if it is in the keychain, else ad-hoc (\"-\"). \
With ad-hoc signing the Device Control and Data Access (Accessibility before macOS 27) \
permission must be granted again after every rebuild.")

find_program(CODESIGN codesign REQUIRED)

# Without the certificate every build gets a new identity and macOS forgets
# the Device Control and Data Access (formerly Accessibility) grant.
# See "Signing certificate" in README.md.
set(sign_identity "${TAPDRAG_SIGN_IDENTITY}")
if(sign_identity STREQUAL "")
  execute_process(COMMAND security find-identity -p codesigning
    OUTPUT_VARIABLE identities ERROR_QUIET)
  if(identities MATCHES "\"tapdrag Code Signing\"")
    set(sign_identity "tapdrag Code Signing")
  else()
    set(sign_identity "-")
  endif()
endif()
if(sign_identity STREQUAL "-")
  message(STATUS "Signing: ad-hoc (the app's permission must be granted again after each rebuild)")
else()
  message(STATUS "Signing: ${sign_identity}")
endif()

set(CMAKE_Swift_COMPILATION_MODE "$<IF:$<CONFIG:Debug>,incremental,wholemodule>")

# CMake's Swift rule doesn't track the bridging header (OBJECT_DEPENDS is
# ignored for Swift). This empty generated source is touched whenever the
# header changes, and that forces the module to recompile.
set(bridge_stamp "${CMAKE_CURRENT_BINARY_DIR}/MTBridgeStamp.swift")
add_custom_command(OUTPUT "${bridge_stamp}"
  COMMAND "${CMAKE_COMMAND}" -E touch "${bridge_stamp}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/MTBridge.h"
  VERBATIM)

add_executable(tapdrag MACOSX_BUNDLE main.swift App.swift Settings.swift "${bridge_stamp}")
target_compile_options(tapdrag PRIVATE
  "SHELL:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/MTBridge.h")
set_target_properties(tapdrag PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${TAPDRAG_BUNDLE_ID}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")

add_custom_command(TARGET tapdrag POST_BUILD
  COMMAND "${CODESIGN}" --force --sign "${sign_identity}" "$<TARGET_BUNDLE_DIR:tapdrag>"
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
