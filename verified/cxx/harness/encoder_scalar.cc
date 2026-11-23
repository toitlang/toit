// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "encoder_visitor.h"
#undef private
#include "visitor.cc"

using namespace toit;

extern Program image;
static unsigned writes;
enum class Writer { BYTE, INTEGER, DOUBLE };
static Writer called;
static int64 payload;

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a valid scalar never reaches VM failure");
  abort();
}

// Observe the writer call made by the deployed visitor. The byte-level
// behavior of the numeric writers is checked by encoder_numbers.cc.
ProgramOrientedEncoder::ProgramOrientedEncoder(Program* program, Buffer* buffer)
    : Encoder(buffer), program_(program) {}
void Encoder::write_byte(uint8 value) { ++writes; called = Writer::BYTE; payload = value; }
void Encoder::write_int(int64 value) { ++writes; called = Writer::INTEGER; payload = value; }
void Encoder::write_double(double value) { ++writes; called = Writer::DOUBLE; payload = bit_cast<int64>(value); }

// Every non-scalar entry is a failing assertion. Scalar entries inherit
// the real implementations, including the virtual dispatch from accept.
class ScalarVisitor : public EncodeVisitor {
 public:
  explicit ScalarVisitor(ProgramOrientedEncoder* encoder) : EncodeVisitor(encoder) {}
 private:
  void visit_array(Array*) override { unexpected(); }
  void visit_byte_array(ByteArray*) override { unexpected(); }
  void visit_string(String*) override { unexpected(); }
  void visit_instance(Instance*) override { unexpected(); }
  void visit_stack(Stack*) override { unexpected(); }
  void visit_task(Task*) override { unexpected(); }
  static void unexpected() { CXXV_ASSERT(false, "scalar never enters a compound-object visitor"); }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  ProgramOrientedEncoder encoder(&image, nullptr);
  ScalarVisitor visitor(&encoder);
  unsigned kind = nondet_uint();
  CXXV_ASSUME(kind < 6);

  Object* object;
  Writer writer;
  int64 expected;
  uword boxed[1 + 8 / sizeof(word)];
  uword roots[] = {2 * ODDBALL_TAG, 2 * ODDBALL_TAG, 2 * ODDBALL_TAG};
  if (kind == 0) {
    word value = nondet_word();
    CXXV_ASSUME(Smi::is_valid(value));
    object = Smi::from(value);
    expected = value;
    writer = Writer::INTEGER;
  } else if (kind < 3) {
    expected = nondet_int64();
    memcpy(boxed + 1, &expected, sizeof(expected));
    boxed[0] = 2 * (kind == 1 ? LARGE_INTEGER_TAG : DOUBLE_TAG);
    object = HeapObject::from_address(reinterpret_cast<uword>(boxed));
    writer = kind == 1 ? Writer::INTEGER : Writer::DOUBLE;
  } else {
    image.set_null_object(HeapObject::from_address(reinterpret_cast<uword>(roots)));
    image.set_true_object(HeapObject::from_address(reinterpret_cast<uword>(roots + 1)));
    image.set_false_object(HeapObject::from_address(reinterpret_cast<uword>(roots + 2)));
    object = HeapObject::from_address(reinterpret_cast<uword>(roots + (kind - 3)));
    expected = kind == 3 ? 'Z' : kind == 4 ? 'T' : 'F';
    writer = Writer::BYTE;
  }
  visitor.accept(object);
  CXXV_ASSERT(writes == 1 && called == writer && payload == expected,
              "dispatch each scalar to its writer once with the exact value or marker");
}
