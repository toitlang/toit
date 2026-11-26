// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects_inline.h"
#include "interpreter_v2.h"
#include "flags.h"
#undef private

namespace toit {
extern Program image;
static Stack* subject;
static Object** slots;
static RootCallback* visitor;
static word old_top, old_length, new_top;
static int height;
static uword bytecode_base;
static word bytecode_length;
static bool damaged, rejected, shrunk, scanned;

// The shrink proof preserves the live count and may reduce the top.
word Stack::shrink_v2_for_gc(word top, int max_height, bool aggressive, RootCallback* cb) {
  CXXV_ASSERT(!damaged && !shrunk && !scanned && this == subject && top == old_top &&
              max_height == height && aggressive == Flags::shrink_stacks_a_lot && cb == visitor,
              "pass the original top, image reserve and visitor to format-2 shrinking");
  shrunk = true;
  _set_top(new_top);
  _set_length(new_top + (old_length - old_top));
  return new_top;
}

// The marking and relocation proofs consume exactly these scanner arguments.
static void visit_stack_roots(Object** base, word top, word length, uword from, uword to, RootCallback* cb) {
  CXXV_ASSERT(shrunk && !scanned && !damaged && cb == visitor && base == slots &&
              top == new_top && length == new_top + (old_length - old_top),
              "scan precisely the relocated live slice after shrinking");
  CXXV_ASSERT(from == bytecode_base && to == bytecode_base + bytecode_length &&
              from <= reinterpret_cast<uword>(image.frame_marker()) &&
              reinterpret_cast<uword>(image.frame_marker()) < to, "exclude precisely the image bytecodes including the frame marker");
  scanned = true;
}

#undef FATAL
#define FATAL(...) do { rejected = true; return; } while (false)
#include "stack_roots_do.inc"
#undef FATAL
}  // namespace toit

using namespace toit;
class Visitor : public RootCallback {
 public:
  void do_roots(Object**, word) override { CXXV_ASSERT(false, "only the modeled scanner visits slots"); }
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  bytecode_length = nondet_word();
  CXXV_ASSUME(bytecode_length >= 4);
  auto* code = static_cast<uint8*>(malloc(bytecode_length));
  CXXV_ASSUME(code != nullptr);
  bytecode_base = reinterpret_cast<uword>(code);
  CXXV_ASSUME(bytecode_base % WORD_SIZE == 0 && bytecode_base <= UINTPTR_MAX - bytecode_length);
  code[0] = 'T';
  code[1] = 'B';
  code[2] = 'C';
  code[3] = '3';  // The verified core's tag (format 3, Program::is_format2).
  image.bytecodes = List<uint8>(code, bytecode_length);
  height = nondet_int();
  image.set_global_max_stack_height(height);
  old_length = nondet_word();
  old_top = nondet_word();
  new_top = nondet_word();
  CXXV_ASSUME(0 <= new_top && new_top <= old_top && old_top <= old_length && old_length < Stack::V2_MAX_LENGTH);
  auto* raw = static_cast<uword*>(malloc(Stack::HEADER_SIZE + old_length * WORD_SIZE));
  CXXV_ASSUME(raw != nullptr && reinterpret_cast<uword>(raw) % WORD_SIZE == 0);
  subject = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(raw)));
  slots = reinterpret_cast<Object**>(raw + Stack::HEADER_SIZE / WORD_SIZE);
  subject->_initialize(old_length);
  subject->_set_top(old_top);
  damaged = nondet_bool();
  if (damaged) {
    unsigned index = nondet_uint() % Stack::GUARD_ZONE_WORDS;
    uword value = nondet_ulong();
    CXXV_ASSUME(value != Stack::GUARD_ZONE_MARKER);
    raw[Stack::HEADER_SIZE / WORD_SIZE - Stack::GUARD_ZONE_WORDS + index] = value;
  }
  Visitor callback;
  visitor = &callback;
  subject->roots_do(&image, visitor);
  CXXV_ASSERT(rejected == damaged && scanned == !damaged && shrunk == !damaged,
              "a damaged guard terminates before shrinking or scanning, and an intact stack reaches both once");
}
