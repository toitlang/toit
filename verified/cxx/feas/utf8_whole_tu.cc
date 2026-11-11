// Copyright (C) 2026 Toit contributors.
// Feasibility probe: does the C++ front end of a tool take the real
// src/utils.cc (which includes objects.h and process.h) as one
// translation unit? (verified/CXX-VERIFICATION-PILOT.md, "Feasibility".)
#include "../harness/cxxv.h"
#include "../../../src/utils.cc"

using namespace toit;

int main() {
  const int N = 6;
  uint8 in[N];
  for (int i = 0; i < N; i++) in[i] = nondet_uchar();
  word len = nondet_int();
  CXXV_ASSUME(0 <= len && len <= N);
  uint16 out[N];
  word r = Utils::utf_8_to_16(in, len, out, N);
  CXXV_ASSERT(r <= len, "size bound");
  return 0;
}
