# Project build notes

## Android arm64 APK

- Build from a temporary copy of the full working tree, including any uncommitted changes in the `base` submodule. Keep intermediate build output and logs outside the working tree (typically under `/tmp`). Copy only the finished APK back into the project. Remove the temporary build directory after successful packaging and delivery; retain it on failure for diagnosis.
- The launcher pins Android NDK `23.2.8568313` (r23c) in `platform/android/luajit-launcher/app/build.gradle`. If that version is not in the installed SDK, install it into the temporary build copy with the repository's `base/toolchain/Makefile`; do not change the user's SDK just for this build. Set `ANDROID_HOME`/`ANDROID_SDK_ROOT` to the installed SDK and `ANDROID_NDK_HOME` to the temporary NDK.
- Set `platform/android/luajit-launcher/local.properties` in the temporary copy to the installed SDK path. A full arm64 Rocks release build uses `TARGET=android-arm64 ... update`.
- Use `PARALLEL_JOBS=1 NINJAFLAGS=-j4` for this build. A higher top-level GNU Make job count caused LuaJIT's nested Make to fail with `read jobs pipe: Bad file descriptor`; Ninja can still use four workers.
- `make/android.mk` defaults `ANDROID_VERSION` to the Git commit count. The arm64 flavor encodes the package version as `ANDROID_VERSION * 10 + 2`. Before installing an update, compare the APK's `versionCode` with `adb shell dumpsys package org.koreader.launcher`; set `ANDROID_VERSION` high enough that the resulting package version is greater. For example, an installed code of `120422` requires at least `ANDROID_VERSION=12043`, which produces `120432`.
- Release APKs may need signing before installation. Use the same signing certificate as the installed app and compare the SHA-256 certificate digest with the prior APK before updating. Install with `adb -s <online-device-serial> install -r <apk>` to replace the package while keeping its data; do not uninstall to work around a version or signature mismatch.
- ADB wireless serials can change. Choose the currently online target from `adb devices -l` rather than reusing an old port.
