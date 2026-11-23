// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "objects_inline.h"

// Observe entry into the VM fatal handler for a reserved tag.
static unsigned fatal_calls;
#undef FATAL
#define FATAL(...) do { ++fatal_calls; return; } while (false)
#include "visitor.cc"
#undef FATAL

using namespace toit;

class RecordingVisitor : public Visitor {
 public:
  unsigned calls = 0;
  int kind = -2;
  Object* argument = nullptr;

 private:
  void record(int selected, Object* object) {
    ++calls;
    kind = selected;
    argument = object;
  }
  void visit_smi(Smi* o) override { record(-1, o); }
  void visit_string(String* o) override { record(STRING_TAG, o); }
  void visit_array(Array* o) override { record(ARRAY_TAG, o); }
  void visit_byte_array(ByteArray* o) override { record(BYTE_ARRAY_TAG, o); }
  void visit_stack(Stack* o) override { record(STACK_TAG, o); }
  void visit_instance(Instance* o) override { record(INSTANCE_TAG, o); }
  void visit_oddball(HeapObject* o) override { record(ODDBALL_TAG, o); }
  void visit_double(Double* o) override { record(DOUBLE_TAG, o); }
  void visit_large_integer(LargeInteger* o) override { record(LARGE_INTEGER_TAG, o); }
  void visit_task(Task* o) override { record(TASK_TAG, o); }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  // All bits outside the class tag are arbitrary, including the sign bit.
  uword header = nondet_ulong() & ~uword{1};
  bool heap = nondet_bool();
  Object* object = heap ? static_cast<Object*>(HeapObject::from_address(reinterpret_cast<uword>(&header)))
                        : reinterpret_cast<Object*>(nondet_ulong() & ~uword{1});
  int expected = heap ? static_cast<int>((header >> 1) & 15) : -1;
  RecordingVisitor visitor;
  visitor.accept(object);
  if (expected >= FREE_LIST_REGION_TAG) {
    CXXV_ASSERT(fatal_calls == 1 && visitor.calls == 0, "reserved tags reach the fatal handler without a visit");
  } else {
    CXXV_ASSERT(fatal_calls == 0 && visitor.calls == 1 && visitor.kind == expected,
                "dispatch an immediate or heap object to its matching visitor exactly once");
    CXXV_ASSERT(visitor.argument == object, "pass the original tagged object to the callback");
  }
}
