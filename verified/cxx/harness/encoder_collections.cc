// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "encoder_visitor.h"
#undef private

using namespace toit;

extern Program image;
static int child_level;
static int children;
static int tokens;
static int witness;
static Object* observed;

enum Operation { BYTE, INTEGER, HEADER };
struct Token {
  Operation operation;
  int64 value;
  uint8 tag;
};
static Token emitted[5];

// Summarize the separately proved numeric writers by their arguments.
// Collect the parent prefix and check that it precedes every child.
static void record(Operation operation, int64 value, uint8 tag = 0) {
  CXXV_ASSERT(children == 0 && tokens < 5, "write only the parent prefix before child dispatch");
  emitted[tokens++] = {operation, value, tag};
}
ProgramOrientedEncoder::ProgramOrientedEncoder(Program* program, Buffer* buffer)
    : Encoder(buffer), program_(program) {}
void Encoder::write_byte(uint8 byte) { record(BYTE, byte); }
void Encoder::write_int(int64 value) { record(INTEGER, value); }
void Encoder::write_header(word size, uint8 tag) { record(HEADER, size, tag); }
void Visitor::accept(Object* child) {
  CXXV_ASSERT(static_cast<EncodeVisitor*>(this)->level_ == child_level, "child nesting increases by one");
  if (children == witness) observed = child;
  ++children;
}

static bool token(int i, Operation operation, int64 value, uint8 tag = 0) {
  return emitted[i].operation == operation && emitted[i].value == value && emitted[i].tag == tag;
}

static void check_list_fields() {
  uword backing[2];
  unsigned tag = nondet_uint() & 15;
  backing[0] = 2 * tag;
  word length = nondet_word();
  CXXV_ASSUME(length >= 0);
  backing[1] = length;
  auto* object = HeapObject::from_address(reinterpret_cast<uword>(backing));
  bool heap = nondet_bool();
  bool integer_size = nondet_bool();
  word size = nondet_word();
  CXXV_ASSUME(Smi::is_valid(size));
  Object* fields[] = {
    Smi::from(INSTANCE_TAG),
    heap ? static_cast<Object*>(object) : Smi::zero(),
    integer_size ? static_cast<Object*>(Smi::from(size)) : object,
  };
  auto* instance = static_cast<Instance*>(HeapObject::from_address(reinterpret_cast<uword>(fields)));
  bool valid = EncodeVisitor::is_valid_list(instance);
  CXXV_ASSERT(valid == (heap && tag == ARRAY_TAG && integer_size && size >= 0 && size <= length),
              "list requires an array and a tagged size within the backing length");
}

static void check_prefix() {
  MallocedBuffer output(1);
  CXXV_ASSUME(output.has_content());
  bool full = nondet_bool();
  output.pos_ = full ? 1 : 0;
  ProgramOrientedEncoder encoder(&image, &output);
  int level = nondet_int();
  CXXV_ASSUME(level >= 0 && level <= 16);
  child_level = level + 1;
  EncodeVisitor visitor(&encoder, level);
  bool skip = visitor.skip_collection();
  CXXV_ASSERT(skip == (full || level == 16), "skip exactly full buffers and depth-limited collections");
  if (skip) {
    CXXV_ASSERT(full ? tokens == 0 : (tokens == 1 && token(0, BYTE, 'Z')),
                "skip output on overflow and encode null at the depth limit");
    return;
  }

  word length = nondet_word();
  word size = nondet_word();
  CXXV_ASSUME(size >= 0 && size <= length);
  uword backing[12];
  backing[0] = 2 * ARRAY_TAG;
  backing[1] = length;
  auto* array = static_cast<Array*>(HeapObject::from_address(reinterpret_cast<uword>(backing)));
  witness = nondet_int();
  CXXV_ASSUME(witness >= 0 && witness < 10);
  uword original = nondet_ulong();
  backing[2 + witness] = original;
  uint8 kind = nondet_bool() ? 'A' : 'L';
  visitor.visit_elements(array, size, kind);
  int expected = size < 10 ? static_cast<int>(size) : 10;
  CXXV_ASSERT(children == expected, "visit exactly the capped prefix");
  if (witness < expected) {
    CXXV_ASSERT(reinterpret_cast<uword>(observed) == original, "pass each original slot in order");
  }
  CXXV_ASSERT(tokens == 5 && token(0, HEADER, 2, kind) && token(1, INTEGER, size) &&
              token(2, BYTE, '[') && token(3, BYTE, '#') && token(4, INTEGER, expected),
              "announce the original size and capped child count in order");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  if (nondet_bool()) check_list_fields();
  else check_prefix();
}
