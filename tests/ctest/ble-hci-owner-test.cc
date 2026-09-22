// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/resources/ble_hci_owner.h"
#ifdef TOIT_LINUX
#include <pthread.h>
#endif

using toit::ble_hci::ControllerOwner;
static_assert(sizeof(ControllerOwner<int>) == 2 * sizeof(int*));

static void check(bool condition) { if (!condition) FATAL("HCI ownership check failed"); }

int main(int argc, char** argv) {
  ControllerOwner<int> owner;
  int first, next;
  check(!owner.claim(nullptr));
  check(!owner.release(nullptr));
  for (int iteration = 0; iteration < 1000; iteration++) {
    check(owner.claim(&first));
    check(owner.target() == &first);
    check(!owner.claim(&first));
    check(!owner.claim(&next));
    owner.detach(&next);
    check(owner.target() == &first);
    check(!owner.release(&next));
    check(!owner.release(&first));
    owner.detach(&first);
    check(owner.target() == nullptr);
    check(!owner.claim(&next));
    check(owner.release(&first));
    check(!owner.release(&first));
    check(owner.claim(&next));
    owner.detach(&first);
    check(owner.target() == &next);
    owner.detach(&next);
    check(owner.release(&next));
  }

#ifdef TOIT_LINUX
  struct Context {
    ControllerOwner<int>* owner;
    int* resource;
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
    int stage = 0;
  } context;
  context.owner = &owner;
  context.resource = &first;
  check(owner.claim(&first));
  pthread_t closing;
  check(pthread_create(&closing, nullptr, [](void* opaque) -> void* {
    auto& c = *static_cast<Context*>(opaque);
    check(pthread_mutex_lock(&c.mutex) == 0);
    c.owner->detach(c.resource);
    c.stage = 1;
    check(pthread_cond_signal(&c.changed) == 0);
    // Model teardown in progress after callbacks have stopped.
    while (c.stage != 2) check(pthread_cond_wait(&c.changed, &c.mutex) == 0);
    check(c.owner->release(c.resource));
    check(pthread_mutex_unlock(&c.mutex) == 0);
    return nullptr;
  }, &context) == 0);
  check(pthread_mutex_lock(&context.mutex) == 0);
  while (context.stage != 1) check(pthread_cond_wait(&context.changed, &context.mutex) == 0);
  check(owner.target() == nullptr);
  check(!owner.claim(&next));
  context.stage = 2;
  check(pthread_cond_signal(&context.changed) == 0);
  check(pthread_mutex_unlock(&context.mutex) == 0);
  check(pthread_join(closing, nullptr) == 0);
  check(owner.claim(&next));
  owner.detach(&next);
  check(owner.release(&next));
  check(pthread_cond_destroy(&context.changed) == 0);
  check(pthread_mutex_destroy(&context.mutex) == 0);
#endif
  return 0;
}
