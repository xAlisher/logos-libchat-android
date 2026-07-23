#!/usr/bin/env bash
# Build the MIX SUPERSET liblogoschat.so for Android arm64-v8a from source.
#
# The mix build is a strict superset of the standard M0 build (all 12 standard
# chat_* exports PLUS chat_get_mix_status) — it embeds the libp2p Mix protocol
# for sender anonymity (AnonComms). The app vendors THIS single .so:
# mixEnabled:false == standard behaviour, mixEnabled:true == Private routing.
#
# Deltas vs scripts/build-android-arm64.sh (see docs/build-fork-tree.md §mix):
#   - source = logos-chat branch feat/logos-testnetv02-mix (nwaku → logos-delivery
#     mix fork; nwaku deps via nimble `nimbledeps/pkgs2`, not vendored submodules)
#   - rust-bundle = libchat only (rln dropped from Cargo.toml)
#   - rln linked separately: zerokit v2.0.2 STATELESS static librln_v2.0.2.a
#   - Nim define -d:libp2p_mix_experimental_exit_is_dest
#   - link: --passL:librln_v2.0.2.a --passL:-Wl,--allow-multiple-definition
#
# Requirements: Android NDK r27 (ANDROID_NDK_HOME), rustup + aarch64-linux-android,
#   make cmake gcc git patch perl (+ nimble deps fetched over git).
# Output: $OUT_DIR/{liblogoschat.so, libc++_shared.so} (stripped) + SHA256SUMS
set -euo pipefail

LOGOS_CHAT_COMMIT=${LOGOS_CHAT_COMMIT:-6b4d83a4b684b9856543bc1af811b5f069ff1377}
LOGOS_CHAT_URL=${LOGOS_CHAT_URL:-https://github.com/logos-messaging/logos-chat}
MIX_RLN_VERSION=${MIX_RLN_VERSION:-v2.0.2}
BUILD_DIR=${BUILD_DIR:-$HOME/logos-chat-mix-build}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-$REPO_DIR/out/arm64-v8a-mix}

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to an NDK r27 install}"
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
TC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
CLANG=$TC/bin/aarch64-linux-android30-clang
STRIP=$TC/bin/llvm-strip
[ -x "$CLANG" ] || { echo "NDK clang not found: $CLANG"; exit 1; }
export PATH="$TC/bin:$HOME/.cargo/bin:$PATH"

echo "==> 1/7 clone logos-chat (mix) @ $LOGOS_CHAT_COMMIT"
if [ ! -d "$BUILD_DIR/.git" ]; then
  git clone "$LOGOS_CHAT_URL" "$BUILD_DIR"
fi
cd "$BUILD_DIR"
git fetch origin "$LOGOS_CHAT_COMMIT"
git checkout -f "$LOGOS_CHAT_COMMIT"

echo "==> 2/7 make update (submodules + in-tree Nim + vendor/.nimble)"
# NOTE: the in-tree csources build can flake under -j (race); it is idempotent —
# a second 'make update' clears it. We run single-jobs update after a -j warmup.
make -j"$(nproc)" update || make update

echo "==> 3/7 patch vendored nim-ffi (empty-event guard, nim-ffi#139)"
if ! grep -q 'len(event) > 0' vendor/nim-ffi/ffi/ffi_context.nim; then
  patch -p1 -d vendor/nim-ffi < "$REPO_DIR/patches/0001-nim-ffi-empty-event-guard.patch"
fi
grep -q 'len(event) > 0' vendor/nim-ffi/ffi/ffi_context.nim || { echo "ffi patch did not apply"; exit 1; }

echo "==> 4/7 populate nwaku nimble deps (nimbledeps/pkgs2) + arm64 nat-libs"
export PATH="$BUILD_DIR/vendor/nimbus-build-system/vendor/Nim/bin:$PATH"
( cd vendor/nwaku && make build-deps )
# Rebuild nat-libs for arm64 from the nimble package (override NAT_UNAME_M to
# suppress host -mssse3), cleaning the host .a/.o build-deps just made.
NATD=$(ls -dt "$BUILD_DIR"/vendor/nwaku/nimbledeps/pkgs2/nat_traversal-* | head -1)
rm -f "$NATD/vendor/libnatpmp-upstream/"*.a "$NATD/vendor/libnatpmp-upstream/"*.o
rm -rf "$NATD/vendor/miniupnp/miniupnpc/build"
make -C vendor/nwaku rebuild-nat-libs-nimbledeps CC="$CLANG" NAT_UNAME_M=aarch64

echo "==> 5/7 cross-build rust-bundle (libchat only) + zerokit $MIX_RLN_VERSION stateless librln"
export CC_aarch64_linux_android=$CLANG
export CXX_aarch64_linux_android=$TC/bin/aarch64-linux-android30-clang++
export AR_aarch64_linux_android=$TC/bin/llvm-ar
export RANLIB_aarch64_linux_android=$TC/bin/llvm-ranlib
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$CLANG
CARGO_TARGET_DIR=rust-bundle/target \
  cargo build --release --target aarch64-linux-android --manifest-path rust-bundle/Cargo.toml
RUST_BUNDLE=$BUILD_DIR/rust-bundle/target/aarch64-linux-android/release/liblogoschat_rust_bundle.a
[ -f "$RUST_BUNDLE" ] || { echo "rust bundle missing"; exit 1; }
( cd vendor/nwaku/vendor/zerokit/rln && \
  RUSTFLAGS="-Ccodegen-units=1" cargo build --release --target aarch64-linux-android \
    --no-default-features --features stateless )
MIX_LIBRLN=$BUILD_DIR/vendor/nwaku/librln_${MIX_RLN_VERSION}.a
cp "$BUILD_DIR/vendor/nwaku/vendor/zerokit/target/aarch64-linux-android/release/librln.a" "$MIX_LIBRLN"

echo "==> 6/7 Nim cross-compile MIX liblogoschat.so"
GIT_VERSION=$(git describe --abbrev=6 --always --tags)
OUTDIR_SO=build/android/arm64-v8a
mkdir -p "$OUTDIR_SO"
./vendor/nimbus-build-system/scripts/env.sh nim c \
  --out:"$OUTDIR_SO/liblogoschat.so" \
  --app:lib --noMain --threads:on --opt:speed --mm:refc \
  --nimMainPrefix:liblogoschat \
  --cpu:arm64 --os:android -d:androidNDK -d:chronosEventEngine=epoll \
  -d:libp2p_mix_experimental_exit_is_dest \
  --cc:clang \
  --clang.path:"$TC/bin" \
  --clang.exe:aarch64-linux-android30-clang \
  --clang.linkerexe:aarch64-linux-android30-clang \
  --passC:--sysroot="$TC/sysroot" --passL:--sysroot="$TC/sysroot" \
  --cincludes:"$TC/sysroot/usr/include" \
  -d:chronicles_log_level=INFO -d:chronicles_enabled=on \
  -d:git_version="\"$GIT_VERSION\"" \
  --path:src --path:vendor/nim-ffi \
  --passL:"$RUST_BUNDLE" \
  --passL:"$MIX_LIBRLN" --passL:"-Wl,--allow-multiple-definition" \
  --passL:-lm --passL:-llog --passL:-lc++_shared \
  library/liblogoschat.nim

mkdir -p "$OUT_DIR"
cp "$OUTDIR_SO/liblogoschat.so" "$OUT_DIR/"
cp "$TC/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT_DIR/"
"$STRIP" --strip-unneeded "$OUT_DIR/liblogoschat.so"

echo "==> 7/7 verify"
file "$OUT_DIR/liblogoschat.so"
file "$OUT_DIR/liblogoschat.so" | grep -q 'ARM aarch64' || { echo "not an arm64 ELF"; exit 1; }
SYMS=$("$TC/bin/llvm-nm" -D --defined-only "$OUT_DIR/liblogoschat.so" | grep -cE ' (chat_[a-z_]+|set_event_callback)$')
echo "    exported chat FFI symbols: $SYMS (expect 13: 12 standard + chat_get_mix_status)"
[ "$SYMS" -ge 13 ] || { echo "expected 13 chat FFI exports (mix superset)"; exit 1; }
"$TC/bin/llvm-nm" -D --defined-only "$OUT_DIR/liblogoschat.so" | grep -q ' chat_get_mix_status$' \
  || { echo "chat_get_mix_status missing — not a mix build"; exit 1; }
"$TC/bin/llvm-readelf" -d "$OUT_DIR/liblogoschat.so" | grep -q 'libc++_shared.so' \
  || { echo "libc++_shared.so missing from DT_NEEDED"; exit 1; }

( cd "$OUT_DIR" && sha256sum *.so > SHA256SUMS && cat SHA256SUMS )
echo "OK (mix superset): $OUT_DIR"
