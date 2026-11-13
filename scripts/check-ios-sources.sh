#!/bin/bash
# Source compilation fallback for environments without CoreSimulator. Does not build a runnable .app.
# The nested compiler sandbox is disabled because sandbox-exec cannot nest in restricted sessions.
# This never changes the outer session's filesystem or network permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/source-check
mkdir -p "$out" build/module-cache
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
developer="$(xcode-select -p)"
common=(-disable-sandbox -module-cache-path build/module-cache -sdk "$sdk" -target arm64-apple-ios17.0-simulator -swift-version 6)
compiler=(xcrun --sdk iphonesimulator swiftc)
"${compiler[@]}" "${common[@]}" -parse-as-library -emit-library -static -emit-module -module-name VespertineRemoteProtocol \
  -emit-module-path "$out/VespertineRemoteProtocol.swiftmodule" -o "$out/libVespertineRemoteProtocol.a" \
  Packages/VespertineRemoteKit/Sources/VespertineRemoteProtocol/*.swift
"${compiler[@]}" "${common[@]}" -parse-as-library -emit-library -static -emit-module -module-name VespertineRemoteClient \
  -I "$out" -emit-module-path "$out/VespertineRemoteClient.swiftmodule" -o "$out/libVespertineRemoteClient.a" \
  Packages/VespertineRemoteKit/Sources/VespertineRemoteClient/*.swift
app=(-default-isolation MainActor -enable-experimental-feature NonisolatedNonsendingByDefault -parse-as-library \
     -module-name VespertineRemote -I "$out" -L "$out" -lVespertineRemoteClient -lVespertineRemoteProtocol)
"${compiler[@]}" "${common[@]}" "${app[@]}" -D DEBUG -enable-testing -emit-module \
  -emit-module-path "$out/VespertineRemote.swiftmodule" -emit-executable -o "$out/VespertineRemote-Debug" RemoteApp/Sources/*.swift
"${compiler[@]}" "${common[@]}" "${app[@]}" -O -emit-executable -o "$out/VespertineRemote-Release" RemoteApp/Sources/*.swift
frameworks="$developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
libs="$developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib"
testing="$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
"${compiler[@]}" "${common[@]}" -typecheck -F "$frameworks" -I "$libs" -I "$out" \
  -load-plugin-library "$testing" RemoteApp/Tests/*.swift
"${compiler[@]}" "${common[@]}" -typecheck -F "$frameworks" -I "$libs" RemoteApp/UITests/*.swift
xcrun vtool -show-build "$out/VespertineRemote-Debug"
xcrun vtool -show-build "$out/VespertineRemote-Release"
echo 'Debug and Release source compilation/linking and unit/UI test typechecking passed. Simulator execution remains unverified.'
