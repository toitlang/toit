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
  output_ << "#include \"aot_support.h\"" << std::endl << std::endl;
  output_ << "Object* run(Process* process, Object** sp) {" << std::endl;
  output_ << "  Object* result = Smi::from(0);" << std::endl;
  output_ << "  Object* const null_object = process->program()->null_object();" << std::endl;
  output_ << "  Object* const true_object = process->program()->true_object();" << std::endl;
  output_ << "  Object* const false_object = process->program()->false_object();" << std::endl << std::endl;

  List<int32> dispatch_table = program->dispatch_table;
  output_ << "  static void* vtbl[] = {" << std::endl;
  for (int i = 0; i < dispatch_table.length(); i++) {
    int offset = dispatch_table[i];
    if (offset >= 0) {
      Method method(program->bytecodes, offset);
      if (method.selector_offset() >= 0 && !types_->is_dead_method(offset)) {
        output_ << "    &&L" << program->absolute_bci_from_bcp(method.entry()) << ", " << std::endl;
        continue;
      }
    }
    output_ << "    null," << std::endl;
  }
  output_ << "  };" << std::endl << std::endl;

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
    Method method = methods[i];
    uint8* end = (i == methods.size() - 1)
        ? program->bytecodes.data() + program->bytecodes.length()
        : methods[i + 1].header_bcp();
    output_ << std::endl;
    emit_method(method, end);
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
      case LOAD_SMI_0: {
        output_ << "    PUSH(Smi::from(0));" << std::endl;
        break;
      }

      case LOAD_SMI_1: {
        output_ << "    PUSH(Smi::from(1));" << std::endl;
        break;
      }

      case LOAD_SMI_U8: {
        B_ARG1(value);
        output_ << "    PUSH(Smi::from(" << value << "));" << std::endl;
        break;
      }

      case LOAD_LOCAL_0:
      case LOAD_LOCAL_1:
      case LOAD_LOCAL_2:
      case LOAD_LOCAL_3:
      case LOAD_LOCAL_4:
      case LOAD_LOCAL_5: {
        output_ << "    PUSH(STACK_AT(" << (opcode - LOAD_LOCAL_0) << "));" << std::endl;
        break;
      }

      case LOAD_LOCAL:
      case LOAD_LOCAL_WIDE: {
        int index = (opcode == LOAD_LOCAL) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    PUSH(STACK_AT(" << index << "));" << std::endl;
        break;
      }

      case POP: {
        B_ARG1(index);
        output_ << "    DROP(" << index << ");" << std::endl;
        break;
      }

      case POP_1: {
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case ALLOCATE:
      case ALLOCATE_WIDE: {
        int index = (opcode == ALLOCATE) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        Smi* class_id = Smi::from(index);
        int size = program->instance_size_for(class_id);
        int fields = Instance::fields_from_size(size);
        TypeTag class_tag = program->class_tag_for(class_id);
        output_ << "    sp = allocate(sp, process, " << index << ", " << fields << ", " << size << ", static_cast<TypeTag>(" << class_tag << "));" << std::endl;
        break;
      }

      case INVOKE_STATIC: {
        S_ARG1(offset);
        Method target(program->bytecodes, program->dispatch_table[offset]);
        int entry = program->absolute_bci_from_bcp(target.entry());
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_STATIC_LENGTH);
        if (types_->is_dead_call(next)) {
          output_ << "    UNREACHABLE();" << std::endl;
        } else {
          output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
          output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
          output_ << "    goto L" << entry << ";" << std::endl;
        }
        break;
      }

      case INVOKE_VIRTUAL: {
        B_ARG1(index);
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_VIRTUAL_LENGTH);
        int offset = Utils::read_unaligned_uint16(bcp + 2);
        output_ << "    Object* receiver = STACK_AT(" << index << ");" << std::endl;
        output_ << "    int id = is_smi(receiver) ? " << program->smi_class_id()->value() << " : HeapObject::cast(receiver)->class_id()->value();" << std::endl;
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto *vtbl[id + " << offset << "];" << std::endl;
        break;
      }

      case INVOKE_ADD: {
        output_ << "    Object* right = STACK_AT(0);" << std::endl;
        output_ << "    Object* left = STACK_AT(1);" << std::endl;
        output_ << "    Object* result;" << std::endl;
        output_ << "    if (add_smis(left, right, &result)) {" << std::endl;
        output_ << "      STACK_AT_PUT(1, result);" << std::endl;
        output_ << "      DROP1();" << std::endl;
        output_ << "    } else {" << std::endl;
        output_ << "      sp = add_int_int(sp);" << std::endl;
        output_ << "    }" << std::endl;
        break;
      }

      case INVOKE_SUB: {
        output_ << "    Object* right = STACK_AT(0);" << std::endl;
        output_ << "    Object* left = STACK_AT(1);" << std::endl;
        output_ << "    Object* result;" << std::endl;
        output_ << "    if (sub_smis(left, right, &result)) {" << std::endl;
        output_ << "      STACK_AT_PUT(1, result);" << std::endl;
        output_ << "      DROP1();" << std::endl;
        output_ << "    } else {" << std::endl;
        output_ << "      sp = sub_int_int(sp);" << std::endl;
        output_ << "    }" << std::endl;
        break;
      }

      case INVOKE_LTE: {
        output_ << "    Object* right = STACK_AT(0);" << std::endl;
        output_ << "    Object* left = STACK_AT(1);" << std::endl;
        output_ << "    STACK_AT_PUT(1, BOOL(lte_ints(left, right)));" << std::endl;
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case BRANCH_IF_FALSE: {
        S_ARG1(offset);
        int target = program->absolute_bci_from_bcp(bcp + offset);
        output_ << "    Object* value = POP();" << std::endl;
        output_ << "    if (!IS_TRUE_VALUE(value)) goto L" << target << ";" << std::endl;
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

      case HALT: {
        output_ << "    return result;" << std::endl;
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
