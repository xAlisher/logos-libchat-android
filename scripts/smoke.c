// smoke.c — on-device smoke test for liblogoschat.so (arm64-v8a).
//
// dlopens ./liblogoschat.so, creates a chat client ({"name":"smoke"} — default
// Logos.dev fleet ENRs, cluster 2 / shard 1), registers the event callback
// BEFORE chat_start (invariant), starts the node, and asks for an intro bundle.
//
// SUCCESS = a printed "logos_chatintro_1_..." string ("SMOKE OK").
//
// Build:
//   $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang \
//     -o smoke smoke.c
// Run:
//   adb push smoke liblogoschat.so libc++_shared.so /data/local/tmp/lchat/
//   adb shell 'cd /data/local/tmp/lchat && chmod +x smoke && LD_LIBRARY_PATH=. ./smoke'

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData);
typedef void *(*chat_new_t)(const char *, FFICallBack, void *);
typedef int (*chat_call_t)(void *, FFICallBack, void *);
typedef void (*set_event_callback_t)(void *, FFICallBack, void *);

static volatile int g_done = 0;
static volatile int g_ret = -1;
static char g_resp[16384];

// Response callback: msg is NOT NUL-terminated — copy (msg,len) immediately.
static void cb(int ret, const char *msg, size_t len, void *ud) {
  const char *tag = (const char *)ud;
  size_t n = len < sizeof(g_resp) - 1 ? len : sizeof(g_resp) - 1;
  g_resp[0] = 0;
  if (msg && n) memcpy(g_resp, msg, n);
  g_resp[n] = 0;
  printf("[cb:%s] ret=%d len=%zu msg=%s\n", tag, ret, (size_t)len, g_resp);
  fflush(stdout);
  g_ret = ret;
  g_done = 1;
}

static void event_cb(int ret, const char *msg, size_t len, void *ud) {
  (void)ud;
  char buf[4096];
  size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
  buf[0] = 0;
  if (msg && n) memcpy(buf, msg, n);
  buf[n] = 0;
  printf("[event] ret=%d len=%zu %s\n", ret, (size_t)len, buf);
  fflush(stdout);
}

// Wait up to timeout_s for the last async call's response callback.
static int wait_done(int timeout_s) {
  for (int i = 0; i < timeout_s * 10; i++) {
    if (g_done) { g_done = 0; return 0; }
    usleep(100000);
  }
  fprintf(stderr, "TIMEOUT waiting for callback\n");
  return 1;
}

int main(void) {
  alarm(180); // hard watchdog: kill the process if anything hangs

  void *h = dlopen("./liblogoschat.so", RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
  printf("dlopen OK\n");

  chat_new_t chat_new_f = (chat_new_t)dlsym(h, "chat_new");
  chat_call_t chat_start_f = (chat_call_t)dlsym(h, "chat_start");
  chat_call_t chat_bundle_f = (chat_call_t)dlsym(h, "chat_create_intro_bundle");
  chat_call_t chat_stop_f = (chat_call_t)dlsym(h, "chat_stop");
  chat_call_t chat_destroy_f = (chat_call_t)dlsym(h, "chat_destroy");
  set_event_callback_t set_event_f = (set_event_callback_t)dlsym(h, "set_event_callback");
  if (!chat_new_f || !chat_start_f || !chat_bundle_f || !set_event_f) {
    fprintf(stderr, "dlsym failed: %s\n", dlerror());
    return 3;
  }
  printf("dlsym OK (chat_new/chat_start/chat_create_intro_bundle/set_event_callback)\n");

  void *ctx = chat_new_f("{\"name\":\"smoke\"}", cb, (void *)"new");
  if (!ctx) { fprintf(stderr, "chat_new returned NULL\n"); return 4; }
  if (wait_done(60)) return 5;
  printf("chat_new OK ctx=%p\n", ctx);

  // Invariant: register the persistent event callback BEFORE chat_start.
  set_event_f(ctx, event_cb, NULL);
  printf("set_event_callback OK\n");

  chat_start_f(ctx, cb, (void *)"start");
  if (wait_done(90)) return 6;
  if (g_ret != 0) { fprintf(stderr, "chat_start failed\n"); return 6; }
  printf("chat_start OK\n");

  chat_bundle_f(ctx, cb, (void *)"bundle");
  if (wait_done(60)) return 7;
  if (g_ret != 0 || strncmp(g_resp, "logos_chatintro_1_", 18) != 0) {
    fprintf(stderr, "SMOKE FAIL: no logos_chatintro_1_ bundle (ret=%d resp=%.60s)\n", g_ret, g_resp);
    return 8;
  }
  printf("SMOKE OK bundle=%s\n", g_resp);
  fflush(stdout);

  if (chat_stop_f) { chat_stop_f(ctx, cb, (void *)"stop"); wait_done(20); }
  if (chat_destroy_f) { chat_destroy_f(ctx, cb, (void *)"destroy"); wait_done(20); }
  return 0;
}
