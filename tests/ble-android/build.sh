#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.
set -euo pipefail
sdk=${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to an installed Android SDK}
out=${1:?Usage: build.sh OUTPUT_DIRECTORY}
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out/classes" "$out/dex"
out=$(cd "$out" && pwd)
platform="$sdk/platforms/android-36/android.jar"
build_tools="$sdk/build-tools/35.0.0"
javac --release 8 -classpath "$platform" -d "$out/classes" "$source_dir/"*.java
jar cf "$out/classes.jar" -C "$out/classes" .
"$build_tools/d8" --lib "$platform" --min-api 33 --output "$out/dex" "$out/classes.jar"
"$build_tools/aapt2" link -I "$platform" --manifest "$source_dir/AndroidManifest.xml" -o "$out/unsigned.apk"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
"$build_tools/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
if [[ ! -f "$out/test.keystore" ]]; then
  keytool -genkeypair -keystore "$out/test.keystore" -storepass android -keypass android \
    -alias test -keyalg RSA -keysize 2048 -validity 3650 -dname 'CN=Toit BLE test'
fi
"$build_tools/apksigner" sign --ks "$out/test.keystore" --ks-pass pass:android \
  --out "$out/ble-test.apk" "$out/aligned.apk"
"$build_tools/apksigner" verify "$out/ble-test.apk"
