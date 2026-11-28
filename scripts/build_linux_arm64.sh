#!/usr/bin/env bash
# Cross-compile the harbor Rust extension for aarch64 Linux (glibc) and export
# the "Linux ARM64" preset to build/linux-arm64/.
#
# Needs (all user-level, no root):
#   rustup target add --toolchain 1.94.0 aarch64-unknown-linux-gnu
#   zig                 (pip install --user ziglang, or a distro package; used as the linker)
#   Godot arm64 Linux export templates for the editor version
#     -> ~/.local/share/godot/export_templates/<version>/{linux_debug,linux_release}.arm64
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
project=$PWD
cargo_bin=${CARGO_BIN:-cargo}
# Prefer the rustup proxy so the "+1.94.0" toolchain pin below works even when a
# distro cargo shadows it on PATH.
if [[ -z "${CARGO_BIN:-}" && -x "$HOME/.cargo/bin/cargo" ]]; then
  cargo_bin="$HOME/.cargo/bin/cargo"
fi
godot_bin=${GODOT_BIN:-godot}
target_dir="$project/rust/target"
target=aarch64-unknown-linux-gnu

# zig is the cross linker: it ships its own glibc sysroots, so no distribution
# cross-gcc packages and no root are required. It needs a writable cache dir.
zig_bin=${ZIG_BIN:-zig}
if ! command -v "$zig_bin" >/dev/null 2>&1; then
  printf 'zig not found (%s); install with `pip install --user ziglang` and put it on PATH\n' "$zig_bin" >&2
  exit 1
fi
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$project/build/zig-cache}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$project/build/zig-cache/local}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

# 2.28 keeps the .so loadable on older aarch64 distributions.
glibc_floor=${HARBOR_ARM64_GLIBC:-2.28}
linker="$project/build/zig-aarch64-linux-gnu-cc"
printf '#!/bin/sh\nexec "%s" cc -target aarch64-linux-gnu.%s "$@"\n' "$(command -v "$zig_bin")" "$glibc_floor" > "$linker"
chmod +x "$linker"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$linker"

"$cargo_bin" +1.94.0 build --locked --release \
  --manifest-path rust/Cargo.toml --target-dir "$target_dir" --target "$target"
install -m 755 "$target_dir/$target/release/libharbor.so" native/libharbor_linux_arm64.so

mkdir -p build/linux-arm64
touch build/.gdignore
"$godot_bin" --headless --path "$project" --import
"$godot_bin" --headless --path "$project" --export-release "Linux ARM64" "$project/build/linux-arm64/harbor-alert.arm64"

printf 'Done: build/linux-arm64/\n'
