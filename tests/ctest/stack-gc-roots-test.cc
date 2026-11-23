// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/objects_inline.h"
#include "../../src/interpreter.h"
#include "../../src/flags.h"

using namespace toit;

class StackVisitor : public RootCallback {
 public:
  Object** first;
  word live;
  word visits = 0;
  Object* ordinary;
  Object* replacement;
  bool shrink;
  bool shrink_stacks() const override { return shrink; }

  void do_roots(Object** roots, word count) override {
    // Even positions hold ordinary references, odd positions bytecode pointers.
    if (count != 1 || 2 * visits >= live || roots != first + 2 * visits) FATAL("unexpected root slot");
    if (*roots != ordinary) FATAL("lost root during stack move");
    *roots = replacement;
    ++visits;
  }
};

static void check(word live, bool shrink) {
  Program image(nullptr, 0);
  alignas(uword) uint8 bytecodes[] = {'T', 'B', 'C', '2'};
  image.bytecodes = List<uint8>(bytecodes, 4);
  image.set_global_max_stack_height(0);
  constexpr word records = Stack::V2_FRAME_WORDS;
  constexpr word reserve = records + RESERVED_STACK_FOR_CALLS + Stack::V2_FRAME_WORDS + Stack::V2_STACK_RESERVE;
  constexpr word top = reserve + 8;
  // Nine live slots overlap when moved down by eight; zero exercises an empty slice.
  uword raw[Stack::HEADER_SIZE / WORD_SIZE + top + 9];
  auto* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(raw)));
  stack->_initialize(top + live);
  stack->_set_top(top);
  stack->v2_set_records(records, 0, 123);
  auto** slots = reinterpret_cast<Object**>(raw + Stack::HEADER_SIZE / WORD_SIZE);
  uword ordinary_word, replacement_word;
  StackVisitor visitor;
  visitor.ordinary = HeapObject::from_address(reinterpret_cast<uword>(&ordinary_word));
  visitor.replacement = HeapObject::from_address(reinterpret_cast<uword>(&replacement_word));
  visitor.live = live;
  visitor.shrink = shrink;
  bool shrinks = visitor.shrink || Flags::shrink_stacks_a_lot;
  word first = shrinks ? reserve : top;
  visitor.first = slots + first;
  for (word i = 0; i < live; ++i) slots[top + i] = i % 2 == 0 ? visitor.ordinary : image.frame_marker();
  stack->roots_do(&image, &visitor);
  if (stack->top() != first || stack->length() != first + live) FATAL("incorrect stack limits");
  if (visitor.visits != (live + 1) / 2) FATAL("missing root");
  for (word i = 0; i < live; ++i) {
    Object* expected = i % 2 == 0 ? visitor.replacement : image.frame_marker();
    if (slots[first + i] != expected) FATAL("incorrect slot after root visit");
  }
}

int main() {
  for (word live = 0; live <= 9; ++live) {
    check(live, false);
    check(live, true);
  }
}
