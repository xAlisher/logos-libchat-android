# Building liblogoschat for Android — how and why

`scripts/build-android-arm64.sh` reproduces `prebuilt/arm64-v8a/` from source. This page explains
what each step does and the walls it clears. The full discovery log (every idea, wall, exact fix
command) is [build-fork-tree.md](build-fork-tree.md). The proven sibling pipeline this adapts:
[logos-libdelivery-android/docs/BUILD.md](https://github.com/xAlisher/logos-libdelivery-android/blob/main/docs/BUILD.md).

Upstream `logos-messaging/logos-chat` @ `53302e4` has **no Android target** — this repo adds one.
Key structural difference from logos-delivery: logos-chat is a **nimbus-build-system** repo (all
Nim deps vendored as git submodules; the build system compiles its own Nim), and the Rust side
(libchat X3DH/double-ratchet + zerokit RLN) is linked as **one static rust-bundle** instead of a
separate `librln.so`.

## The pipeline

| Step | Command | What really happens |
|------|---------|---------------------|
| 1 | `git clone` @ pinned commit | Submodules come in step 2. |
| 2 | `make -j$(nproc) update` | nimbus-build-system: submodule init + **hard reset** (wipes any vendor patch — order matters), builds the in-tree Nim compiler (`vendor/nimbus-build-system/vendor/Nim`, 2.2.4), creates the `vendor/.nimble` link dir. ~25 min. |
| 3 | `patch -p1 -d vendor/nim-ffi` | The [nim-ffi#139](https://github.com/logos-messaging/nim-ffi/issues/139) empty-event guard. `vendor/nim-ffi` is pinned at v0.1.3 — every released tag has the bug (`unsafeAddr event[0]` on an empty string = nil deref → SIGSEGV on the first empty-payload event). Must run **after** step 2 (the reset). |
| 4 | `cargo build --release --target aarch64-linux-android --manifest-path rust-bundle/Cargo.toml` | Plain cargo + NDK env — no cross/Docker. Produces `liblogoschat_rust_bundle.a` (libchat + rln as rlibs, Rust std emitted once). openssl-src (via rusqlite's `bundled-sqlcipher-vendored-openssl`) needs `ANDROID_NDK_ROOT` set and the NDK toolchain `bin/` on PATH. wasmer 4.4 (via rln → ark-circom) cross-compiles fine. The upstream `$(MAKE) -C vendor/nwaku librln` step is skipped — it builds a *host* `librln.a` whose symbols the bundle already contains. |
| 5 | `make -C vendor/nwaku CC=<ndk-clang> nat-libs` | miniupnpc + libnatpmp static libs, linked by absolute path from `nat_traversal.nim` — they must be arm64. No `-mssse3` wall here (nimbus targets.mk passes explicit `CFLAGS="-Os -fPIC"`, unlike logos-delivery's Nat.mk), but the script cleans any host build first because make would consider them up to date. |
| 6 | `env.sh nim c ... library/liblogoschat.nim` | The actual cross-compile+link through the nimbus env script (in-tree Nim on PATH, NIMBLE_DIR set). logos-chat's `config.nims` has **no android block**, so the toolchain wiring is passed on the command line: `--cc:clang --clang.path/exe/linkerexe`, `--passC/--passL:--sysroot`, `--cincludes` (modeled on logos-delivery's `config.nims` `if defined(android):` section). Plus `--os:android -d:androidNDK -d:chronosEventEngine=epoll`, the rust bundle via `--passL`, and `--passL:-llog --passL:-lc++_shared`. |

Then strip (`llvm-strip --strip-unneeded`), copy `libc++_shared.so` from the NDK sysroot, verify,
SHA256SUMS.

## The patch

**`0001-nim-ffi-empty-event-guard.patch`** — identical to logos-libdelivery-android's patch 0001
(same bug, same vendored v0.1.x line; applies cleanly to the `vendor/nim-ffi` submodule).
Retirement condition: nim-ffi releases the fix (on master since pre-2026-07) **and** logos-chat
re-pins past v0.1.3.

Why `--passL:-lc++_shared` is a link flag and not an afterthought: the `.so` uses C++ exceptions
(Rust/C++ deps) but would never declare the C++ runtime → `UnsatisfiedLinkError:
__gxx_personality_v0` at load. `patchelf --add-needed` after the fact corrupts the GNU hash table
and Android's linker rejects the file (learned on libdelivery, W-fail-12/13).

## Verify (what the script checks)

- `file` = `ELF 64-bit ... ARM aarch64`
- `llvm-nm -D --defined-only` shows all **12** exports: `chat_new, chat_start, chat_stop,
  chat_destroy, set_event_callback, chat_get_id, chat_get_identity, chat_create_intro_bundle,
  chat_list_conversations, chat_get_conversation, chat_new_private_conversation,
  chat_send_message`
- `llvm-readelf -d` has `libc++_shared.so` in DT_NEEDED

## On-device smoke test

`scripts/smoke.c` — dlopens the lib, `chat_new({"name":"smoke"})` → `set_event_callback` (before
start — invariant) → `chat_start` → `chat_create_intro_bundle`. Success = a printed
`logos_chatintro_1_...` string from a live node on the phone. See the header comment for exact
build/push/run commands.

## CI

`.github/workflows/build.yml` runs the same script on `ubuntu-latest`. No setup-nim needed
(nimbus-build-system builds its own); NDK r27 via sdkmanager; rustup target add. Not bit-for-bit
reproducible vs `prebuilt/` (toolchain drift) — functional equivalence is what's checked.

## ABI status

- **arm64-v8a** — built, proven on-device (see fork-tree log for the smoke transcript).
- Nothing else. Emulators can't run the arm64 Nim `.so`; validate on a real phone.
