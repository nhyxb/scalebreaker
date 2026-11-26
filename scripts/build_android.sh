#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
project=$PWD
cargo_bin=${CARGO_BIN:-cargo}
godot_bin=${GODOT_BIN:-godot}
target_dir="$project/rust/target"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to the Android SDK directory}"
ndk=${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/29.0.14206865}
linker="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
if [[ ! -x "$linker" ]]; then
  printf 'Android NDK linker not found: %s\n' "$linker" >&2
  exit 1
fi
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker"

"$cargo_bin" +1.94.0 build --locked --manifest-path rust/Cargo.toml --target-dir "$target_dir"
"$cargo_bin" +1.94.0 build --locked --release --manifest-path rust/Cargo.toml --target-dir "$target_dir" --target aarch64-linux-android
install -m 755 "$target_dir/aarch64-linux-android/release/libharbor.so" native/libharbor_android.so

mkdir -p build
touch build/.gdignore
"$godot_bin" --headless --path "$project" --editor --import
"$godot_bin" --headless --path "$project" --export-debug "Android ARM64" "$project/build/harbor-alert-debug.apk"
