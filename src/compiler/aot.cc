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
  Program* program = types_->program();
  output_ << "void run(Process* process, Object** sp) {" << std::endl;
  output_ << "  PUSH(process->task());" << std::endl;
  output_ << "  PUSH(Smi::from(0));  // Should be: return address" << std::endl;
  output_ << "  PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
  int entry = program->absolute_bci_from_bcp(program->entry_main().entry());
  output_ << "  goto L" << entry << ";  // __entry__main" << std::endl;

  auto methods = types_->methods();
  std::sort(methods.begin(), methods.end(), [&](Method a, Method b) {
    return a.header_bcp() < b.header_bcp();
  });
  for (unsigned i = 0; i < methods.size(); i++) {
    uint8* end = (i == methods.size() - 1)
        ? program->bytecodes.data() + program->bytecodes.length()
        : methods[i + 1].header_bcp();
    output_ << std::endl;
    emit_method(methods[i], end);
  }
  output_ << "}" << std::endl;
}

#define B_ARG1(name) const int name = bcp[1];
#define B_ARG2(name) const int name = bcp[2];
#define S_ARG1(name) const int name = Utils::read_unaligned_uint16(bcp + 1);

void CcGenerator::emit_method(Method method, uint8* end) {
  Program* program = types_->program();
  int id = program->absolute_bci_from_bcp(method.header_bcp());
  int size = end - method.entry();
  output_ << "  // Method @ " << id << " (" << size << " bytes)" << std::endl;
  uint8* bcp = method.entry();
  while (bcp < end) {
    uint8 opcode = *bcp;
    int bci = program->absolute_bci_from_bcp(bcp);
    if (opcode >= ILLEGAL_END) {
      output_ << "  UNREACHABLE();" << std::endl;
      break;
    }
    output_ << "  L" << bci << ": {  // " << opcode_print[opcode] << std::endl;
    switch (opcode) {
      case HALT: {
        output_ << "    return;" << std::endl;
        break;
      }

      case POP: {
        B_ARG1(index);
        output_ << "    DROP(" << index << ");" << std::endl;
        break;
      }

      case POP_1: {
        output_ << "    DROP(1);" << std::endl;
        break;
      }

      case INVOKE_STATIC: {
        S_ARG1(offset);
        Method target(program->bytecodes, program->dispatch_table[offset]);
        int entry = program->absolute_bci_from_bcp(target.entry());
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_STATIC_LENGTH);
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto L" << entry << ";" << std::endl;
        break;
      }

      case RETURN: {
        B_ARG1(offset);
        B_ARG2(arity);
        output_ << "    Object* result = STACK_AT(0);" << std::endl;
        output_ << "    DROP(" << (offset + 1) << ");" << std::endl;
        output_ << "    void* continuation = POP();" << std::endl;
        output_ << "    DROP(" << arity << ");" << std::endl;
        output_ << "    PUSH(result);" << std::endl;
        output_ << "    goto *continuation;" << std::endl;
        break;
      }

      default: {
        output_ << "    UNIMPLEMENTED();" << std::endl;
        break;
      }
    }
    output_ << "  }" << std::endl;
    bcp += opcode_length[opcode];
  }
}

void compile_to_cc(TypeDatabase* types) {
  CcGenerator generator(types);
  generator.emit();
  printf("%s", generator.output().c_str());
}

}  // namespace toit::compiler
}  // namespace toit
