// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "heap_roots.cc"
#undef protected
#undef private

using namespace toit;

extern Program loaded_program;
extern Object* arbitrary_reference();

// Observe destruction through the base pointer used by the queue. The
// concrete VM classes still supply the lambda and keep_after_callback.
template <class Node>
class ObservedNode : public Node {
 public:
  ObservedNode(Instance* key, Object* lambda, ObjectHeap* heap, bool* destroyed)
      : Node(key, lambda, heap), destroyed_(destroyed) {}
  ~ObservedNode() override { *destroyed_ = true; }

 private:
  bool* destroyed_;
};

static void check_delivery(ObjectHeap* heap) {
  loaded_program.roots_[Program::null_object_INDEX] = arbitrary_reference();
  CXXV_ASSERT(heap->next_finalizer_to_run() == loaded_program.null_object(), "empty queue returns program null");
  Object* lambda = arbitrary_reference();
  bool weak = nondet_bool();
  bool destroyed = false;
  CallableFinalizerNode* head;
  if (weak) {
    head = new ObservedNode<WeakMapFinalizerNode>(nullptr, lambda, heap, &destroyed);
  } else {
    head = new ObservedNode<ToitFinalizerNode>(nullptr, lambda, heap, &destroyed);
  }
  CXXV_ASSUME(head != nullptr);
  heap->queue_finalizer(head);
  WeakMapFinalizerNode tail(nullptr, arbitrary_reference(), heap);
  bool has_tail = nondet_bool();
  if (has_tail) heap->queue_finalizer(&tail);

  WeakMapFinalizerNode existing(nullptr, arbitrary_reference(), heap);
  bool registered = nondet_bool();
  if (registered) heap->registered_callback_finalizers_.prepend(&existing);

  CXXV_ASSERT(heap->next_finalizer_to_run() == lambda, "delivery returns the head callback");
  CXXV_ASSERT(destroyed == !weak, "only the ordinary callback is destroyed");
  if (weak) {
    CXXV_ASSERT(heap->registered_callback_finalizers_.remove_first() == head, "weak callback re-registers first");
    delete head;
  }
  if (registered) {
    CXXV_ASSERT(heap->registered_callback_finalizers_.remove_first() == &existing, "existing registration survives");
  }
  CXXV_ASSERT(heap->registered_callback_finalizers_.is_empty(), "exact registered callbacks");
  if (has_tail) {
    CXXV_ASSERT(heap->runnable_finalizers_.remove_first() == &tail, "pending successor survives");
  }
  CXXV_ASSERT(!heap->has_finalizer_to_run(), "all runnable callbacks accounted for");
}

static void check_removal(ObjectHeap* heap) {
  // The callback list may contain multiple registrations for the key.
  // Enumerate every pattern of matches across three consecutive nodes.
  uword header = (static_cast<uword>(nondet_ushort()) & 0xffc0) | (2 * INSTANCE_TAG);
  Object* slot = reinterpret_cast<Object*>(header | 32);
  Object* other_slot = reinterpret_cast<Object*>(header | 32);
  auto key = Instance::cast(HeapObject::from_address(reinterpret_cast<uword>(&slot)));
  auto other_key = Instance::cast(HeapObject::from_address(reinterpret_cast<uword>(&other_slot)));
  auto& list = heap->registered_callback_finalizers_;
  const int count = 3;
  bool destroyed[count] = {};
  bool matches[count];
  CallableFinalizerNode* nodes[count];
  for (int i = 0; i < count; i++) {
    matches[i] = nondet_bool();
    Instance* node_key = matches[i] ? key : other_key;
    if (nondet_bool()) {
      nodes[i] = new ObservedNode<WeakMapFinalizerNode>(node_key, nullptr, heap, &destroyed[i]);
    } else {
      nodes[i] = new ObservedNode<ToitFinalizerNode>(node_key, nullptr, heap, &destroyed[i]);
    }
    CXXV_ASSUME(nodes[i] != nullptr);
    list.append(nodes[i]);
  }
  heap->remove_callable_finalizer(key);
  CXXV_ASSERT(reinterpret_cast<uword>(slot) == header, "removal clears only the key flag");
  CXXV_ASSERT(reinterpret_cast<uword>(other_slot) == (header | 32), "other key remains active");
  FinalizerNode* last = nullptr;
  for (int i = 0; i < count; i++) {
    CXXV_ASSERT(destroyed[i] == matches[i], "destroy exactly the registrations for the key");
    if (!matches[i]) last = nodes[i];
  }
  CXXV_ASSERT(list.last() == last, "tail is the final surviving registration");
  // An empty FIFO reports no last element even if its insertion pointer
  // still refers to a deleted node. Exercise that pointer on every path.
  WeakMapFinalizerNode marker(other_key, nullptr, heap);
  list.append(&marker);
  for (int i = 0; i < count; i++) {
    if (!matches[i]) {
      CXXV_ASSERT(list.remove_first() == nodes[i], "surviving registrations retain their order");
      delete nodes[i];
    }
  }
  CXXV_ASSERT(list.remove_first() == &marker, "append uses the surviving tail or empty anchor");
  CXXV_ASSERT(list.is_empty(), "no additional registrations remain");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  ObjectHeap heap(&loaded_program, nullptr, nullptr, nullptr, nullptr);
  if (nondet_bool()) check_delivery(&heap);
  else check_removal(&heap);
  // The VM heap outlives the callback operation.
  exit(0);
}
