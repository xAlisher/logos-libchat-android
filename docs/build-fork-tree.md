# liblogoschat Android build — fork-tree log

Protocol: `~/fieldcraft/protocols/red-team-fork-tree.md` — every idea, wall, and **exact fix
command**, in order. Sibling log (the proven map this build follows):
[logos-libdelivery-android/docs/BUILD.md](https://github.com/xAlisher/logos-libdelivery-android/blob/main/docs/BUILD.md).

Target: `logos-messaging/logos-chat` @ `53302e4373755b72391727de3d5d2b30e1239dbb`
(the rev pinned by desktop `chat_module`), standard (non-mix) build, arm64-v8a,
NDK r27 (27.1.12297006), Nim 2.2.4, host = wild (Ubuntu, x86_64).

---

## Session 2026-07-23

### N0 — environment survey
- Nim 2.2.4 at `~/.nimble/bin/nim` (not on PATH); the leftover `~/.nimble/bin/nimble` is a
  broken binary ("required file not found") — expected: `make deps` re-bootstraps it.
- rustup target `aarch64-linux-android` already installed; `cross` + Docker present.
- NDK `~/Android/Sdk/ndk/27.1.12297006` with `aarch64-linux-android30-clang`.
- 220 G free on `/extra`; building under `/extra/tmp/logos-chat-build`, `TMPDIR=/extra/tmp`.

### W1 — adb device unauthorized (CLEARED)
- **Wall:** `adb devices` → `RF8RA0M127K  unauthorized` even after `adb kill-server`.
  The phone was waiting for the "Allow USB debugging?" tap.
- **Fix:** `adb kill-server; adb devices` restarted the daemon → phone re-prompted →
  authorized a few minutes later. Retry-later worked; no config change needed.

### N1 — upstream anatomy (differs from logos-delivery in the important way)
- logos-chat is a **nimbus-build-system** repo (all Nim deps are vendored git submodules under
  `vendor/`, plus nwaku's own `vendor/nwaku/vendor/*`), **not** nimble.lock/nimbledeps like
  logos-delivery. Consequences:
  - nim-ffi is `vendor/nim-ffi` @ v0.1.3 (the buggy rev, `unsafeAddr event[0]` at
    `ffi/ffi_context.nim:39`). libdelivery patch 0001 **applies cleanly** with
    `patch -p1` inside `vendor/nim-ffi` (verified with `--dry-run`).
  - `make update` = `update-common` (submodule sync + **`git reset --hard` foreach** —
    wipes any vendor patch) + `deps-common` (builds the in-tree Nim compiler
    `vendor/nimbus-build-system/vendor/Nim` + creates `vendor/.nimble` links).
    **Patch order rule: patch vendor/nim-ffi only AFTER `make update`.**
  - Nim compiles must run through `vendor/nimbus-build-system/scripts/env.sh` (puts the
    in-tree Nim on PATH, sets NIMBLE_DIR).
- `make liblogoschat` = `build-rust-bundle` (`$(MAKE) -C vendor/nwaku librln` +
  `cargo build --release --manifest-path rust-bundle/Cargo.toml` →
  `rust-bundle/target/release/liblogoschat_rust_bundle.a`) + `build-waku-nat`
  (`$(MAKE) -C vendor/nwaku nat-libs`) + `nim liblogoschat ... --passL:<bundle.a> --passL:-lm`.
- **No Android toolchain wiring exists in logos-chat's `config.nims`** (logos-delivery had an
  `if defined(android):` block setting `clang.path/exe/linkerexe`, sysroot, cincludes). Our
  build passes those switches on the nim command line instead.
- Header `library/liblogoschat.h` in the pinned rev has exactly the 12 standard functions
  (no `chat_get_mix_status` — that's the mix build).

### N2 — rust-bundle cross-compile: WIN on first try, plain cargo (no cross/Docker)
- **Risk scouted first:** `cargo tree -i openssl-sys` → pulled via
  `rusqlite(bundled-sqlcipher-vendored-openssl) → libsqlite3-sys → openssl-src`
  (builds OpenSSL from source), and `cargo tree -i wasmer` → wasmer 4.4 via
  `rln → ark-circom`. Both are classic cross-compile walls — neither fired.
- **The move (exact, worked first try, 1m50s):**
  ```bash
  export ANDROID_NDK_HOME=~/Android/Sdk/ndk/27.1.12297006 ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
  TC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64
  export PATH="$TC/bin:$HOME/.cargo/bin:$PATH"   # openssl-src needs the toolchain on PATH
  export CC_aarch64_linux_android=$TC/bin/aarch64-linux-android30-clang
  export CXX_aarch64_linux_android=$TC/bin/aarch64-linux-android30-clang++
  export AR_aarch64_linux_android=$TC/bin/llvm-ar
  export RANLIB_aarch64_linux_android=$TC/bin/llvm-ranlib
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$TC/bin/aarch64-linux-android30-clang
  CARGO_TARGET_DIR=rust-bundle/target cargo build --release \
    --target aarch64-linux-android --manifest-path rust-bundle/Cargo.toml
  ```
- **Result:** `rust-bundle/target/aarch64-linux-android/release/liblogoschat_rust_bundle.a`,
  161 MB, objects verified `ELF 64-bit ... ARM aarch64` via `llvm-ar x` + `file`.
- **Insight:** skipped `$(MAKE) -C vendor/nwaku librln` (host-only step; downloads/builds a
  host `librln_v0.7.0.a` whose symbols the bundle already contains as an rlib). If the Nim
  link later misses rln symbols, revisit here.
- `vendor/libchat/rust_toolchain.toml` is misnamed (underscore — cargo only honors
  `rust-toolchain.toml`), so no toolchain pin applies; host stable was used.

### N3 — make update: exit 0 (~25 min, mostly the in-tree Nim compiler build)
- `make -j$(nproc) update` → submodule sync/reset + built
  `vendor/nimbus-build-system/vendor/Nim/bin/nim` (2.2.4) + `vendor/.nimble/pkgs` links.
- nim-ffi patch applied after it, as planned:
  `patch -p1 -d vendor/nim-ffi < patches/0001-nim-ffi-empty-event-guard.patch` → clean.

### N4 — nat-libs cross-build: NO -mssse3 wall here (unlike logos-delivery)
- logos-delivery's `Nat.mk` baked `-mssse3` from host `uname -m` (needed `NAT_UNAME_M=aarch64`).
  nwaku's nimbus-build-system `targets.mk` passes explicit `CFLAGS="-Os -fPIC"` instead, so a
  plain CC override suffices. Built **before any host nat-libs existed** (fresh clone), so no
  clean-first step was needed either — but the build script keeps a defensive clean.
- **Exact command:**
  `make -C vendor/nwaku CC=$TC/bin/aarch64-linux-android30-clang nat-libs`
- Verified: `natpmp.o` inside `libnatpmp.a` = `ELF 64-bit ... ARM aarch64`; same for
  `miniupnp/miniupnpc/build/libminiupnpc.a`.

### N5 — Nim cross-compile: WIN on first try (exit 0, ~4 min)
- The hypothesis that logos-delivery's android wiring transplants held completely. Since
  logos-chat's `config.nims` has no `if defined(android):` block, all toolchain switches went on
  the command line (through `vendor/nimbus-build-system/scripts/env.sh` so the in-tree Nim and
  NIMBLE_DIR apply). **Exact command:**
  ```bash
  ./vendor/nimbus-build-system/scripts/env.sh nim c \
    --out:build/android/arm64-v8a/liblogoschat.so \
    --app:lib --noMain --threads:on --opt:speed --mm:refc \
    --nimMainPrefix:liblogoschat \
    --cpu:arm64 --os:android -d:androidNDK -d:chronosEventEngine=epoll \
    --cc:clang --clang.path:"$TC/bin" \
    --clang.exe:aarch64-linux-android30-clang \
    --clang.linkerexe:aarch64-linux-android30-clang \
    --passC:--sysroot="$TC/sysroot" --passL:--sysroot="$TC/sysroot" \
    --cincludes:"$TC/sysroot/usr/include" \
    -d:chronicles_log_level=INFO -d:chronicles_enabled=on \
    -d:git_version="\"$(git describe --abbrev=6 --always --tags)\"" \
    --path:src --path:vendor/nim-ffi \
    --passL:"$RUST_BUNDLE" --passL:-lm --passL:-llog --passL:-lc++_shared \
    library/liblogoschat.nim
  ```
- **Result:** `liblogoschat.so` 34.6 MB unstripped → 24.4 MB stripped. `file` = ARM aarch64;
  `llvm-nm -D --defined-only` shows **all 12** chat FFI exports; DT_NEEDED = libm, liblog,
  **libc++_shared.so**, libdl, libc. No missing rln symbols — skipping the host `librln` step
  (N2) was correct: the rust-bundle satisfies everything.
- **Insight:** zero link walls that libdelivery hit (`-lc++_shared` was included from the start
  because the map said so; `-llog` likewise). The walls were pre-cleared by the sibling log —
  this is the fork-tree discipline paying out a second time.

### N6 — on-device smoke test: SMOKE OK (Samsung SM-G780G, Android 13)
- Build + push + run:
  ```bash
  $TC/bin/aarch64-linux-android30-clang -O2 -o smoke scripts/smoke.c
  adb shell mkdir -p /data/local/tmp/lchat
  adb push smoke prebuilt/arm64-v8a/liblogoschat.so prebuilt/arm64-v8a/libc++_shared.so /data/local/tmp/lchat/
  adb shell 'cd /data/local/tmp/lchat && chmod +x smoke && LD_LIBRARY_PATH=. ./smoke'
  ```
- **Transcript (win condition):** dlopen OK → `chat_new({"name":"smoke"})` ret=0 →
  `set_event_callback` → `chat_start` ret=0 — node started, announced
  `/ip4/192.168.1.47/tcp/50015`, dialed the 6 default Logos.dev fleet peers (clusterId=2) →
  `chat_create_intro_bundle` ret=0:
  ```
  SMOKE OK bundle=logos_chatintro_1_CiBYqJPNHm2H3Z4IPtkA492U1vIeA61IfkpejcS9yraJHRIg6OuKhwocnGN1YVNkWXkT9W6h6TxJnNzYY3Dz6EqD1GoaQPznTkXtBXFx7YsU1SU5UVgwE3ogWjTCdH_ChPKDby-rGoxX6H_ombsYv9i5Jhx1iGuhl2PZ_rkUE_X_ViNUNwo
  ```
  then clean `chat_stop` ret=0 + `chat_destroy` ret=0. Full lifecycle proven on-device.

---

## Wall summary

| # | Wall | Fix (exact) |
|---|------|-------------|
| W1 | adb `unauthorized` at session start | `adb kill-server; adb devices` → phone re-prompted → authorized minutes later |
| W2 (class, pre-cleared) | `make update` hard-resets submodules, wiping vendor patches | patch `vendor/nim-ffi` **after** `make update` |
| W3 (class, pre-cleared) | nim-ffi v0.1.3 empty-event SIGSEGV (nim-ffi#139) | `patch -p1 -d vendor/nim-ffi < patches/0001-nim-ffi-empty-event-guard.patch` |
| W4 (class, pre-cleared) | missing C++ runtime at load (`__gxx_personality_v0`) | `--passL:-lc++_shared` at link time (never patchelf) |
| W5 (class, pre-cleared) | no Android toolchain wiring in config.nims | pass `--cc:clang --clang.path/exe/linkerexe --passC/--passL:--sysroot --cincludes` on the nim command line |

Everything else that was a wall on libdelivery (nat-libs `-mssse3`, cross/Docker for rust,
nimbledeps population order) either does not exist in this repo's build system or was avoided by
following the map. Total time upstream-clone → SMOKE OK: ~1h15m.
