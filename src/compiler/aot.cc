// Copyright (C) 2023 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "aot.h"

#include <algorithm>
#include <string>
#include <sstream>

namespace toit {
namespace compiler {

#define BYTECODE_LENGTH(name, length, format, print) length,
static int opcode_length[] { BYTECODES(BYTECODE_LENGTH) -1 };
#undef BYTECODE_LENGTH

#define BYTECODE_PRINT(name, length, format, print) print,
static const char* opcode_print[] { BYTECODES(BYTECODE_PRINT) null };
#undef BYTECODE_PRINT

class CcGenerator {
 public:
  explicit CcGenerator(TypeDatabase* types)
     : types_(types) {}

  void emit();
  std::string output() const { return output_.str(); }

 private:
  TypeDatabase* const types_;
  std::stringstream output_;

  void emit_method(Method method, uint8* end);
};

void CcGenerator::emit() {
  output_ << "void funk() {" << std::endl;
  auto methods = types_->methods();
  std::sort(methods.begin(), methods.end(), [&](Method a, Method b) {
    return a.header_bcp() < b.header_bcp();
  });
  Program* program = types_->program();
  for (unsigned i = 0; i < methods.size(); i++) {
    uint8* end = (i == methods.size() - 1)
        ? program->bytecodes.data() + program->bytecodes.length()
        : methods[i + 1].header_bcp();
    if (i != 0) output_ << std::endl;
    emit_method(methods[i], end);
  }
  output_ << "}" << std::endl;
}

void CcGenerator::emit_method(Method method, uint8* end) {
  int id = types_->program()->absolute_bci_from_bcp(method.header_bcp());
  int size = end - method.entry();
  output_ << "  // Method @ " << id << " (" << size << " bytes)" << std::endl;
  uint8* bcp = method.entry();
  while (bcp < end) {
    uint8 opcode = *bcp;
    int bci = types_->program()->absolute_bci_from_bcp(bcp);
    if (opcode >= ILLEGAL_END) {
      // printf("[got in trouble at %p | %d]\n", bcp, bci);
      break;
    }
    output_ << "  L" << bci << ": {  // " << opcode_print[opcode] << std::endl;
    switch (opcode) {
      default:
        output_ << "    return;" << std::endl;
        break;
    }
    output_ << "  }" << std::endl;
    bcp += opcode_length[opcode];
    // printf("bcp = %p (opcode = %d | %s)\n", bcp, opcode, opcode_print[opcode]);
  }
}

void compile_to_cc(TypeDatabase* types) {
  CcGenerator generator(types);
  generator.emit();
  printf("%s", generator.output().c_str());
}

}  // namespace toit::compiler
}  // namespace toit
