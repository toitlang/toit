// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.cc"
#include "objects_runtime.cc"
static void release_payload(void*);
#define free release_payload
#include "heap_roots.cc"
#undef free
#undef protected
#undef private

using namespace toit;
extern Process owner;

static uint8* payload;
static bool disposable;
static unsigned releases;
static uword charged;

// The finalizer never reads the payload. Track ownership of its allocation
// independently of the logical size carried by the VM header.
static void release_payload(void* p) {
  CXXV_ASSERT(disposable && p == payload && releases == 0, "release the owned buffer exactly once");
  CXXV_ASSERT(owner.object_heap()->external_memory() == charged, "release before refunding its charge");
  ++releases;
  free(p);
}

class FinalizerVisit : public RootCallback, public LivenessOracle {
 public:
  HeapObject* key;
  HeapObject* moved;
  bool alive;
  unsigned visits = 0;

  bool has_active_finalizer(HeapObject* o) override {
    CXXV_ASSERT(o == key, "inspect the current finalizer key");
    return o->has_active_finalizer();
  }
  bool is_alive(HeapObject* o) override {
    CXXV_ASSERT(o == key && o->has_active_finalizer(), "query liveness only for an active registration");
    return alive;
  }
  void do_roots(Object** slot, word count) override {
    CXXV_ASSERT(alive && count == 1 && *slot == key && visits == 0, "relocate the surviving key once");
    *slot = moved;
    ++visits;
  }
};

enum Storage { RAW, STRING_BUFFER, NULL_BUFFER, MAPPED };

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  auto heap = owner.object_heap();
  heap->owner_ = &owner;
  new (&heap->registered_vm_finalizers_) FinalizerNodeFifo();
  constexpr Storage kind = CXXV_STORAGE_KIND;
  bool string = kind == STRING_BUFFER;
  word length = nondet_word();
  CXXV_ASSUME(length >= 0 && (!string || length < INTPTR_MAX));
  uword initial = nondet_ulong();
  uword cost = (kind == RAW || string) ? static_cast<uword>(length) + unsigned(string) : 0;
  CXXV_ASSUME(initial <= UINTPTR_MAX - cost);
  uint64 lifetime = static_cast<uint64>(nondet_int64());
  CXXV_ASSUME(lifetime <= UINT64_MAX - cost);
  heap->external_memory_ = initial;
  heap->total_external_memory_ = lifetime;
  heap->register_external_allocation(cost);
  charged = initial + cost;
  payload = kind == NULL_BUFFER ? nullptr : static_cast<uint8*>(malloc(1));
  CXXV_ASSUME(kind == NULL_BUFFER || payload != nullptr);

  static_assert(ByteArray::EXTERNAL_SIZE == String::EXTERNAL_OBJECT_SIZE, "external header fixture");
  struct Header { uword words[ByteArray::EXTERNAL_SIZE / WORD_SIZE]; };
  Header original = {}, copy;
  auto key = HeapObject::from_address(reinterpret_cast<uword>(original.words));
  key->_set_header(Smi::from(3), string ? STRING_TAG : BYTE_ARRAY_TAG);
  if (string) {
    auto s = String::cast(key);
    s->_set_external_length(length);
    s->_set_external_address(payload);
  } else {
    auto b = ByteArray::cast(key);
    b->_initialize_external_memory(length, payload, false);
    if (kind == MAPPED) b->_set_external_tag(MappedFileTag);
  }
  // Model successful native registration. Allocation failure has its own proof.
  bool registered = heap->add_vm_finalizer(key);
  CXXV_ASSUME(registered);
  bool transferred = kind == RAW && nondet_bool();
  if (transferred) {
    CXXV_ASSERT(ByteArray::cast(key)->neuter(&owner) == payload, "transfer returns the original owned buffer");
    key->clear_has_active_finalizer();
  }
  disposable = (string || kind == RAW) && !transferred;
  FinalizerVisit visitor;
  visitor.key = key;
  visitor.moved = HeapObject::from_address(reinterpret_cast<uword>(copy.words));
  visitor.alive = nondet_bool();
  bool shutdown = nondet_bool();
  bool retained = !shutdown && !transferred && visitor.alive;
  if (shutdown) {
    clean_up_finalizers(&heap->registered_vm_finalizers_);
  } else {
    copy = original;
    heap->process_registered_vm_finalizers(&visitor, &visitor);
  }
  CXXV_ASSERT(visitor.visits == unsigned(retained) && releases == unsigned(disposable && !retained),
              "trace only live active keys and release owned dead or dying buffers exactly once");
  CXXV_ASSERT(heap->external_memory() == (retained ? charged : initial) &&
              heap->total_external_memory_.load() == lifetime + cost,
              "preserve the live charge until disposal and keep the lifetime counter unchanged");
  if (retained) {
    // Re-establish the ownership conditions for the next collection or shutdown.
    auto node = heap->registered_vm_finalizers_.first();
    CXXV_ASSERT(node && heap->registered_vm_finalizers_.last() == node && node->next_ == nullptr &&
                node->heap_ == heap && node->key() == visitor.moved && visitor.moved->has_active_finalizer(),
                "preserve one active registration for the relocated object and the same owning heap");
    if (string) {
      auto s = String::cast(visitor.moved);
      CXXV_ASSERT(s->class_tag() == STRING_TAG && !s->content_on_heap() && s->length() == length &&
                  s->as_external() == payload, "the relocated string still owns the same terminated buffer");
    } else {
      auto b = ByteArray::cast(visitor.moved);
      CXXV_ASSERT(b->class_tag() == BYTE_ARRAY_TAG && b->has_external_address() && b->_external_length() == length &&
                  b->_external_address() == payload &&
                  b->external_tag() == (kind == RAW ? RawByteTag : kind == MAPPED ? MappedFileTag : NullStructTag),
                  "the relocated array preserves its storage kind, extent and buffer");
    }
    delete heap->registered_vm_finalizers_.remove_first();  // End the surviving node's fixture lifetime.
  } else {
    CXXV_ASSERT(heap->registered_vm_finalizers_.is_empty(), "remove disposed and transferred registrations");
  }
  if ((retained || !disposable) && payload) free(payload);
}
