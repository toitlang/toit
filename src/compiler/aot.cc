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
#include "set.h"
#include "source_mapper.h"

#include "../interpreter.h"

#include <algorithm>
#include <string>
#include <sstream>
#include <set>

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

  void emit(std::vector<int> offsets);
  std::string output() const { return output_.str(); }

 private:
  TypeDatabase* const types_;
  std::stringstream output_;

  void emit_method(Method method);
  void emit_range(uint8* mend, uint8* begin, uint8* end);

  void emit_invoke_virtual(uint8* bcp, int arity, int offset);
  void emit_invoke_operation(uint8* bcp, Opcode opcode, const char* mnemonic);

  std::vector<uint8*> split_method(Method method, uint8* end);
  void split_range(uint8* begin, uint8* end, std::set<uint8*>& points);

  static std::string branch(uint8* begin, uint8* end, Program* program, uint8* target) {
    int id = program->absolute_bci_from_bcp(target);
    if (target >= begin && target < end) {
      return std::string("goto L") + std::to_string(id);
    } else {
      return std::string("TAILCALL return bb_") + std::to_string(id) + "(RUN_ARGS)";
    }
  }

  enum OperandKind {
    UNKNOWN_NOT_SMI,
    UNKNOWN_MAYBE_SMI,
    INT_DEFINITELY_SMI,
    INT_NOT_SMI,
    INT_MAYBE_SMI
  };

  static OperandKind operand_kind(Program* program, TypeSet type) {
    int size = type.size(TypeSet::words_per_type(program));
    bool contains_smi = type.contains_smi(program);
    bool contains_lgi = type.contains_instance(program->large_integer_class_id());
    if (size == 1) {
      if (contains_smi) return INT_DEFINITELY_SMI;
      return contains_lgi ? INT_NOT_SMI : UNKNOWN_NOT_SMI;
    } else if (size == 2) {
      if (!contains_smi) return UNKNOWN_NOT_SMI;
      return contains_lgi ? INT_MAYBE_SMI : UNKNOWN_MAYBE_SMI;
    } else {
      return contains_smi ? UNKNOWN_MAYBE_SMI : UNKNOWN_NOT_SMI;
    }
  }

  static bool is_int(OperandKind kind) { return kind >= INT_DEFINITELY_SMI; }
  static bool is_likely_smi(OperandKind kind) { return kind == INT_DEFINITELY_SMI || kind == INT_MAYBE_SMI; }
  static bool is_maybe_smi(OperandKind kind) { return kind != UNKNOWN_NOT_SMI && kind != INT_NOT_SMI; }
};

void CcGenerator::emit(std::vector<int> offsets) {
  Program* program = types_->program();
  output_ << "#include \"aot_support.h\"" << std::endl << std::endl;

  std::vector<Method> methods;
  for (auto it : offsets) {
    methods.push_back(Method(program->bytecodes, it));
  }

  std::sort(methods.begin(), methods.end(), [&](Method a, Method b) {
    return a.header_bcp() < b.header_bcp();
  });

  for (unsigned i = 0; i < methods.size(); i++) {
    Method method = methods[i];
    if (types_->is_dead_method(program->absolute_bci_from_bcp(method.header_bcp()))) {
      // Skip dead methods completely.
      continue;
    }
    uint8* end = (i == methods.size() - 1)
        ? program->bytecodes.data() + program->bytecodes.length()
        : methods[i + 1].header_bcp();
    int id = program->absolute_bci_from_bcp(method.header_bcp());
    output_ << "static void method_" << id << "(RUN_PARAMS) __attribute__((unused));" << std::endl;
    auto points = split_method(method, end);
    for (unsigned j = 0; j < points.size(); j++) {
      int entry = program->absolute_bci_from_bcp(points[j]);
      output_ << "static void bb_" << entry << "(RUN_PARAMS) __attribute__((unused));" << std::endl;
    }
    output_ << std::endl;
  }

  output_ << "static void method_illegal(RUN_PARAMS) __attribute__((unused));" << std::endl;
  output_ << "static void method_illegal(RUN_PARAMS) {" << std::endl;
  output_ << "  UNIMPLEMENTED();" << std::endl;
  output_ << "};" << std::endl << std::endl;

  List<int32> dispatch_table = program->dispatch_table;
  int selector_offset_max = 0;
  for (int i = 0; i < dispatch_table.length(); i++) {
    int offset = dispatch_table[i];
    if (offset < 0) continue;
    Method method(program->bytecodes, offset);
    selector_offset_max = Utils::max(selector_offset_max, method.selector_offset());
  }

  output_ << "static const run_func vtbl[] = {" << std::endl;
  int limit = selector_offset_max + program->class_bits.length();
  for (int i = 0; i < limit; i++) {
    int offset = dispatch_table[i];
    if (offset >= 0) {
      Method method(program->bytecodes, offset);
      if (method.selector_offset() >= 0 && !types_->is_dead_method(offset)) {
        int entry = program->absolute_bci_from_bcp(method.header_bcp());
        output_ << "  &method_" << entry << ", " << std::endl;
        continue;
      }
    }
    output_ << "  &method_illegal," << std::endl;
  }
  output_ << "};" << std::endl;

  for (unsigned i = 0; i < methods.size(); i++) {
    Method method = methods[i];
    if (types_->is_dead_method(program->absolute_bci_from_bcp(method.header_bcp()))) {
      // Skip dead methods completely.
      continue;
    }
    uint8* mend = (i == methods.size() - 1)
        ? program->bytecodes.data() + program->bytecodes.length()
        : methods[i + 1].header_bcp();
    auto points = split_method(method, mend);
    output_ << std::endl;
    emit_method(method);
    for (unsigned j = 0; j < points.size(); j++) {
      uint8* end = (j == points.size() - 1)
          ? mend
          : points[j + 1];
      output_ << std::endl;
      emit_range(mend, points[j], end);
    }
  }

  output_ << std::endl;
  output_ << "void run(Process* process, Object** sp) {" << std::endl;
  output_ << "  Object* const null_object = process->program()->null_object();" << std::endl;
  output_ << "  Object* const true_object = process->program()->true_object();" << std::endl;
  output_ << "  Object* const false_object = process->program()->false_object();" << std::endl << std::endl;

  output_ << "  Wonk wonky = {" << std::endl;
  output_ << "    .process  = process," << std::endl;
  output_ << "    .heap     = process->object_heap()," << std::endl;
  output_ << "    .globals  = process->object_heap()->global_variables()," << std::endl;
  output_ << "    .literals = process->program()->literals.array()," << std::endl;
  output_ << "    .base     = 0," << std::endl;
  output_ << "    .limit    = 0," << std::endl;
  output_ << "  };" << std::endl;
  output_ << "  Wonk* wonk = &wonky;" << std::endl;

  output_ << "  PUSH(process->task());" << std::endl;
  int id = program->absolute_bci_from_bcp(program->entry_main().header_bcp());
  output_ << "  method_" << id << "(RUN_ARGS_XX(0, 0));  // __entry__main" << std::endl;
  output_ << "}" << std::endl;
}

#define B_ARG1(name) const int name = bcp[1];
#define B_ARG2(name) const int name = bcp[2];
#define S_ARG1(name) const int name = Utils::read_unaligned_uint16(bcp + 1);

void CcGenerator::emit_method(Method method) {
  Program* program = types_->program();
  int id = program->absolute_bci_from_bcp(method.header_bcp());
  output_ << "static void method_" << id << "(RUN_PARAMS) {" << std::endl;

  if (method.is_normal_method() || method.is_field_accessor()) {
    if (method.selector_offset() >= 0) {
      output_ << "  int selector = reinterpret_cast<word>(x2);" << std::endl;
      output_ << "  if (UNLIKELY(selector != " << method.selector_offset() << ")) {" << std::endl;
      output_ << "    UNIMPLEMENTED();  // Should be: Lookup error." << std::endl;
      output_ << "  }" << std::endl;
    }
  } else if (method.is_block_method()) {
    output_ << "  int arguments = reinterpret_cast<word>(x2);" << std::endl;
    output_ << "  int excessive = arguments - " << method.arity() << ";" << std::endl;
    output_ << "  if (excessive != 0) {" << std::endl;
    output_ << "    if (LIKELY(excessive > 0)) {" << std::endl;
    output_ << "      DROP(excessive);" << std::endl;
    output_ << "    } else {" << std::endl;
    output_ << "      UNIMPLEMENTED();  // Should be: Too few arguments." << std::endl;
    output_ << "    }" << std::endl;
    output_ << "  }" << std::endl;
  }

  output_ << "  PUSH(reinterpret_cast<Object*>(extra));" << std::endl;
  output_ << "  PUSH(Smi::from(0));  // Should be: Frame marker." << std::endl;
  output_ << "  " << branch(0, 0, program, method.entry()) << ";" << std::endl;
  output_ << "}" << std::endl;
}

void CcGenerator::emit_range(uint8* mend, uint8* begin, uint8* end) {
  Program* program = types_->program();

  uint8* bcp = begin;
  output_ << "static void bb_" << program->absolute_bci_from_bcp(bcp) << "(RUN_PARAMS) {" << std::endl;

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
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    TAILCALL return store_field(RUN_ARGS_XX(&bb_" << next << ", " << index << "));" << std::endl;
        break;
      }

      case STORE_FIELD_POP: {
        B_ARG1(index);
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    TAILCALL return store_field_pop(RUN_ARGS_XX(&bb_" << next << ", " << index << "));" << std::endl;
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
            output_ << "    PUSH(wonk->literals[" << index << "]);" << std::endl;
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
          output_ << "    PUSH(Smi::from(0));  // Dead." << std::endl;
        } else {
          Method target(program->bytecodes, offset);
          int id = program->absolute_bci_from_bcp(target.header_bcp());
          output_ << "    PUSH(reinterpret_cast<Object*>(&method_" << id << "));" << std::endl;
        }
        break;
      }

      case LOAD_GLOBAL_VAR:
      case LOAD_GLOBAL_VAR_WIDE: {
        int index = (opcode == LOAD_GLOBAL_VAR) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    PUSH(wonk->globals[" << index << "]);" << std::endl;
        break;
      }

      case LOAD_GLOBAL_VAR_LAZY:
      case LOAD_GLOBAL_VAR_LAZY_WIDE: {
        int index = (opcode == LOAD_GLOBAL_VAR_LAZY) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    Object* global = wonk->globals[" << index << "];" << std::endl;
        output_ << "    if (UNLIKELY(is_heap_object(global) && HeapObject::cast(global)->class_id() == Smi::from(" << program->lazy_initializer_class_id()->value() << "))) {" << std::endl;
        output_ << "      PUSH(Smi::from(" << index << "));" << std::endl;
        output_ << "      PUSH(global);" << std::endl;
        int target = program->absolute_bci_from_bcp(program->run_global_initializer().header_bcp());
        output_ << "      TAILCALL return method_" << target << "(RUN_ARGS_X(&bb_" << next << "));" << std::endl;
        output_ << "    }" << std::endl;
        output_ << "    PUSH(global);" << std::endl;
        break;
      }

      case STORE_GLOBAL_VAR:
      case STORE_GLOBAL_VAR_WIDE: {
        int index = (opcode == STORE_GLOBAL_VAR) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        output_ << "    wonk->globals[" << index << "] = STACK_AT(0);" << std::endl;
        break;
      }

      case LOAD_GLOBAL_VAR_DYNAMIC: {
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    TAILCALL return load_global(RUN_ARGS_X(&bb_" << next << "));" << std::endl;
        break;
      }

      case STORE_GLOBAL_VAR_DYNAMIC: {
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    TAILCALL return store_global(RUN_ARGS_X(&bb_" << next << "));" << std::endl;
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
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    TAILCALL return allocate(RUN_ARGS_XX(&bb_" << next << ", " << index << "));" << std::endl;
        break;
      }

      case IS_CLASS:
      case IS_CLASS_WIDE: {
        int encoded = (opcode == IS_CLASS) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        int index = encoded >> 1;
        int lower = program->class_check_ids[2 * index];
        int upper = program->class_check_ids[2 * index + 1];
        bool is_nullable = (encoded & 1) != 0;
        output_ << "    Object* object = STACK_AT(0);" << std::endl;
        if (is_nullable) {
          output_ << "    Object* result = true_object;" << std::endl;
          output_ << "    if (object != null_object) {" << std::endl;
          output_ << "      Smi* id = is_smi(object) ? Smi::from(" << program->smi_class_id()->value() << ") : HeapObject::cast(object)->class_id();" << std::endl;
          output_ << "      result = BOOL(Smi::from(" << lower << ") <= id && id < Smi::from(" << upper << "));" << std::endl;
          output_ << "    }" << std::endl;
          output_ << "    STACK_AT_PUT(0, result);" << std::endl;
        } else {
          output_ << "    Smi* id = is_smi(object) ? Smi::from(" << program->smi_class_id()->value() << ") : HeapObject::cast(object)->class_id();" << std::endl;
          output_ << "    STACK_AT_PUT(0, BOOL(Smi::from(" << lower << ") <= id && id < Smi::from(" << upper << ")));" << std::endl;
        }
        break;
      }

      case IS_INTERFACE:
      case IS_INTERFACE_WIDE: {
        int encoded = (opcode == IS_INTERFACE) ? bcp[1] : Utils::read_unaligned_uint16(bcp + 1);
        int index = encoded >> 1;
        int selector = program->interface_check_offsets[index];
        bool is_nullable = (encoded & 1) != 0;
        output_ << "    Object* object = STACK_AT(0);" << std::endl;
        if (is_nullable) {
          output_ << "    Object* result = true_object;" << std::endl;
          output_ << "    if (object != null_object) {" << std::endl;
          output_ << "      Smi* id = is_smi(object) ? Smi::from(" << program->smi_class_id()->value() << ") : HeapObject::cast(object)->class_id();" << std::endl;
          //output_ << "      result = BOOL(Smi::from(" << lower << ") <= id && id < Smi::from(" << upper << "));" << std::endl;
          output_ << "    }" << std::endl;
          output_ << "    STACK_AT_PUT(0, result);" << std::endl;
        } else {
          output_ << "    Smi* id = is_smi(object) ? Smi::from(" << program->smi_class_id()->value() << ") : HeapObject::cast(object)->class_id();" << std::endl;
          //output_ << "      STACK_AT_PUT(0, BOOL(Smi::from(" << lower << ") <= id && id < Smi::from(" << upper << ")));" << std::endl;
          output_ << "    STACK_AT_PUT(0, BOOL(true));" << std::endl;
        }
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
        int id = program->absolute_bci_from_bcp(target.header_bcp());
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_STATIC_LENGTH);
        if (types_->is_dead_call(next)) {
          output_ << "    UNREACHABLE();" << std::endl;
        } else {
          output_ << "    TAILCALL return method_" << id << "(RUN_ARGS_X(&bb_" << next << "));" << std::endl;
        }
        break;
      }

      case INVOKE_STATIC_TAIL: {
        output_ << "    FATAL(\"unimplemented: " << opcode_print[opcode] << "\");" << std::endl;
        break;
      }

      case INVOKE_BLOCK: {
        B_ARG1(arity);
        output_ << "    run_func* block = reinterpret_cast<run_func*>(STACK_AT(" << (arity - 1) << "));" << std::endl;
        output_ << "    run_func continuation = *block;" << std::endl;
        int next = program->absolute_bci_from_bcp(bcp + INVOKE_BLOCK_LENGTH);
        output_ << "    TAILCALL return continuation(RUN_ARGS_XX(&bb_" << next << ", " << arity << "));" << std::endl;
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
        int offset = Utils::read_unaligned_uint16(bcp + 2);
        emit_invoke_virtual(bcp, index + 1, offset);
        break;
      }

      case INVOKE_VIRTUAL_WIDE: {
        // We never generate this bytecode, because it requires more
        // than 256 arguments and the compiler does not allow that.
        UNREACHABLE();
        break;
      }

      case INVOKE_VIRTUAL_GET: {
        int offset = Utils::read_unaligned_uint16(bcp + 1);
        emit_invoke_virtual(bcp, 1, offset);
        break;
      }

      case INVOKE_VIRTUAL_SET: {
        int offset = Utils::read_unaligned_uint16(bcp + 1);
        emit_invoke_virtual(bcp, 2, offset);
        break;
      }

      case INVOKE_EQ:
      case INVOKE_BIT_OR:
      case INVOKE_BIT_XOR:
      case INVOKE_BIT_AND:
      case INVOKE_BIT_SHL:
      case INVOKE_BIT_SHR:
      case INVOKE_BIT_USHR:
      case INVOKE_MUL:
      case INVOKE_DIV:
      case INVOKE_MOD:
      //case INVOKE_AT:
      case INVOKE_AT_PUT: {
        int arity = (opcode == INVOKE_AT_PUT) ? 3 : 2;
        int offset = program->invoke_bytecode_offset(opcode);
        emit_invoke_virtual(bcp, arity, offset);
        break;
      }

      case INVOKE_AT: {
        std::vector<TypeSet> arguments = types_->input(program->absolute_bci_from_bcp(bcp));
        if (arguments.size() == 2 && arguments[0].size(TypeSet::words_per_type(program)) == 1 && arguments[0].contains_instance(program->byte_array_class_id())) {
          output_ << "    Object* index = STACK_AT(0);" << std::endl;
          output_ << "    ByteArray* array = ByteArray::cast(STACK_AT(1));" << std::endl;
          output_ << "    ByteArray::Bytes bytes(array);" << std::endl;
          output_ << "    STACK_AT_PUT(1, Smi::from(bytes.at(Smi::cast(index)->value())));" << std::endl;
          output_ << "    DROP1();" << std::endl;
        } else {
          int offset = program->invoke_bytecode_offset(opcode);
          emit_invoke_virtual(bcp, 2, offset);
        }
        break;
      }

#define AOT_OPERATION(opcode, mnemonic)                \
      case opcode: {                                   \
        emit_invoke_operation(bcp, opcode, #mnemonic); \
        break;                                         \
      }

      AOT_OPERATION(INVOKE_LT,  lt)
      AOT_OPERATION(INVOKE_LTE, lte)
      AOT_OPERATION(INVOKE_GT,  gt)
      AOT_OPERATION(INVOKE_GTE, gte)
      AOT_OPERATION(INVOKE_ADD, add)
      AOT_OPERATION(INVOKE_SUB, sub)
#undef AOT_OPERATION

      case BRANCH:
      case BRANCH_BACK: {
        S_ARG1(offset);
        uint8* target = (opcode == BRANCH) ? (bcp + offset) : (bcp - offset);
        if (target != mend) {
          output_ << "    " << branch(begin, end, program, target) << ";" << std::endl;
        } else {
          output_ << "    // Dead branch." << std::endl;
          output_ << "    __builtin_unreachable();" << std::endl;
        }
        break;
      }

      case BRANCH_IF_TRUE:
      case BRANCH_BACK_IF_TRUE: {
        S_ARG1(offset);
        uint8* target = (opcode == BRANCH_IF_TRUE) ? (bcp + offset) : (bcp - offset);
        output_ << "    Object* value = POP();" << std::endl;
        output_ << "    if (IS_TRUE_VALUE(value)) " << branch(begin, end, program, target) << ";" << std::endl;
        break;
      }

      case BRANCH_IF_FALSE:
      case BRANCH_BACK_IF_FALSE: {
        S_ARG1(offset);
        uint8* target = (opcode == BRANCH_IF_FALSE) ? (bcp + offset) : (bcp - offset);
        output_ << "    Object* value = POP();" << std::endl;
        output_ << "    if (!IS_TRUE_VALUE(value)) " << branch(begin, end, program, target) << ";" << std::endl;
        break;
      }

      case PRIMITIVE: {
        B_ARG1(module);
        unsigned index = Utils::read_unaligned_uint16(bcp + 2);
        int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
        output_ << "    PrimitiveEntry* primitive = const_cast<PrimitiveEntry*>(Primitive::at(" << module << ", " << index << "));  // ";
        output_ << PrimitiveResolver::module_name(module) << "." << PrimitiveResolver::primitive_name(module, index) << std::endl;
        output_ << "    TAILCALL return invoke_primitive(RUN_ARGS_XX(&bb_" << next << ", primitive));" << std::endl;
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
        output_ << "    run_func continuation = reinterpret_cast<run_func>(STACK_AT(" << (offset + 1) << "));" << std::endl;
        output_ << "    DROP(" << (arity + offset + 1) << ");" << std::endl;
        output_ << "    STACK_AT_PUT(0, result);" << std::endl;
        output_ << "    TAILCALL return continuation(RUN_ARGS);" << std::endl;
        break;
      }

      case RETURN_NULL: {
        B_ARG1(offset);
        B_ARG2(arity);
        output_ << "    run_func continuation = reinterpret_cast<run_func>(STACK_AT(" << (offset + 1) << "));" << std::endl;
        output_ << "    DROP(" << (arity + offset + 1) << ");" << std::endl;
        output_ << "    STACK_AT_PUT(0, null_object);" << std::endl;
        output_ << "    TAILCALL return continuation(RUN_ARGS);" << std::endl;
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
        output_ << "    run_func continuation = reinterpret_cast<run_func>(STACK_AT(0));" << std::endl;
        output_ << "    STACK_AT_PUT(" << arity << ", result);" << std::endl;
        if (arity > 0) {
          output_ << "    DROP(" << arity << ");" << std::endl;
        }
        output_ << "    TAILCALL return continuation(RUN_ARGS);" << std::endl;
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

  if (end != mend) {
    int next = program->absolute_bci_from_bcp(end);
    output_ << "  TAILCALL return bb_" << next << "(RUN_ARGS);" << std::endl;
  } else {
    output_ << "  __builtin_unreachable();" << std::endl;
  }
  output_ << "}" << std::endl;
}

void CcGenerator::emit_invoke_virtual(uint8* bcp, int arity, int offset) {
  Program* program = types_->program();
  std::vector<TypeSet> arguments = types_->input(program->absolute_bci_from_bcp(bcp));
  bool needs_smi_check = true;
  if (arguments.size() == arity) {
    needs_smi_check = arguments[0].contains_smi(program);
  }
  output_ << "    Object* receiver = STACK_AT(" << (arity - 1) << ");" << std::endl;
  if (needs_smi_check) {
    output_ << "    unsigned id = is_smi(receiver) ? " << program->smi_class_id()->value() << " : HeapObject::cast(receiver)->class_id()->value();" << std::endl;
  } else {
    output_ << "    unsigned id = HeapObject::cast(receiver)->class_id()->value();" << std::endl;
  }
  int next = program->absolute_bci_from_bcp(bcp + opcode_length[*bcp]);
  output_ << "    TAILCALL return vtbl[id + " << offset << "](RUN_ARGS_XX(&bb_" << next << ", " << offset << "));" << std::endl;
}

void CcGenerator::emit_invoke_operation(uint8* bcp, Opcode opcode, const char* mnemonic) {
  Program* program = types_->program();
  std::vector<TypeSet> arguments = types_->input(program->absolute_bci_from_bcp(bcp));

  bool is_compare;
  switch (opcode) {
    case INVOKE_LT:
    case INVOKE_LTE:
    case INVOKE_GT:
    case INVOKE_GTE:
      is_compare = true;
      break;

    case INVOKE_ADD:
    case INVOKE_SUB:
      is_compare = false;
      break;

    default:
      UNREACHABLE();
  }

  OperandKind left = UNKNOWN_NOT_SMI;
  OperandKind right = UNKNOWN_NOT_SMI;
  if (arguments.size() == 2) {
    left = operand_kind(program, arguments[0]);
    right = operand_kind(program, arguments[1]);
  }

  if (!is_int(left) || !is_int(right)) {
    int offset = program->invoke_bytecode_offset(opcode);
    if (is_maybe_smi(left) && is_maybe_smi(right)) {
      if (right == INT_DEFINITELY_SMI) {
        output_ << "    Smi* right = Smi::cast(STACK_AT(0));" << std::endl;
      } else {
        output_ << "    Object* right = STACK_AT(0);" << std::endl;
      }

      if (left == INT_DEFINITELY_SMI) {
        output_ << "    Smi* left = Smi::cast(STACK_AT(1));" << std::endl;
      } else {
        output_ << "    Object* left = STACK_AT(1);" << std::endl;
      }
      int next = program->absolute_bci_from_bcp(bcp + opcode_length[opcode]);
      if (is_compare) {
        output_ << "    bool result;" << std::endl;
      } else {
        output_ << "    Object* result;" << std::endl;
      }
      output_ << "    if (!aot_" << mnemonic << "(left, right, &result)) {" << std::endl;
      output_ << "      TAILCALL return aot_" << mnemonic << "(RUN_ARGS_XX(&bb_" << next << ", " << offset << "));" << std::endl;
      output_ << "    }" << std::endl;
      if (is_compare) {
        output_ << "    STACK_AT_PUT(1, BOOL(result));" << std::endl;
      } else {
        output_ << "    STACK_AT_PUT(1, result);" << std::endl;
      }
      output_ << "    DROP1();" << std::endl;
    } else {
      emit_invoke_virtual(bcp, 2, offset);
    }
    return;
  }

  if (is_compare || (is_likely_smi(left) && is_maybe_smi(right))) {
    if (right == INT_DEFINITELY_SMI) {
      output_ << "    Smi* right = Smi::cast(STACK_AT(0));" << std::endl;
    } else {
      output_ << "    Object* right = STACK_AT(0);" << std::endl;
    }

    if (left == INT_DEFINITELY_SMI) {
      output_ << "    Smi* left = Smi::cast(STACK_AT(1));" << std::endl;
    } else {
      output_ << "    Object* left = STACK_AT(1);" << std::endl;
    }
  }

  if (is_compare) {
    if (is_likely_smi(left) && is_maybe_smi(right)) {
      output_ << "    bool result;" << std::endl;
      output_ << "    if (UNLIKELY(!aot_" << mnemonic << "(left, right, &result))) {" << std::endl;
      output_ << "      result = aot_" << mnemonic << "(left, right);" << std::endl;
      output_ << "    }" << std::endl;
      output_ << "    STACK_AT_PUT(1, BOOL(result));" << std::endl;
      output_ << "    DROP1();" << std::endl;
    } else {
      output_ << "    STACK_AT_PUT(1, BOOL(aot_" << mnemonic << "(left, right)));" << std::endl;
      output_ << "    DROP1();" << std::endl;
    }
  } else {
    if (is_likely_smi(left) && is_maybe_smi(right)) {
      output_ << "    Object* result;" << std::endl;
      output_ << "    if (LIKELY(aot_" << mnemonic << "(left, right, &result))) {" << std::endl;
      output_ << "      STACK_AT_PUT(1, result);" << std::endl;
      output_ << "      DROP1();" << std::endl;
      output_ << "    } else {" << std::endl;
      output_ << "      sp = aot_" << mnemonic << "(sp, wonk);" << std::endl;
      output_ << "    }" << std::endl;
    } else {
      output_ << "    sp = aot_" << mnemonic << "(sp, wonk);" << std::endl;
    }
  }
}

std::vector<uint8*> CcGenerator::split_method(Method method, uint8* end) {
  std::set<uint8*> points;
  while (true) {
    size_t count = points.size();
    uint8* begin = method.entry();
    std::vector<uint8*> copy(points.begin(), points.end());
    for (auto it : copy) {
      split_range(begin, it, points);
      begin = it;
    }
    split_range(begin, end, points);
    if (count == points.size()) break;
  }
  points.insert(method.entry());
  return std::vector<uint8*>(points.begin(), points.end());
}

void CcGenerator::split_range(uint8* begin, uint8* end, std::set<uint8*>& points) {
  Program* program = types_->program();
  uint8* bcp = begin;
  while (bcp < end) {
    Opcode opcode = static_cast<Opcode>(*bcp);
    switch (opcode) {
      case STORE_FIELD:
      case STORE_FIELD_WIDE:
      case STORE_FIELD_POP:
      case LOAD_GLOBAL_VAR_LAZY:
      case LOAD_GLOBAL_VAR_LAZY_WIDE:
      case LOAD_GLOBAL_VAR_DYNAMIC:
      case STORE_GLOBAL_VAR_DYNAMIC:
      case ALLOCATE:
      case ALLOCATE_WIDE:
      case INVOKE_STATIC:
      case INVOKE_BLOCK:
      case INVOKE_VIRTUAL:
      case INVOKE_VIRTUAL_WIDE:
      case INVOKE_VIRTUAL_GET:
      case INVOKE_VIRTUAL_SET:
      case INVOKE_EQ:
      case INVOKE_BIT_OR:
      case INVOKE_BIT_XOR:
      case INVOKE_BIT_AND:
      case INVOKE_BIT_SHL:
      case INVOKE_BIT_SHR:
      case INVOKE_BIT_USHR:
      case INVOKE_MUL:
      case INVOKE_DIV:
      case INVOKE_MOD:
      case INVOKE_AT_PUT:
      case PRIMITIVE: {
        uint8* next = bcp + opcode_length[opcode];
        if (next < end) points.insert(next);
        break;
      }

      case INVOKE_LT:
      case INVOKE_GT:
      case INVOKE_LTE:
      case INVOKE_GTE:
      case INVOKE_ADD:
      case INVOKE_SUB: {
        uint8* next = bcp + opcode_length[opcode];
        if (next < end) {
          int position = program->absolute_bci_from_bcp(bcp);
          std::vector<TypeSet> arguments = types_->input(position);
          if (arguments.size() == 2) {
            OperandKind left = operand_kind(program, arguments[0]);
            OperandKind right = operand_kind(program, arguments[1]);
            if (!is_int(left) || !is_int(right)) points.insert(next);
          } else {
            points.insert(next);
          }
        }
        break;
      }

      case INVOKE_AT: {
        uint8* next = bcp + opcode_length[opcode];
        if (next < end) {
          int position = program->absolute_bci_from_bcp(bcp);
          std::vector<TypeSet> arguments = types_->input(position);
          if (arguments.size() == 2) {
            if (arguments[0].size(TypeSet::words_per_type(program)) != 1 ||
                !arguments[0].contains_instance(program->byte_array_class_id())) {
              points.insert(next);
            }
          } else {
            points.insert(next);
          }
        }
        break;
      }

      case BRANCH:
      case BRANCH_IF_TRUE:
      case BRANCH_IF_FALSE: {
        uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
        if (target > end) points.insert(target);
        break;
      }

      case BRANCH_BACK:
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE: {
        uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
        if (target < begin) points.insert(target);
        break;
      }

      default: {
        break;
      }
    }
    bcp += opcode_length[opcode];
  }
}

void compile_to_cc(TypeDatabase* types, SourceMapper* source_mapper) {
  CcGenerator generator(types);
  generator.emit(source_mapper->methods());
  printf("%s", generator.output().c_str());
}

}  // namespace toit::compiler
}  // namespace toit
