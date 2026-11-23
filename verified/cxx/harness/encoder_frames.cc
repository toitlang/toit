// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "objects_inline.h"
#include "encoder.h"
#include "visitor.h"
#include "heap.h"
#include "bytecodes.h"
#include "profiler.h"
#include "utils.h"
#include "uuid.h"

// Select the deployed trace policy after loading the native host headers.
// This exercises the FreeRTOS cap without substituting its OS or allocator.
#ifdef CXXV_FREERTOS_TRACE
#define TOIT_FREERTOS
#endif
#define private public
#include "encoder.cc"
#undef private

using namespace toit;

// Number selected from [0, prefix): the first top frames and the last
// bottom frames, with each frame counted once when these regions overlap.
static int selected(int prefix, int total, int top, int bottom) {
  if (total <= top + bottom) return prefix;
  int first = prefix < top ? prefix : top;
  int tail_start = total - bottom;
  return prefix <= tail_start ? first : first + (prefix - tail_start);
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
#ifdef CXXV_FREERTOS_TRACE
  const int top = 13, bottom = 27;
#else
  const int top = 33, bottom = 67;
#endif
  int total = nondet_int();
  CXXV_ASSUME(total >= 0);
  MallocedBuffer output(24);
  CXXV_ASSUME(output.has_content());
  Encoder encoder(&output);
  EncodeFrameCallback callback(&encoder, total);
  CXXV_ASSERT(callback.number_of_frames_written() == selected(0, total, top, bottom),
              "empty prefix has no emitted frames");
  CXXV_ASSERT(callback.number_of_frames_to_write() == selected(total, total, top, bottom),
              "announced count equals selected frames at end of traversal");
  int index = nondet_int();
  CXXV_ASSUME(index >= 0 && index < total);
  int before = selected(index, total, top, bottom);
  callback.count_ = before;
  int bci = nondet_int();
  callback.do_frame(nullptr, index, bci);
  int after = selected(index + 1, total, top, bottom);
  CXXV_ASSERT(callback.number_of_frames_written() == after, "callback preserves prefix count");

  // Compose with the numeric writer proof for the actual frame bytes.
  MallocedBuffer expected(24);
  CXXV_ASSUME(expected.has_content());
  if (after > before) {
    Encoder reference(&expected);
    reference.write_header(2, 'F');
    reference.write_int(index);
    reference.write_int(bci);
  }
  CXXV_ASSERT(output.size() == expected.size() && !output.has_overflow(),
              "omitted frames write nothing and selected frames have the specified length");
  if (output.size() > 0) {
    word offset = nondet_word();
    CXXV_ASSUME(offset >= 0 && offset < output.size());
    CXXV_ASSERT(output.content()[offset] == expected.content()[offset],
                "selected frame has its original number and bytecode index in order");
  }
}
