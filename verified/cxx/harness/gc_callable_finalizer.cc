// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "heap_roots.cc"
#include "third_party/dartino/object_memory.cc"
#include "third_party/dartino/object_memory_copying.cc"
#undef protected
#undef private

using namespace toit;
extern Program image;
GcMetadata GcMetadata::singleton_;
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a valid supplied source chunk avoids fatal errors");
  abort();
}

static bool destroyed;
class ObservedCallback : public ToitFinalizerNode {
 public:
  using ToitFinalizerNode::ToitFinalizerNode;
  ~ObservedCallback() override { destroyed = true; }
};

class Oracle : public LivenessOracle {
 public:
  HeapObject* key;
  SemiSpace* source;
  unsigned active_queries = 0, live_queries = 0;
  bool has_active_finalizer(HeapObject* o) override {
    CXXV_ASSERT(o == key && !destroyed && active_queries == 0, "inspect the registered key once");
    ++active_queries;
    return source->SemiSpace::has_active_finalizer(o);
  }
  bool is_alive(HeapObject* o) override {
    CXXV_ASSERT(o == key && o->has_active_finalizer() && active_queries == 1 && live_queries == 0,
                "test reachability only after verifying the active flag");
    ++live_queries;
    return source->SemiSpace::is_alive(o);
  }
};

class Relocate : public RootCallback {
 public:
  ObservedCallback* node;
  HeapObject* key;
  HeapObject* moved_key;
  Object* closure;
  Object* moved_closure;
  unsigned keys = 0, closures = 0;
  bool queued = false;

  void do_roots(Object** roots, word count) override {
    CXXV_ASSERT(!destroyed && count == 1, "visit one field of a live node");
    if (roots == reinterpret_cast<Object**>(&node->key_)) {
      CXXV_ASSERT(*roots == (queued ? image.null_object() : key), "queued nodes no longer retain their dead key");
      if (!queued) *roots = moved_key;
      ++keys;
    } else {
      CXXV_ASSERT(roots == &node->lambda_ && *roots == (queued ? moved_closure : closure),
                  "visit the current closure field");
      *roots = moved_closure;
      ++closures;
    }
  }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  ObjectHeap heap(&image, nullptr, nullptr, nullptr, nullptr);
  uword words[8] = {};
  auto object = [&words](int i) { return HeapObject::from_address(reinterpret_cast<uword>(&words[i])); };
  auto key = Instance::cast(object(0));
  key->_set_header(Smi::from(3), INSTANCE_TAG);
  uword clean_header = words[0];
  bool active = nondet_bool();
  if (active) key->set_has_active_finalizer();
  bool in_source = nondet_bool();
  bool forwarded = in_source && nondet_bool();
  bool live = !in_source || forwarded;
  if (forwarded) {
    words[2] = words[0];
    key->set_forwarding_address(object(2));
  }
  uword initial_header = words[0];
  // Supply the chunk membership seen by the young collector at finalization.
  auto& metadata = GcMetadata::singleton_;
  metadata.lowest_address_ = reinterpret_cast<uword>(words);
  metadata.heap_extent_ = sizeof(words);
  CXXV_ASSUME(metadata.lowest_address_ <= UINTPTR_MAX - metadata.heap_extent_);
  SemiSpace source(&image, nullptr);
  Chunk chunk(&source, reinterpret_cast<uword>(in_source ? words : words + 6), 2 * WORD_SIZE);
  source.chunk_list_.append(&chunk);
  image.roots_[Program::null_object_INDEX] = object(5);
  Oracle oracle;
  oracle.key = key;
  oracle.source = &source;
  Relocate relocate;
  relocate.key = key;
  relocate.moved_key = forwarded ? object(2) : key;
  relocate.closure = object(3);
  relocate.moved_closure = object(4);
  auto node = new ObservedCallback(key, relocate.closure, &heap);
  CXXV_ASSUME(node != nullptr);
  relocate.node = node;
  heap.registered_callback_finalizers_.append(node);

  heap.process_registered_callback_finalizers(&relocate, &oracle);
  bool runnable = active && !live;
  bool retained = active && live;
  CXXV_ASSERT(oracle.active_queries == 1 && oracle.live_queries == unsigned(active) && destroyed == !active,
              "discard an inactive registration without testing reachability or visiting fields");
  CXXV_ASSERT(relocate.keys == unsigned(retained) && relocate.closures == unsigned(active),
              "retain both live fields or only the dead key's closure");
  CXXV_ASSERT(words[0] == (runnable ? clean_header : initial_header),
              "clear only the active bit when scheduling the callback");
  CXXV_ASSERT(heap.registered_callback_finalizers_.first() == (retained ? node : nullptr) &&
              heap.runnable_finalizers_.first() == (runnable ? node : nullptr), "transfer exactly the dead active registration");
  if (active) {
    CXXV_ASSERT(node->lambda() == relocate.moved_closure &&
                node->key() == (runnable ? image.null_object() : relocate.moved_key),
                "save the relocated closure and retain a key only while it is live");
  }
  relocate.queued = true;
  heap.process_finalizer_queue(&relocate, &oracle);
  CXXV_ASSERT(relocate.keys == unsigned(active) && relocate.closures == unsigned(active) + unsigned(runnable) &&
              oracle.active_queries == 1 && oracle.live_queries == unsigned(active),
              "queued closures survive the second visit without another liveness test");
  CXXV_ASSERT(heap.next_finalizer_to_run() == (runnable ? relocate.moved_closure : image.null_object()) &&
              destroyed == !retained && !heap.has_finalizer_to_run(), "deliver the runnable closure once");
  CXXV_ASSERT(heap.next_finalizer_to_run() == image.null_object(), "a second delivery finds no callback");
  if (retained) delete heap.registered_callback_finalizers_.remove_first();
  source.chunk_list_.unlink(&chunk);
  exit(0);  // The fixture owns the descriptor and its backing storage.
}
