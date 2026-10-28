#!/bin/sh
# Builds ./tapdrag. Rebuilding changes the binary's signature, so macOS will
# ask for the Accessibility permission again afterwards.
set -e
cd "$(dirname "$0")"
swiftc -O -import-objc-header MTBridge.h tapdrag.swift -o tapdrag
codesign -s - -f --identifier local.tapdrag tapdrag
echo "built $(pwd)/tapdrag"
