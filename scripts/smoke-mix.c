// smoke-mix.c — on-device smoke test for the MIX SUPERSET liblogoschat.so.
//
// Like smoke.c, but boots with {"name":"smoke-mix","mixEnabled":true,...} (the
// AnonComms testnet preset) and, after chat_start, calls the mix-only export
// chat_get_mix_status and prints the JSON
// {"mixEnabled":bool,"mixReady":bool,"mixPoolSize":int,"minPoolSize":int}.
//
// SUCCESS = an intro bundle ("SMOKE OK") + a printed mix status line. Whether
// mixReady is true / the pool is non-empty depends on the live testnet mix pool
// being reachable — the point of THIS test is that the mix export resolves and
// returns well-formed status on the arm64 device (the build is a real mix build).
//
// Build:
//   $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang \
//     -o smoke-mix smoke-mix.c
// Run:
//   adb push smoke-mix liblogoschat.so libc++_shared.so /data/local/tmp/lchat/
//   adb shell 'cd /data/local/tmp/lchat && chmod +x smoke-mix && LD_LIBRARY_PATH=. ./smoke-mix'

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData);
typedef void *(*chat_new_t)(const char *, FFICallBack, void *);
typedef int (*chat_call_t)(void *, FFICallBack, void *);
typedef void (*set_event_callback_t)(void *, FFICallBack, void *);

// The exact AnonComms mix preset the desktop chat_module_mix uses (shardId 0,
// cluster 2, the two vaclab testnet kad bootstrap nodes) minus rlnKeystoreSource.
static const char *MIX_CONFIG =
    "{\"name\":\"smoke-mix\",\"clusterId\":2,\"shardId\":0,\"mixEnabled\":true,"
    "\"minMixPoolSize\":4,\"mixNodes\":[],"
    "\"kadBootstrapNodes\":["
    "\"/dns4/node-01.ih-eu-mda1.misc.vaclab.status.im/tcp/30304/p2p/16Uiu2HAm8PDGahpTZ86SKxBqFodPVxpGonXLucUR9bscFWxqJuZr\","
    "\"/dns4/node-03.ih-eu-mda1.misc.vaclab.status.im/tcp/30304/p2p/16Uiu2HAmMgeAACqTTEKVuyBmbtyAqg6qznevmyF5k6qRcL6eXsqS\"],"
    "\"staticPeers\":["
    "\"/dns4/node-01.ih-eu-mda1.misc.vaclab.status.im/tcp/30304/p2p/16Uiu2HAm8PDGahpTZ86SKxBqFodPVxpGonXLucUR9bscFWxqJuZr\","
    "\"/dns4/node-03.ih-eu-mda1.misc.vaclab.status.im/tcp/30304/p2p/16Uiu2HAmMgeAACqTTEKVuyBmbtyAqg6qznevmyF5k6qRcL6eXsqS\"]}";

static volatile int g_done = 0;
static volatile int g_ret = -1;
static char g_resp[16384];

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

static int wait_done(int timeout_s) {
  for (int i = 0; i < timeout_s * 10; i++) {
    if (g_done) { g_done = 0; return 0; }
    usleep(100000);
  }
  fprintf(stderr, "TIMEOUT waiting for callback\n");
  return 1;
}

int main(void) {
  alarm(240);

  void *h = dlopen("./liblogoschat.so", RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
  printf("dlopen OK\n");

  chat_new_t chat_new_f = (chat_new_t)dlsym(h, "chat_new");
  chat_call_t chat_start_f = (chat_call_t)dlsym(h, "chat_start");
  chat_call_t chat_bundle_f = (chat_call_t)dlsym(h, "chat_create_intro_bundle");
  chat_call_t chat_mix_f = (chat_call_t)dlsym(h, "chat_get_mix_status");
  chat_call_t chat_stop_f = (chat_call_t)dlsym(h, "chat_stop");
  chat_call_t chat_destroy_f = (chat_call_t)dlsym(h, "chat_destroy");
  set_event_callback_t set_event_f = (set_event_callback_t)dlsym(h, "set_event_callback");
  if (!chat_new_f || !chat_start_f || !chat_bundle_f || !set_event_f) {
    fprintf(stderr, "dlsym failed: %s\n", dlerror());
    return 3;
  }
  if (!chat_mix_f) {
    fprintf(stderr, "MIX FAIL: chat_get_mix_status not exported — not a mix build\n");
    return 3;
  }
  printf("dlsym OK (+ chat_get_mix_status — mix superset confirmed)\n");

  void *ctx = chat_new_f(MIX_CONFIG, cb, (void *)"new");
  if (!ctx) { fprintf(stderr, "chat_new returned NULL\n"); return 4; }
  if (wait_done(60)) return 5;
  printf("chat_new OK ctx=%p\n", ctx);

  set_event_f(ctx, event_cb, NULL);
  printf("set_event_callback OK\n");

  chat_start_f(ctx, cb, (void *)"start");
  if (wait_done(120)) return 6;
  if (g_ret != 0) { fprintf(stderr, "chat_start failed\n"); return 6; }
  printf("chat_start OK\n");

  // Give mix discovery a moment, then poll status a few times.
  for (int i = 0; i < 6; i++) {
    chat_mix_f(ctx, cb, (void *)"mix_status");
    if (wait_done(30)) return 9;
    printf("MIX STATUS [%d]: %s\n", i, g_resp);
    fflush(stdout);
    if (i < 5) sleep(10);
  }

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
