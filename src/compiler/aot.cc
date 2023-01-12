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
#include "resolver_primitive.h"
#include "../interpreter.h"

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
  output_ << "void run(Process* process, Object** sp) {" << std::endl;
  output_ << "  Object* const null_object = process->program()->null_object();" << std::endl;
  output_ << "  Object* const true_object = process->program()->true_object();" << std::endl;
  output_ << "  Object* const false_object = process->program()->false_object();" << std::endl << std::endl;

  List<int32> dispatch_table = program->dispatch_table;
  output_ << "  static const void* const vtbl[] = {" << std::endl;
  for (int i = 0; i < dispatch_table.length(); i++) {
    int offset = dispatch_table[i];
    if (offset >= 0) {
      Method method(program->bytecodes, offset);
      if (method.selector_offset() >= 0 && !types_->is_dead_method(offset)) {
        output_ << "    &&L" << program->absolute_bci_from_bcp(method.entry()) << ", " << std::endl;
        continue;
      }
    }
    output_ << "    0," << std::endl;
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
  output_ << "  // Method @ " << id << " (" << size << " bytes): Begin" << std::endl;
  uint8* bcp = method.entry();
  while (bcp < end) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    int bci = program->absolute_bci_from_bcp(bcp);
    if (opcode >= ILLEGAL_END) {
      output_ << "  UNREACHABLE();" << std::endl;
      break;
    }
    output_ << "  L" << bci << ": __attribute__((unused)); {  // " << opcode_print[opcode] << std::endl;
    switch (opcode) {
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

      case STORE_LOCAL: {
        B_ARG1(index);
        output_ << "    STACK_AT_PUT(" << index << ", STACK_AT(0));" << std::endl;
        break;
      }

      case STORE_LOCAL_POP: {
        B_ARG1(index);
        output_ << "    STACK_AT_PUT(" << index << ", STACK_AT(0));" << std::endl;
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case LOAD_OUTER: {
        B_ARG1(index);
        output_ << "    Object** block = reinterpret_cast<Object**>(STACK_AT(0));" << std::endl;
        output_ << "    STACK_AT_PUT(0, block[" << index << "]);" << std::endl;
        break;
      }

      case STORE_OUTER: {
        B_ARG1(index);
        output_ << "    Object* value = STACK_AT(0);" << std::endl;
        output_ << "    Object** block = reinterpret_cast<Object**>(STACK_AT(1));" << std::endl;
        output_ << "    block[" << index << "] = value;" << std::endl;
        output_ << "    STACK_AT_PUT(1, value);" << std::endl;
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case LOAD_FIELD:
      case LOAD_FIELD_WIDE: {
        int index = (opcode == LOAD_FIELD) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    Instance* instance = Instance::cast(STACK_AT(0));" << std::endl;
        output_ << "    STACK_AT_PUT(0, instance->at(" << index << "));" << std::endl;
        break;
      }

      case LOAD_FIELD_LOCAL: {
        B_ARG1(encoded);
        int local = encoded & 0x0f;
        int field = encoded >> 4;
        output_ << "    Instance* instance = Instance::cast(STACK_AT(" << local << "));" << std::endl;
        output_ << "    PUSH(instance->at(" << field << "));" << std::endl;
        break;
      }

      case POP_LOAD_FIELD_LOCAL: {
        B_ARG1(encoded);
        int local = encoded & 0x0f;
        int field = encoded >> 4;
        output_ << "    Instance* instance = Instance::cast(STACK_AT(" << (local + 1) << "));" << std::endl;
        output_ << "    STACK_AT_PUT(0, instance->at(" << field << "));" << std::endl;
        break;
      }

      case STORE_FIELD:
      case STORE_FIELD_WIDE: {
        int index = (opcode == STORE_FIELD) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    Object* value = STACK_AT(0);" << std::endl;
        output_ << "    Instance* instance = Instance::cast(STACK_AT(1));" << std::endl;
        output_ << "    instance->at_put(" << index << ", value);" << std::endl;
        output_ << "    STACK_AT_PUT(1, value);" << std::endl;
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case STORE_FIELD_POP: {
        B_ARG1(index);
        output_ << "    Object* value = STACK_AT(0);" << std::endl;
        output_ << "    Instance* instance = Instance::cast(STACK_AT(1));" << std::endl;
        output_ << "    instance->at_put(" << index << ", value);" << std::endl;
        output_ << "    DROP(2);" << std::endl;
        break;
      }

      case LOAD_LITERAL:
      case LOAD_LITERAL_WIDE: {
        int index = (opcode == LOAD_LITERAL) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        switch (index) {
          case 0:
            output_ << "    PUSH(true_object);" << std::endl;
            break;
          case 1:
            output_ << "    PUSH(false_object);" << std::endl;
            break;
          default:
            output_ << "    PUSH(process->program()->literals.at(" << index << "));" << std::endl;
            break;
        }
        break;
      }

      case LOAD_NULL: {
        output_ << "    PUSH(null_object);" << std::endl;
        break;
      }

      case LOAD_SMI_0: {
        output_ << "    PUSH(Smi::from(0));" << std::endl;
        break;
      }

      case LOAD_SMIS_0: {
        B_ARG1(n);
        output_ << "for (int i = 0; i < " << n << "; i++) PUSH(Smi::from(0));" << std::endl;
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

      case LOAD_SMI_U16: {
        uint16 value = Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    PUSH(Smi::from(" << value << "));" << std::endl;
        break;
      }

      case LOAD_SMI_U32: {
        uint32 value = Utils::read_unaligned_uint32(bcp + 1);
        output_ << "    PUSH(Smi::from(" << value << "));" << std::endl;
        break;
      }

      case LOAD_METHOD: {
        int offset = Utils::read_unaligned_uint32(bcp + 1);
        if (types_->is_dead_method(offset)) {
          output_ << "    PUSH(Smi::from(0));  // dead" << std::endl;
        } else {
          Method target(program->bytecodes, offset);
          int entry = program->absolute_bci_from_bcp(target.entry());
          output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << entry << "));" << std::endl;
        }
        break;
      }

      case LOAD_GLOBAL_VAR:
      case LOAD_GLOBAL_VAR_WIDE: {
        int index = (opcode == LOAD_GLOBAL_VAR) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    PUSH(process->object_heap()->global_variables()[" << index << "]);" << std::endl;
        break;
      }

      case LOAD_GLOBAL_VAR_LAZY:
      case LOAD_GLOBAL_VAR_LAZY_WIDE: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case STORE_GLOBAL_VAR:
      case STORE_GLOBAL_VAR_WIDE: {
        int index = (opcode == STORE_GLOBAL_VAR) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    process->object_heap()->global_variables()[" << index << "] = STACK_AT(0);" << std::endl;
        break;
      }

      case LOAD_GLOBAL_VAR_DYNAMIC:
      case STORE_GLOBAL_VAR_DYNAMIC: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case LOAD_BLOCK: {
        B_ARG1(index);
        // TODO(kasper): This should be the distance from the bottom of the stack, so we can
        // relocate the blocks correctly later.
        output_ << "    PUSH(reinterpret_cast<Object*>(sp + " << index << "));" << std::endl;
        break;
      }

      case LOAD_OUTER_BLOCK: {
        B_ARG1(index);
        output_ << "    Object** block = reinterpret_cast<Object**>(STACK_AT(0));" << std::endl;
        output_ << "    STACK_AT_PUT(0, reinterpret_cast<Object*>(block + " << index << "));" << std::endl;
        break;
      }

      case POP_LOAD_LOCAL: {
        B_ARG1(offset);
        output_ << "    STACK_AT_PUT(0, STACK_AT(" << offset + 1 << "));" << std::endl;
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

      case IS_CLASS:
      case IS_CLASS_WIDE: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case IS_INTERFACE:
      case IS_INTERFACE_WIDE: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case AS_CLASS:
      case AS_CLASS_WIDE:
      case AS_LOCAL: {
        output_ << "    // Should be: Check class!" << std::endl;
        break;
      }

      case AS_INTERFACE:
      case AS_INTERFACE_WIDE: {
        output_ << "    // Should be: Check interface!" << std::endl;
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

      case INVOKE_STATIC_TAIL: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case INVOKE_BLOCK: {
        B_ARG1(index);
        output_ << "    void** block = reinterpret_cast<void**>(STACK_AT(" << (index - 1) << "));" << std::endl;
        // TODO(kasper): We need to handle the case where we are providing too many
        // arguments to the block call somehow.
        output_ << "    void* continuation = *block;" << std::endl;
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_BLOCK_LENGTH);
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto* continuation;" << std::endl;
        break;
      }

      case INVOKE_LAMBDA_TAIL: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case INVOKE_INITIALIZER_TAIL: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
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

      case INVOKE_VIRTUAL_WIDE: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case INVOKE_VIRTUAL_GET: {
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_VIRTUAL_GET_LENGTH);
        int offset = Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    Object* receiver = STACK_AT(0);" << std::endl;
        output_ << "    int id = is_smi(receiver) ? " << program->smi_class_id()->value() << " : HeapObject::cast(receiver)->class_id()->value();" << std::endl;
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto *vtbl[id + " << offset << "];" << std::endl;
        break;
      }

      case INVOKE_VIRTUAL_SET: {
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_VIRTUAL_SET_LENGTH);
        int offset = Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    Object* receiver = STACK_AT(1);" << std::endl;
        output_ << "    int id = is_smi(receiver) ? " << program->smi_class_id()->value() << " : HeapObject::cast(receiver)->class_id()->value();" << std::endl;
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto *vtbl[id + " << offset << "];" << std::endl;
        break;
      }

      case INVOKE_EQ:
      case INVOKE_LT:
      case INVOKE_GT:
      case INVOKE_LTE:
      case INVOKE_GTE:
      case INVOKE_BIT_OR:
      case INVOKE_BIT_XOR:
      case INVOKE_BIT_AND:
      case INVOKE_BIT_SHL:
      case INVOKE_BIT_SHR:
      case INVOKE_BIT_USHR:
      case INVOKE_ADD:
      case INVOKE_SUB:
      case INVOKE_MUL:
      case INVOKE_DIV:
      case INVOKE_MOD:
      case INVOKE_AT:
      case INVOKE_AT_PUT: {
        int index = (opcode == INVOKE_AT_PUT) ? 2 : 1;
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        int offset = program->invoke_bytecode_offset(opcode);
        output_ << "    Object* receiver = STACK_AT(" << index << ");" << std::endl;
        output_ << "    int id = is_smi(receiver) ? " << program->smi_class_id()->value() << " : HeapObject::cast(receiver)->class_id()->value();" << std::endl;
        output_ << "    PUSH(reinterpret_cast<Object*>(&&L" << next << "));" << std::endl;
        output_ << "    PUSH(Smi::from(0));  // Should be: frame marker" << std::endl;
        output_ << "    goto *vtbl[id + " << offset << "];" << std::endl;
        break;
      }

/*
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
*/

      case BRANCH:
      case BRANCH_BACK: {
        S_ARG1(offset);
        int target = (opcode == BRANCH)
            ? program->absolute_bci_from_bcp(bcp + offset)
            : program->absolute_bci_from_bcp(bcp - offset);
        output_ << "    goto L" << target << ";" << std::endl;
        break;
      }

      case BRANCH_IF_TRUE:
      case BRANCH_BACK_IF_TRUE: {
        S_ARG1(offset);
        int target = (opcode == BRANCH_IF_TRUE)
            ? program->absolute_bci_from_bcp(bcp + offset)
            : program->absolute_bci_from_bcp(bcp - offset);
        output_ << "    Object* value = POP();" << std::endl;
        output_ << "    if (IS_TRUE_VALUE(value)) goto L" << target << ";" << std::endl;
        break;
      }

      case BRANCH_IF_FALSE:
      case BRANCH_BACK_IF_FALSE: {
        S_ARG1(offset);
        int target = (opcode == BRANCH_IF_FALSE)
            ? program->absolute_bci_from_bcp(bcp + offset)
            : program->absolute_bci_from_bcp(bcp - offset);
        output_ << "    Object* value = POP();" << std::endl;
        output_ << "    if (!IS_TRUE_VALUE(value)) goto L" << target << ";" << std::endl;
        break;
      }

      case PRIMITIVE: {
        B_ARG1(module);
        unsigned index = Utils::read_unaligned_uint16(bcp + 2);
        int arity = PrimitiveResolver::arity(index, module);
        const int parameter_offset = Interpreter::FRAME_SIZE;
        output_ << "    const PrimitiveEntry* primitive = Primitive::at(" << module << ", " << index << ");  // ";
        output_ << PrimitiveResolver::module_name(module) << "." << PrimitiveResolver::primitive_name(module, index) << std::endl;
        output_ << "    Primitive::Entry* entry = reinterpret_cast<Primitive::Entry*>(primitive->function);" << std::endl;
        output_ << "    Object* result = entry(process, sp + " << (parameter_offset + arity - 1) << ");" << std::endl;
        output_ << "    void* continuation = STACK_AT(1);" << std::endl;
        output_ << "    DROP(" << (arity + 1) << ");" << std::endl;
        output_ << "    STACK_AT_PUT(0, result);" << std::endl;
        output_ << "    goto *continuation;" << std::endl;
        break;
      }

      case THROW: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case RETURN: {
        B_ARG1(offset);
        B_ARG2(arity);
        output_ << "    Object* result = STACK_AT(0);" << std::endl;
        output_ << "    void* continuation = STACK_AT(" << (offset + 1) << ");" << std::endl;
        output_ << "    DROP(" << (arity + offset + 1) << ");" << std::endl;
        output_ << "    STACK_AT_PUT(0, result);" << std::endl;
        output_ << "    goto *continuation;" << std::endl;
        break;
      }

      case RETURN_NULL: {
        B_ARG1(offset);
        B_ARG2(arity);
        output_ << "    void* continuation = STACK_AT(" << (offset + 1) << ");" << std::endl;
        output_ << "    DROP(" << (arity + offset + 1) << ");" << std::endl;
        output_ << "    STACK_AT_PUT(0, null_object);" << std::endl;
        output_ << "    goto *continuation;" << std::endl;
        break;
      }

      case NON_LOCAL_RETURN:
      case NON_LOCAL_RETURN_WIDE: {
        int arity = -1;
        int height = -1;
        if (opcode == NON_LOCAL_RETURN) {
          B_ARG1(encoded);
          arity = encoded & 0x0f;
          height = encoded >> 4;
        } else {
          arity = Utils::read_unaligned_uint16(bcp + 1);
          height = Utils::read_unaligned_uint16(bcp + 3);
        }
        // TODO(kasper): Handle linked frames.
        output_ << "    Object** block = reinterpret_cast<Object**>(STACK_AT(0));" << std::endl;
        output_ << "    Object* result = STACK_AT(1);" << std::endl;
        output_ << "    sp = block + " << (height + 2) << ";" << std::endl;
        output_ << "    void* continuation = STACK_AT(0);" << std::endl;
        output_ << "    STACK_AT_PUT(" << arity << ", result);" << std::endl;
        if (arity > 0) {
          output_ << "    DROP(" << arity << ");" << std::endl;
        }
        output_ << "    goto *continuation;" << std::endl;
        break;
      }

      case NON_LOCAL_BRANCH: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case IDENTICAL: {
        // TODO(kasper): Fix the semantics.
        output_ << "    Object* right = STACK_AT(0);" << std::endl;
        output_ << "    Object* left = STACK_AT(1);" << std::endl;
        output_ << "    STACK_AT_PUT(1, BOOL(left == right));" << std::endl;
        output_ << "    DROP1();" << std::endl;
        break;
      }

      case LINK: {
        output_ << "    PUSH(Smi::from(0xbeef));" << std::endl;
        output_ << "    PUSH(Smi::from(-0xdead));" << std::endl;
        output_ << "    PUSH(Smi::from(-1));" << std::endl;
        // TODO(kasper): This should be the link.
        output_ << "    PUSH(reinterpret_cast<Object*>(sp));" << std::endl;
        break;
      }

      case UNLINK: {
        // TODO(kasper): Restore the link.
        output_ << "     DROP1();" << std::endl;
        break;
      }

      case UNWIND: {
        // TODO(kasper): Check if we need to continue unwinding.
        output_ << "     DROP(3);" << std::endl;
        break;
      }

      case HALT: {
        output_ << "    return;" << std::endl;
        break;
      }

      case INTRINSIC_SMI_REPEAT:
      case INTRINSIC_ARRAY_DO:
      case INTRINSIC_HASH_FIND:
      case INTRINSIC_HASH_DO: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case ILLEGAL_END: {
        UNREACHABLE();
      }
    }
    output_ << "  }" << std::endl;
    bcp += opcode_length[opcode];
  }

  output_ << "  __builtin_unreachable();" << std::endl;
  output_ << "  // Method @ " << id << " (" << size << " bytes): End" << std::endl;
}

void compile_to_cc(TypeDatabase* types) {
  CcGenerator generator(types);
  generator.emit();
  printf("%s", generator.output().c_str());
}

}  // namespace toit::compiler
}  // namespace toit
