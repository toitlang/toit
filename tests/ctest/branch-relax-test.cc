// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The compiler's branch relaxation of format 3 (Emitter::relax_branches,
// verified/spec/format/22-format3-branches-frames.md): a branch gets the
// two-byte short form exactly when its final distance fits a byte, every
// distance in the code is recomputed, and positions are relocated.

#include <stdio.h>
#include <vector>

#include "../../src/top.h"
#include "../../src/interpreter_v2.h"
#include "../../src/compiler/bytecode_format.h"
#include "../../src/compiler/emitter.h"
#include "../../src/compiler/list.h"
#include "../../src/compiler/zone.h"

namespace toit {
namespace compiler {

static void check(bool condition, const char* what) {
  if (!condition) {
    printf("FAIL: %s\n", what);
    FATAL("branch relaxation test failed");
  }
}

// Emits exactly [n] bytes (n >= 2) that leave the stack as it was.
static void filler(Emitter* e, int n) {
  while (n > 0) {
    if (n == 3 || n == 5) {
      e->load_integer(5);     // LOAD_SMI_U8: 2 bytes.
      e->pop(1);              // POP_1: 1 byte.
      n -= 3;
    } else if (n == 2) {
      e->load_null();         // 1 byte.
      e->pop(1);              // 1 byte.
      n -= 2;
    } else {
      e->load_integer(1000);  // LOAD_SMI_U16: 3 bytes.
      e->pop(1);
      n -= 4;
    }
  }
}

struct Decoded {
  int position;
  int opcode;
  int target;  // -1 for no distance.
};

// Decodes the format-3 code and the targets of every instruction with a
// distance.
static std::vector<Decoded> decode(List<uint8> code) {
  std::vector<Decoded> result;
  for (int i = 0; i < code.length();) {
    int op = code[i];
    check(op < V2_OPCODE_COUNT, "valid opcode");
    int len = V2_OPCODE_LENGTHS[op];
    check(i + len <= code.length(), "instruction inside the code");
    int target = -1;
    int w = len >= 3 ? code[i + 1] | code[i + 2] << 8 : 0;
    if (BRANCH <= op && op <= BRANCH_IF_NOT_NULL) target = i + w;
    if (BRANCH_BACK <= op && op <= BRANCH_BACK_IF_NOT_NULL) target = i - w;
    if (op == V2_LOOP_REPEAT || op == V2_LOOP_ARRAY) target = i - w;
    if (op == V2_HASH_FIND) target = i + w;
    if (V2_BRANCH_S <= op && op <= V2_BRANCH_IF_NOT_NULL_S) target = i + code[i + 1];
    if (op == V2_BRANCH_BACK_S) target = i - code[i + 1];
    result.push_back({ i, op, target });
    i += len;
  }
  return result;
}

static const Decoded& at(const std::vector<Decoded>& code, int position) {
  for (auto& d : code) {
    if (d.position == position) return d;
  }
  FATAL("no instruction at the position");
}

// A forward branch over [skip] bytes: short exactly when 2 + skip <= 255.
static void test_forward(int skip, Emitter::Condition condition) {
  Emitter e(0);
  if (condition != Emitter::UNCONDITIONAL) e.load_null();
  Label label;
  int branch = e.position();
  e.branch(condition, &label);
  filler(&e, skip);
  int target = e.position();
  e.bind(&label);
  e.ret_null();
  e.relax_branches();
  auto code = decode(e.bytecodes());
  auto& b = at(code, e.relocated(branch));
  bool want_short = 2 + skip <= 255;
  int base = condition == Emitter::UNCONDITIONAL ? BRANCH
      : condition == Emitter::IF_TRUE ? BRANCH_IF_TRUE
      : condition == Emitter::IF_FALSE ? BRANCH_IF_FALSE : BRANCH_IF_NOT_NULL;
  check(b.opcode == (want_short ? V2_BRANCH_S + (base - BRANCH) : base), "forward branch form");
  check(b.target == e.relocated(target), "forward branch target");
}

// A backward branch over [skip] bytes: short exactly when skip <= 255.
static void test_backward(int skip) {
  Emitter e(0);
  Label label;
  int target = e.position();
  e.bind(&label);
  filler(&e, skip);
  int branch = e.position();
  e.branch(Emitter::UNCONDITIONAL, &label);
  int old_length = e.position();
  e.relax_branches();
  auto bytes = e.bytecodes();
  auto code = decode(bytes);
  auto& b = at(code, e.relocated(branch));
  bool want_short = skip <= 255;
  check(b.opcode == (want_short ? V2_BRANCH_BACK_S : BRANCH_BACK), "backward branch form");
  check(b.target == e.relocated(target), "backward branch target");
  check(e.relocated(old_length) == bytes.length(), "end relocated");
}

// Branch A jumps over branch B; A fits a byte only because B is short.
static void test_chain() {
  Emitter e(0);
  Label x, y;
  int a = e.position();
  e.branch(Emitter::UNCONDITIONAL, &x);
  filler(&e, 251);
  int b = e.position();
  e.branch(Emitter::UNCONDITIONAL, &y);
  int xp = e.position();
  e.bind(&x);
  filler(&e, 4);
  int yp = e.position();
  e.bind(&y);
  e.ret_null();
  e.relax_branches();
  auto code = decode(e.bytecodes());
  check(at(code, e.relocated(a)).opcode == V2_BRANCH_S, "chain: A short");
  check(at(code, e.relocated(b)).opcode == V2_BRANCH_S, "chain: B short");
  check(at(code, e.relocated(a)).target == e.relocated(xp), "chain: A target");
  check(at(code, e.relocated(b)).target == e.relocated(yp), "chain: B target");
  check(e.relocated(b) == 2 + 251, "chain: B moved");
}

// A loop step's backward distance shrinks with a short branch in its body.
static void test_loop() {
  Emitter e(0);
  for (int i = 0; i < 4; i++) e.load_null();
  Label body;
  int bp = e.position();
  e.bind(&body);
  e.pop(1);
  Label skip;
  int branch = e.position();
  e.branch(Emitter::UNCONDITIONAL, &skip);
  filler(&e, 10);
  int sp = e.position();
  e.bind(&skip);
  int loop = e.position();
  e.loop_step(V2_LOOP_REPEAT, &body, 1);
  e.ret_null();
  e.relax_branches();
  auto code = decode(e.bytecodes());
  check(at(code, e.relocated(branch)).opcode == V2_BRANCH_S, "loop: inner branch short");
  check(at(code, e.relocated(branch)).target == e.relocated(sp), "loop: inner branch target");
  auto& l = at(code, e.relocated(loop));
  check(l.opcode == V2_LOOP_REPEAT, "loop: step");
  check(l.target == e.relocated(bp), "loop: step target");
}

static void test() {
  AllowThrowingNew allow;
  Zone zone;
  BytecodeFormatScope format(2);
  // The boundaries: 255 is the last distance with a short form.
  int skips[] = { 2, 3, 100, 252, 253, 254, 255, 256, 300 };
  for (int skip : skips) {
    test_forward(skip, Emitter::UNCONDITIONAL);
    test_forward(skip, Emitter::IF_TRUE);
    test_forward(skip, Emitter::IF_FALSE);
    test_forward(skip, Emitter::IF_NOT_NULL);
    test_backward(skip);
  }
  test_chain();
  test_loop();
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::compiler::test();
  printf("OK\n");
  return 0;
}
