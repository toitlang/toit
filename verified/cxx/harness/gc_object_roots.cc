// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#undef protected
#undef private

using namespace toit;

extern Program image;

class RecordingRoots : public RootCallback {
 public:
  unsigned calls = 0;
  mutable unsigned skip_queries = 0;
  Object** first = nullptr;
  word count = -1;
  HeapObject* subject = nullptr;
  bool skip;

  void do_roots(Object** roots, word n) override {
    ++calls;
    first = roots;
    count = n;
  }
  bool skip_marking(HeapObject* obj) const override {
    CXXV_ASSERT(obj == subject, "ask about the instance currently being scanned");
    ++skip_queries;
    return skip;
  }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  auto tag = static_cast<TypeTag>(nondet_int());
  CXXV_ASSUME(tag >= ARRAY_TAG && tag <= PROMOTED_TRACK_TAG && tag != STACK_TAG);
  bool instance = tag == INSTANCE_TAG || tag == TASK_TAG;
  int cid = nondet_int();
  CXXV_ASSUME(cid >= 0 && cid < 1024);
  bool skip = nondet_bool(), active = nondet_bool();
  uint16 classes[1024];
  image.class_bits = List<uint16>(classes,1024);
  word count = nondet_word();
  CXXV_ASSUME(count >= 0 && count <= (INTPTR_MAX - 2 * WORD_SIZE) / WORD_SIZE);
  int header_words = tag == ARRAY_TAG ? 2 : 1;
  if (instance) {
    CXXV_ASSUME(count < Program::INSTANCE_SIZE_MASK);
    classes[cid] = Program::compute_class_bits(tag, (1 + count) * WORD_SIZE);
  }
  uword payload = instance || tag == ARRAY_TAG ? count : 0;
  auto* storage = static_cast<Object**>(malloc((header_words + payload) * WORD_SIZE));
  CXXV_ASSUME(storage != nullptr && reinterpret_cast<uword>(storage) % WORD_SIZE == 0);
  auto* object = HeapObject::from_address(reinterpret_cast<uword>(storage));
  object->_set_header(Smi::from(cid),tag);
  if (active) object->set_has_active_finalizer();
  if (tag == ARRAY_TAG) static_cast<Array*>(object)->_set_length(count);
  RecordingRoots callback;
  callback.subject = object;
  callback.skip = skip;
  object->roots_do(&image,&callback);
  bool visit = tag == ARRAY_TAG || (instance && !(skip && active));
  CXXV_ASSERT(callback.skip_queries == (instance && active), "only finalizable instances and tasks query the visitor");
  CXXV_ASSERT(callback.calls == visit, "visit the complete field range unless the active finalizer and visitor request a skip");
  if (visit) {
    CXXV_ASSERT(callback.first == storage + header_words && callback.count == count,
                "deliver the whole field slice, including empty slices, without header words");
  }
}
