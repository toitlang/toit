// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <string>

#include "../../src/top.h"
#include "../../src/bytecodes.h"

namespace toit {

using namespace compiler;

#define BYTECODE_NAME(name, length, format, print) #name,
const char* ALL_BYTECODE_NAMES[] {
  BYTECODES(BYTECODE_NAME) "ILLEGAL"
};
#undef BYTECODE_NAME

static bool ends_with(const std::string& str, const std::string& suffix) {
  return str.size() >= suffix.size() &&
      str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

int main(int argc, char** argv) {
  int count = sizeof(ALL_BYTECODE_NAMES) / sizeof(ALL_BYTECODE_NAMES[0]);
  std::string last;
  for (int i = 0; i < count; i++) {
    auto current = std::string(ALL_BYTECODE_NAMES[i]);
    if (ends_with(current, "WIDE")) {
      printf("checking %s\n", current.c_str());
      if (last + "_WIDE" != current) {
        FATAL("WIDE bytecode must be non-wide + 1");
      }
    }
    last = current;
  }
  return 0;
}

}

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  return toit::main(argc, argv);
}
