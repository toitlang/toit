// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <string>
#include <stdio.h>

#include "../../src/bytecodes.h"

namespace toit {

using namespace compiler;

struct Bytecode {
  const char* name;
  int length;
  const char* format;
  const char* print;
};

#define BYTECODE_STRUCT(name_, length_, format_, print_) \
  { .name=#name_, .length=length_, .format=#format_, .print=print_ },
const Bytecode ALL_BYTECODES[] {
  BYTECODES(BYTECODE_STRUCT)
  { .name="ILLEGAL", .length=0, .format="", .print="" }
};
#undef BYTECODE_STRUCT

int main(int argc, char** argv) {
  int count = sizeof(ALL_BYTECODES) / sizeof(ALL_BYTECODES[0]);
  // Don't print the illegal one.
  for (int i = 0; i < count - 1; i++) {
    printf("%s %d %s %s\n",
            ALL_BYTECODES[i].name,
            ALL_BYTECODES[i].length,
            ALL_BYTECODES[i].format,
            ALL_BYTECODES[i].print);
  }
  return 0;
}

}

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
