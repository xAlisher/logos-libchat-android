# logos-libchat-android

**Build Android apps using [Logos Chat](https://github.com/logos-messaging/logos-chat) — X3DH/double-ratchet private chat over an embedded Logos Messaging node.**

This repo packages `liblogoschat` cross-compiled for Android **arm64-v8a**: the build pipeline
(every wall documented), the source patches it needs, and the prebuilt `.so` artifacts. An app
using it runs its own Logos Chat client on the phone — wire-compatible with desktop Basecamp
`chat_module` (same cluster-2 network, same `logos_chatintro_1_` intro bundles, same event
semantics). Sibling of
[logos-libdelivery-android](https://github.com/xAlisher/logos-libdelivery-android) — same build
lineage, but liblogoschat **embeds its own node** (it replaces liblogosdelivery; RLN is linked
inside statically, so there is no separate `librln.so`).

**Upstream pin:** `logos-messaging/logos-chat` @
[`53302e4`](https://github.com/logos-messaging/logos-chat/commit/53302e4373755b72391727de3d5d2b30e1239dbb)
(the revision pinned by the desktop chat module). Standard (non-mix) build.

## What's in the box

```
prebuilt/arm64-v8a/     liblogoschat.so      — the chat client + embedded node (Nim + Rust, stripped)
                        libc++_shared.so     — NDK C++ runtime (declared dependency, load it first)
include/                liblogoschat.h       — the C FFI surface (12 functions)
patches/                source patches the build needs (see docs/BUILD.md)
scripts/                build-android-arm64.sh — full from-source rebuild
docs/BUILD.md           how the build works and every wall it clears
docs/build-fork-tree.md the discovery log (every idea, wall, exact fix command)
```

## The FFI surface (12 exports)

`chat_new`, `chat_start`, `chat_stop`, `chat_destroy`, `set_event_callback`, `chat_get_id`,
`chat_get_identity`, `chat_create_intro_bundle`, `chat_list_conversations`,
`chat_get_conversation`, `chat_new_private_conversation`, `chat_send_message` — see
`include/liblogoschat.h`. `chat_new` takes a config JSON (`{"name":"..."}` alone joins the
default Logos.dev fleet, cluster 2 / shard 1).

Usage invariants that matter (verified against source):

- Register `set_event_callback` **before** `chat_start` or early pushes are lost.
- Callbacks fire synchronously on the lib's FFI thread; `msg` is **not** NUL-terminated —
  copy `(msg, len)` immediately, never call back into the lib from inside a callback.
- The lib does not persist anything — identity, ratchet state and conversations die with the
  process.

## Quick start (smoke test on a device)

```bash
# from the repo root, with ANDROID_NDK_HOME set
CLANG=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang
$CLANG -o smoke scripts/smoke.c
adb push smoke prebuilt/arm64-v8a/liblogoschat.so prebuilt/arm64-v8a/libc++_shared.so /data/local/tmp/lchat/
adb shell 'cd /data/local/tmp/lchat && chmod +x smoke && LD_LIBRARY_PATH=. ./smoke'
# prints identity + a logos_chatintro_1_... intro bundle from a live node
```

## Rebuild from source

`scripts/build-android-arm64.sh` — see [docs/BUILD.md](docs/BUILD.md) for what each step does.
CI (`.github/workflows/build.yml`) runs the same script on `ubuntu-latest`.

## Consumers

[logos-chat-android](https://github.com/xAlisher/logos-chat-android) — React Native chat app
(in development).

## License

MIT (this repo's build glue). Upstream logos-chat is MIT/Apache-2.0 dual-licensed.
