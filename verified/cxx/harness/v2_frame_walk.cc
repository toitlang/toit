// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects.cc"
#undef private

using namespace toit;

extern Program image;

class RecordedFrame : public FrameCallback {
 public:
  void do_frame(Stack* stack, int number, int bci) override {
    ++calls;
    source = stack;
    index = number;
    location = bci;
  }

  unsigned calls = 0;
  Stack* source = nullptr;
  int index = -1;
  int location = 0;
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  int frames = nondet_int();
  CXXV_ASSUME(0 <= frames && frames <= (Stack::V2_MAX_LENGTH - 1) / Stack::V2_FRAME_WORDS);
  int frame_words = frames * Stack::V2_FRAME_WORDS;
  auto* words = static_cast<uword*>(malloc(Stack::HEADER_SIZE + frame_words * sizeof(word)));
  CXXV_ASSUME(words != nullptr);
  Stack* stack = static_cast<Stack*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  unsigned record_end = nondet_uint();
  CXXV_ASSUME(record_end >= static_cast<unsigned>(frame_words) && record_end < Stack::V2_MAX_LENGTH);
  words[Stack::TRY_TOP_OFFSET / WORD_SIZE] = (static_cast<uword>(frame_words) << 16) | record_end;
  int suspended = nondet_int();
  words[Stack::PENDING_STACK_CHECK_METHOD_OFFSET / WORD_SIZE] = static_cast<uword>(suspended);
  int skip = nondet_int();
  int omitted = skip <= 0 ? 0 : (skip < frames ? skip : frames);
  int count = frames - omitted;
  Stack::v2_frames_skip_ = skip;
  CXXV_ASSERT(stack->v2_frames_do(nullptr, nullptr) == count, "count-only walk needs no bytecodes or callback");
  V2FrameWalker walk(stack, skip);
  CXXV_ASSERT(walk.next_ == 0 && walk.count() == count, "starts at zero with the unskipped frame count");

  // Induction step for every prefix, including the exhausted cursor.
  int index = nondet_int();
  CXXV_ASSUME(index >= 0 && index <= count);
  walk.next_ = index;
  int length = nondet_int();
  CXXV_ASSUME(length >= 0 && length < V2_MAX_BYTECODES);
  uint8* code = static_cast<uint8*>(malloc(length));
  CXXV_ASSUME(length == 0 || code != nullptr);
  image.bytecodes = List<uint8>(code, length);
  uint8 opcode = nondet_uchar();
  if (suspended >= 0 && suspended < length) code[suspended] = opcode;

  int expected = suspended;
  if (index < count) {
    int depth = index + omitted;
    if (depth == 0) {
      if (suspended >= 0 && suspended < length && opcode < V2_OPCODE_COUNT) expected += V2_OPCODE_LENGTHS[opcode];
    } else {
      int record = frames - depth;
      CXXV_ASSERT(record > 0 && record < frames, "return location is in a live non-bottom frame");
      expected = nondet_int();
      words[Stack::HEADER_SIZE / WORD_SIZE + record * Stack::V2_FRAME_WORDS + Stack::V2_FRAME_RET] = static_cast<uword>(expected);
    }
  }

  RecordedFrame callback;
  bool emitted = walk.next(&image, &callback);
  CXXV_ASSERT(emitted == (index < count) && callback.calls == static_cast<unsigned>(emitted),
              "emit exactly once for each remaining frame and stop at exhaustion");
  CXXV_ASSERT(walk.next_ == index + emitted && walk.count() == count, "advance by one with a stable limit");
  if (emitted) {
    CXXV_ASSERT(callback.source == stack && callback.index == index && callback.location == expected,
                "emit the original stack, consecutive index and expected bytecode location");
  }
  free(code);
  free(words);
}
