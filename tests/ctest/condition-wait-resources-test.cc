// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Checks that ConditionWaitResources either owns a complete set of
// platform resources or none at all, whichever platform allocation fails.

#include <cstdio>
#include <cstdlib>
#include <initializer_list>

#include "../../src/os_condition_wait.h"

// Unlike assert, CHECK also evaluates its condition when NDEBUG is defined.
// Several conditions allocate resources, so they must always run.
#define CHECK(cond) do { \
  if (!(cond)) { \
    std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
    std::abort(); \
  } \
} while (false)

namespace {

struct FakePlatform {
  struct Resource { bool used; bool timer; void* arg; };
  using Signal = Resource*;
  using Timer = Resource*;
  using Callback = void (*)(void*);
  static int attempts;
  static int fail_at;
  static int active;
  // The Toit runtime linked into this test forbids a throwing operator new,
  // so resources come from a small static pool.
  static Resource pool[8];

  static Resource* create(bool timer, void* arg) {
    if (++attempts == fail_at) return nullptr;
    for (Resource& resource : pool) {
      if (resource.used) continue;
      resource = Resource{true, timer, arg};
      active++;
      return &resource;
    }
    CHECK(false);
    return nullptr;
  }
  static void release(Resource* resource) {
    CHECK(resource->used);
    resource->used = false;
    active--;
  }
  static Signal create_signal() { return create(false, nullptr); }
  static Timer create_timer(Callback callback, void* arg) {
    CHECK(callback != nullptr);
    return create(true, arg);
  }
  static void delete_signal(Signal signal) {
    CHECK(!signal->timer);
    release(signal);
  }
  static void delete_timer(Timer timer) {
    CHECK(timer->timer);
    release(timer);
  }
};

FakePlatform::Resource FakePlatform::pool[8];
int FakePlatform::attempts = 0;
int FakePlatform::fail_at = 0;
int FakePlatform::active = 0;

using Resources = toit::ConditionWaitResources<FakePlatform>;

// The fallback instance must support constant initialization in thread-local
// storage, like the per-thread fallback on ESP32.
__thread Resources fallback{};

void callback(void*) {}

void check_empty(const Resources& resources) {
  CHECK(resources.wake == nullptr);
  CHECK(resources.callback_complete == nullptr);
  CHECK(resources.timer == nullptr);
  CHECK(FakePlatform::active == 0);
}

}  // namespace

int main() {
  check_empty(fallback);
  int cases = 0;
  for (bool preexisting_wake : {false, true}) {
    int allocations = preexisting_wake ? 2 : 3;
    for (int failure = 1; failure <= allocations; failure++) {
      Resources resources{};
      FakePlatform::fail_at = 0;
      if (preexisting_wake) CHECK(resources.initialize_wake());
      FakePlatform::fail_at = FakePlatform::attempts + failure;
      CHECK(!resources.initialize(callback));
      check_empty(resources);
      resources.dispose();
      check_empty(resources);

      // Retrying after a failed preparation owns exactly one complete set.
      FakePlatform::fail_at = 0;
      CHECK(resources.initialize(callback));
      CHECK(FakePlatform::active == 3);
      CHECK(resources.timer->arg == &resources);
      int attempts = FakePlatform::attempts;
      CHECK(resources.initialize(callback));
      CHECK(resources.initialize_wake());
      CHECK(FakePlatform::attempts == attempts);
      resources.dispose();
      resources.dispose();
      check_empty(resources);
      cases++;
    }
  }
  std::printf("condition-wait-resources: %d cases passed\n", cases);
  return 0;
}
