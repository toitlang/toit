// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/heap.h"
#include "../../src/heap_roots.h"

using namespace toit;

class RecordingVisitor : public RootCallback {
 public:
  void expect(Object** slot) {
    if (count_ == 5) FATAL("too many expected roots");
    slots_[count_++] = slot;
  }

  void expect_callback(CallableFinalizerNode* node) {
    expect(reinterpret_cast<Object**>(&node->key_));
    expect(&node->lambda_);
  }

  void do_roots(Object** roots, word length) override {
    if (length != 1 || visited_ >= count_) FATAL("unexpected root span");
    if (roots != slots_[visited_]) FATAL("incorrect finalizer root slot or visit order");
    *roots = replacement(visited_++);
  }

  void check() {
    if (visited_ != count_) FATAL("missing finalizer roots");
    for (int i = 0; i < count_; i++) {
      if (*slots_[i] != replacement(i)) FATAL("updated root was lost");
    }
  }

 private:
  Object** slots_[5];
  Object* replacement(int i) {
    return HeapObject::from_address(reinterpret_cast<uword>(&replacement_words_[i]));
  }
  uword replacement_words_[5] = {};
  int count_ = 0;
  int visited_ = 0;
};

static void check_queues(int ordinary_queue, int weak_queue, bool weak_first, bool has_vm) {
  ObjectHeap heap(nullptr, nullptr, nullptr, nullptr, nullptr);
  uword key_word = 0;
  auto key = reinterpret_cast<Instance*>(HeapObject::from_address(reinterpret_cast<uword>(&key_word)));
  // Different slots may initially contain the very same reference.
  ToitFinalizerNode ordinary(key, key, &heap);
  WeakMapFinalizerNode weak(key, key, &heap);
  VmFinalizerNode vm(key, &heap);
  CallableFinalizerNode* nodes[] = { &ordinary, &weak };
  int placement[] = { ordinary_queue, weak_queue };
  if (weak_first) {
    nodes[0] = &weak;
    nodes[1] = &ordinary;
    placement[0] = weak_queue;
    placement[1] = ordinary_queue;
  }
  FinalizerNodeFifo* queues[] = { &heap.registered_callback_finalizers_, &heap.runnable_finalizers_ };
  RecordingVisitor visitor;
  for (int q = 0; q < 2; q++) {
    for (int i = 0; i < 2; i++) {
      if (placement[i] != q) continue;
      queues[q]->append(nodes[i]);
      visitor.expect_callback(nodes[i]);
    }
    if (q == 0 && has_vm) {
      heap.registered_vm_finalizers_.append(&vm);
      visitor.expect(reinterpret_cast<Object**>(&vm.key_));
    }
  }
  heap.iterate_finalization_roots(&visitor);
  visitor.check();
  for (int q = 0; q < 2; q++) {
    for (int i = 0; i < 2; i++) {
      if (placement[i] == q) {
        if (queues[q]->remove_first() != nodes[i]) FATAL("callback queue order changed");
      }
    }
    if (!queues[q]->is_empty()) FATAL("extra callback after traversal");
  }
  if (heap.registered_vm_finalizers_.remove_first() != (has_vm ? &vm : nullptr) ||
      !heap.registered_vm_finalizers_.is_empty()) FATAL("VM queue changed");
}

int main() {
  for (int ordinary = -1; ordinary <= 1; ordinary++) {
    for (int weak = -1; weak <= 1; weak++) {
      for (int order = 0; order < 2; order++) {
        for (int vm = 0; vm < 2; vm++) check_queues(ordinary, weak, order != 0, vm != 0);
      }
    }
  }
}
