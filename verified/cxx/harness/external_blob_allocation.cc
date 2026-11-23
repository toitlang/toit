// Copyright (C) 2026 Toit contributors.

#include "prelude.h"

static bool node_oom;
static unsigned node_requests;
static bool refuse_node() {
  ++node_requests;
  return node_oom;
}

#define private public
#define protected public
#include "heap.h"
#include "objects_inline.h"
// Include the null outcome of the native nothrow node allocation.
#undef _new
#define _new refuse_node() ? nullptr : new (std::nothrow)
#include "heap.cc"
#undef _new
#define _new new (std::nothrow)
#include "objects.cc"
#undef protected
#undef private

using namespace toit;
extern Program image;
extern Process owner;
static bool string;
static HeapObject* reserved;
static unsigned requests;

HeapObject* TwoSpaceHeap::allocate(uword size) {
  ++requests;
  CXXV_ASSERT(size == (string ? String::EXTERNAL_OBJECT_SIZE : ByteArray::EXTERNAL_SIZE),
              "reserve one external object header");
  if (nondet_bool()) return nullptr;
  void* storage = malloc(size);
  if (storage == nullptr) return nullptr;
  reserved = HeapObject::from_address(reinterpret_cast<uword>(storage));
  return reserved;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  string = nondet_bool();
  TypeTag tag = string ? STRING_TAG : BYTE_ARRAY_TAG;
  unsigned cid = nondet_uint();
  CXXV_ASSUME(cid < 1024);
  uint16 classes[1024];
  classes[cid] = nondet_ushort();
  CXXV_ASSUME(Program::class_tag_from_class_bits(classes[cid]) == tag);
  image.class_bits = List<uint16>(classes, 1024);
  image._builtin_class_ids[string ? Program::string_class_id_INDEX : Program::byte_array_class_id_INDEX] = Smi::from(cid);
  ObjectHeap local_heap(&image, &owner, nullptr, nullptr, nullptr);
  auto* heap = &local_heap;
  VmFinalizerNode* prior = nullptr;
  if (nondet_bool()) {
    prior = new VmFinalizerNode(nullptr, heap);
    CXXV_ASSUME(prior != nullptr);
    heap->registered_vm_finalizers_.append(prior);
  }

  word length = nondet_word();
  CXXV_ASSUME(0 <= length && length < MESSAGING_ENCODING_MAX_SIZE);
  auto* memory = static_cast<uint8*>(malloc(length + (string ? 1 : 0)));
  CXXV_ASSUME(memory != nullptr);
  word index = nondet_word();
  uint8 original = nondet_uchar();
  if (length != 0) {
    CXXV_ASSUME(0 <= index && index < length);
    memory[index] = original;
  }
  if (string) memory[length] = nondet_uchar();
  bool dispose = nondet_bool();
  node_oom = nondet_bool();
  HeapObject* result;
  if (string) {
    result = heap->allocate_external_string(length, memory, dispose);
  } else {
    result = heap->allocate_external_byte_array(length, memory, dispose, false);
  }
  bool register_node = reserved != nullptr && dispose;
  CXXV_ASSERT(requests == 1 && node_requests == (register_node ? 1 : 0), "request a finalizer only for an owned header");
  CXXV_ASSERT(result == (register_node && node_oom ? nullptr : reserved), "propagate reservation and finalizer exhaustion");
  if (length != 0) CXXV_ASSERT(memory[index] == original, "preserve every existing payload byte");
  bool registered = register_node && !node_oom;
  auto* tail = heap->registered_vm_finalizers_.last();
  if (registered) {
    CXXV_ASSERT(tail != nullptr && tail != prior && tail->key() == result && tail->heap_ == heap,
                "append the finalizer for this object and heap");
  } else {
    CXXV_ASSERT(tail == prior, "preserve the finalizer queue on failure or borrowed storage");
  }
  CXXV_ASSERT(heap->registered_vm_finalizers_.first() == (prior != nullptr ? prior : tail),
              "preserve the first registered node");
  if (prior != nullptr) {
    CXXV_ASSERT(prior->next_ == (registered ? tail : nullptr), "link the previous last node to its successor");
  }
  if (tail != nullptr) CXXV_ASSERT(tail->next_ == nullptr, "terminate the resulting queue");
  if (reserved != nullptr) {
    CXXV_ASSERT(reserved->class_id() == Smi::from(cid) && reserved->has_class_tag(tag) &&
                reserved->has_active_finalizer() == registered, "match the header class and finalizer flag to registration");
    if (string) {
      auto* object = String::cast(reserved);
      CXXV_ASSERT(!object->content_on_heap() && object->length() == length && object->as_external() == memory &&
                  object->_raw_hash_code() == String::NO_HASH_CODE && memory[length] == 0,
                  "initialize external string over the original terminated payload");
    } else {
      auto* object = ByteArray::cast(reserved);
      CXXV_ASSERT(object->has_external_address() && object->_external_length() == length &&
                  object->as_external() == memory && object->external_tag() == RawByteTag,
                  "initialize external bytes over the original payload");
    }
  }
  if (register_node && node_oom) {
    CXXV_ASSERT(heap->last_allocation_result_ == ObjectHeap::ALLOCATION_OUT_OF_MEMORY, "record finalizer allocation failure");
  }
  if (!registered) free(memory);
  // Teardown is a separate consumer of the established finalizer state.
  exit(0);
}
