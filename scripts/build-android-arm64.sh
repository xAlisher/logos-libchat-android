#!/usr/bin/env bash
# Build liblogoschat.so for Android arm64-v8a from source.
#
# Reproduces the binary vendored in prebuilt/arm64-v8a/, from the pinned
# logos-chat commit plus the patch in patches/ (see docs/BUILD.md for the
# full story of why each step exists; docs/build-fork-tree.md for the
# discovery log).
#
# Requirements (Ubuntu 24.04 / GitHub Actions ubuntu-latest):
#   - Android NDK r27 (ANDROID_NDK_HOME)
#   - rustup with target aarch64-linux-android
#   - make, cmake, gcc, git, patch, perl (openssl-src)
#   - NO system Nim needed: nimbus-build-system builds its own in `make update`
#
# Output: $OUT_DIR/{liblogoschat.so, libc++_shared.so} (stripped) + SHA256SUMS
set -euo pipefail

LOGOS_CHAT_COMMIT=${LOGOS_CHAT_COMMIT:-53302e4373755b72391727de3d5d2b30e1239dbb}
LOGOS_CHAT_URL=${LOGOS_CHAT_URL:-https://github.com/logos-messaging/logos-chat}
BUILD_DIR=${BUILD_DIR:-$HOME/logos-chat-build}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-$REPO_DIR/out/arm64-v8a}

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to an NDK r27 install}"
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
TC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
CLANG=$TC/bin/aarch64-linux-android30-clang
STRIP=$TC/bin/llvm-strip
[ -x "$CLANG" ] || { echo "NDK clang not found: $CLANG"; exit 1; }
export PATH="$TC/bin:$HOME/.cargo/bin:$PATH"

echo "==> 1/6 clone logos-chat @ $LOGOS_CHAT_COMMIT"
if [ ! -d "$BUILD_DIR/.git" ]; then
  git clone "$LOGOS_CHAT_URL" "$BUILD_DIR"
fi
cd "$BUILD_DIR"
git fetch origin "$LOGOS_CHAT_COMMIT"
git checkout -f "$LOGOS_CHAT_COMMIT"

echo "==> 2/6 make update (submodules + in-tree Nim + vendor/.nimble links)"
# nimbus-build-system: update-common hard-resets every submodule (so the
# nim-ffi patch MUST come after this), then deps-common builds the vendored
# Nim compiler and creates the vendor/.nimble link dir.
make -j"$(nproc)" update

echo "==> 3/6 patch vendored nim-ffi (empty-event guard, nim-ffi#139)"
# vendor/nim-ffi is a git submodule pinned at v0.1.3 — the release with the
# empty-event SIGSEGV (unsafeAddr event[0] on a nil-data empty string).
if grep -q 'len(event) > 0' vendor/nim-ffi/ffi/ffi_context.nim; then
  echo "    already patched"
else
  patch -p1 -d vendor/nim-ffi < "$REPO_DIR/patches/0001-nim-ffi-empty-event-guard.patch"
fi
grep -q 'len(event) > 0' vendor/nim-ffi/ffi/ffi_context.nim || { echo "ffi patch did not apply"; exit 1; }

echo "==> 4/6 cross-build rust-bundle (libchat + zerokit rln) for aarch64-linux-android"
# Plain cargo with NDK toolchain env — no cross/Docker needed. openssl-src
# (pulled by rusqlite's bundled-sqlcipher-vendored-openssl) needs
# ANDROID_NDK_ROOT + the toolchain bin dir on PATH.
export CC_aarch64_linux_android=$CLANG
export CXX_aarch64_linux_android=$TC/bin/aarch64-linux-android30-clang++
export AR_aarch64_linux_android=$TC/bin/llvm-ar
export RANLIB_aarch64_linux_android=$TC/bin/llvm-ranlib
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$CLANG
CARGO_TARGET_DIR=rust-bundle/target \
  cargo build --release --target aarch64-linux-android --manifest-path rust-bundle/Cargo.toml
RUST_BUNDLE=$BUILD_DIR/rust-bundle/target/aarch64-linux-android/release/liblogoschat_rust_bundle.a
[ -f "$RUST_BUNDLE" ] || { echo "rust bundle missing: $RUST_BUNDLE"; exit 1; }

echo "==> 5/6 cross-build nwaku nat-libs (miniupnpc + libnatpmp) for arm64"
# nat_traversal.nim links these vendored .a's by absolute path; they must be
# arm64. Clean any host build first (make would consider them up to date).
NATV=vendor/nwaku/vendor/nim-nat-traversal/vendor
rm -f "$NATV/libnatpmp-upstream/"*.a "$NATV/libnatpmp-upstream/"*.o
rm -rf "$NATV/miniupnp/miniupnpc/build"
make -C vendor/nwaku CC="$CLANG" nat-libs

echo "==> 6/6 Nim cross-compile liblogoschat.so"
# logos-chat has no Android target and no android block in config.nims — the
# toolchain wiring (clang.exe/linkerexe, sysroot) is passed on the command
# line, modeled on logos-delivery's config.nims android section.
GIT_VERSION=$(git describe --abbrev=6 --always --tags)
OUTDIR_SO=build/android/arm64-v8a
mkdir -p "$OUTDIR_SO"
./vendor/nimbus-build-system/scripts/env.sh nim c \
  --out:"$OUTDIR_SO/liblogoschat.so" \
  --app:lib --noMain --threads:on --opt:speed --mm:refc \
  --nimMainPrefix:liblogoschat \
  --cpu:arm64 --os:android -d:androidNDK -d:chronosEventEngine=epoll \
  --cc:clang \
  --clang.path:"$TC/bin" \
  --clang.exe:aarch64-linux-android30-clang \
  --clang.linkerexe:aarch64-linux-android30-clang \
  --passC:--sysroot="$TC/sysroot" --passL:--sysroot="$TC/sysroot" \
  --cincludes:"$TC/sysroot/usr/include" \
  -d:chronicles_log_level=INFO -d:chronicles_enabled=on \
  -d:git_version="\"$GIT_VERSION\"" \
  --path:src --path:vendor/nim-ffi \
  --passL:"$RUST_BUNDLE" --passL:-lm --passL:-llog --passL:-lc++_shared \
  library/liblogoschat.nim

mkdir -p "$OUT_DIR"
cp "$OUTDIR_SO/liblogoschat.so" "$OUT_DIR/"
cp "$TC/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT_DIR/"
"$STRIP" --strip-unneeded "$OUT_DIR/liblogoschat.so"

echo "==> verify"
file "$OUT_DIR/liblogoschat.so"
file "$OUT_DIR/liblogoschat.so" | grep -q 'ARM aarch64' || { echo "not an arm64 ELF"; exit 1; }
SYMS=$("$TC/bin/llvm-nm" -D --defined-only "$OUT_DIR/liblogoschat.so" | grep -cE ' (chat_[a-z_]+|set_event_callback)$')
echo "    exported chat FFI symbols: $SYMS (expect 12)"
[ "$SYMS" -ge 12 ] || { echo "expected 12 chat FFI exports"; exit 1; }
# The C++ runtime must be a declared dependency (link it; patchelf corrupts GNU_HASH).
"$TC/bin/llvm-readelf" -d "$OUT_DIR/liblogoschat.so" | grep -q 'libc++_shared.so' \
  || { echo "libc++_shared.so missing from DT_NEEDED"; exit 1; }

( cd "$OUT_DIR" && sha256sum *.so > SHA256SUMS && cat SHA256SUMS )
echo "OK: $OUT_DIR"
