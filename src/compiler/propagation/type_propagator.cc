// Copyright (C) 2022 Toitware ApS.
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

#include "type_propagator.h"
#include "../../top.h"

#include "../../bytecodes.h"
#include "../../objects.h"
#include "../../program.h"
#include "../../interpreter.h"
#include "../../printing.h"

namespace toit {
namespace compiler {

// Dispatching helper macros.
#define DISPATCH(n)                                                                \
    { ASSERT(program->bytecodes.data() <= bcp + n);                                \
      ASSERT(bcp + n < program->bytecodes.data() + program->bytecodes.length());   \
      Opcode next = static_cast<Opcode>(bcp[n]);                                   \
      bcp += n;                                                                    \
      printf("[%p | ", bcp);                                                       \
      print_bytecode_console(bcp);                                                 \
      printf("]\n");                                                               \
      goto *dispatch_table[next];                                                  \
    }

#define DISPATCH_TO(opcode)                                 \
    goto interpret_##opcode

// Opcode definition macros.
#define OPCODE_BEGIN(opcode)                                \
  interpret_##opcode: {                                     \
    static const int _length_ = opcode##_LENGTH

#define OPCODE_END()                                        \
    DISPATCH(_length_);                                     \
  }

// Definition of byte code with wide variant.
#define OPCODE_BEGIN_WITH_WIDE(opcode, arg) {               \
  uword arg;                                                \
  int _length_;                                             \
  interpret_##opcode##_WIDE:                                \
    _length_ = opcode##_WIDE_LENGTH;                        \
    arg = Utils::read_unaligned_uint16(bcp + 1);            \
    goto interpret_##opcode##_impl;                         \
  interpret_##opcode:                                       \
    _length_ = opcode##_LENGTH;                             \
    arg = bcp[1];                                           \
  interpret_##opcode##_impl:

#define B_ARG1(name) uint8 name = bcp[1];
#define S_ARG1(name) uint16 name = Utils::read_unaligned_uint16(bcp + 1);

void TypeSet::print(Program* program, const char* banner) {
  printf("TypeSet(%s) = {", banner);
  bool first = true;
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (!contains(id)) continue;
    if (first) printf(" ");
    else printf(", ");
    printf("%d", id);
    first = false;
  }
  printf(" }\n");
}

bool TypeSet::contains_null(Program* program) const {
  return contains(program->null_class_id()->value());
}

void TypeSet::remove_null(Program* program) {
  remove(program->null_class_id()->value());
}

void TypeSet::remove_range(unsigned start, unsigned end) {
  // TODO(kasper): We can make this much faster.
  for (unsigned type = start; type < end; type++) {
    remove(type);
  }
}

bool TypeSet::remove_typecheck_class(Program* program, int index, bool is_nullable) {
  unsigned start = program->class_check_ids[2 * index];
  unsigned end = program->class_check_ids[2 * index + 1];
  bool contains_null_before = contains_null(program);
  remove_range(0, start);
  remove_range(end, program->class_bits.length());
  if (contains_null_before && is_nullable) {
    add(program->null_class_id()->value());
    return true;
  }
  // TODO(kasper): Return false if the type is empty after this.
  return true;
}

bool TypeSet::remove_typecheck_interface(Program* program, int index, bool is_nullable) {
  bool contains_null_before = contains_null(program);
  // TODO(kasper): We can make this faster.
  int selector_offset = program->interface_check_offsets[index];
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (!contains(id)) continue;
    int entry_index = id + selector_offset;
    int entry_id = program->dispatch_table[entry_index];
    if (entry_id != -1) {
      Method target(program->bytecodes, entry_id);
      if (target.selector_offset() == selector_offset) continue;
    }
    remove(id);
  }
  if (contains_null_before && is_nullable) {
    add(program->null_class_id()->value());
    return true;
  }
  // TODO(kasper): Return false if the type is empty after this.
  return true;
}

TypePropagator::TypePropagator(Program* program)
    : program_(program) {
}

int TypePropagator::words_per_type() const {
  int classes = program_->class_bits.length();
  int words_per_type = (classes + WORD_BIT_SIZE - 1) / WORD_BIT_SIZE;
  return words_per_type;
}

void TypePropagator::propagate() {
  MethodTemplate* entry = instantiate(program_->entry_main(), std::vector<int>());
  enqueue(entry);

  while (enqueued_.size() != 0) {
    MethodTemplate* last = enqueued_[enqueued_.size() - 1];
    enqueued_.pop_back();
    last->propagate();
    last->clear_enqueued();
  }

  TypeStack* stack = new TypeStack(-1, 1, words_per_type());
  TypeSet type = stack->get(0);
  for (auto it = templates_.begin(); it != templates_.end(); it++) {
    type.clear(words_per_type());
    std::vector<MethodTemplate*>& templates = it->second;
    for (unsigned i = 0; i < templates.size(); i++) {
      MethodTemplate* method = templates[i];
      type.add_all(method->type(), words_per_type());
    }
    printf("call at %p: ", it->first);
    type.print(program(), "propagated");
  }
}

void TypePropagator::call_method(MethodTemplate* caller, TypeStack* stack, uint8* callsite, Method target, std::vector<int>& arguments) {
  int arity = target.arity();
  int index = arguments.size();
  if (index == arity) {
    printf("[%p - invoke method:", callsite);
    for (unsigned i = 0; i < arguments.size(); i++) {
      printf(" %d", arguments[i]);
    }
    printf("]\n");
    MethodTemplate* callee = find(callsite, target, arguments);
    TypeSet result = callee->call(caller);
    stack->merge_top(result);
    return;
  }

  TypeSet type = stack->local(arity - index);
  Program* program = this->program();
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (!type.contains(id)) continue;
    arguments.push_back(id);
    call_method(caller, stack, callsite, target, arguments);
    arguments.pop_back();
  }
}

void TypePropagator::call_static(MethodTemplate* caller, TypeStack* stack, uint8* callsite, Method target) {
  std::vector<int> arguments;
  stack->push_empty();
  call_method(caller, stack, callsite, target, arguments);
  stack->drop_arguments(target.arity());
}

void TypePropagator::call_virtual(MethodTemplate* caller, TypeStack* stack, uint8* callsite, int arity, int offset) {
  TypeSet receiver = stack->local(arity - 1);

  std::vector<int> arguments;
  stack->push_empty();

  Program* program = this->program();
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (!receiver.contains(id)) continue;
    int entry_index = id + offset;
    int entry_id = program->dispatch_table[entry_index];
    if (entry_id == -1) continue;
    Method target(program->bytecodes, entry_id);
    if (target.selector_offset() != offset) continue;
    arguments.push_back(id);
    call_method(caller, stack, callsite, target, arguments);
    arguments.pop_back();
  }

  stack->drop_arguments(arity);
}

TypeResult* TypePropagator::global_variable(int index) {
  auto it = globals_.find(index);
  if (it == globals_.end()) {
    TypeResult* variable = new TypeResult(words_per_type());
    globals_[index] = variable;
    return variable;
  } else {
    return it->second;
  }
}

void TypePropagator::enqueue(MethodTemplate* method) {
  if (!method || method->enqueued()) return;
  method->mark_enqueued();
  enqueued_.push_back(method);
}

MethodTemplate* TypePropagator::find(uint8* caller, Method target, std::vector<int> arguments) {
  auto it = templates_.find(caller);
  if (it == templates_.end()) {
    std::vector<MethodTemplate*> templates;
    MethodTemplate* result = instantiate(target, arguments);
    templates.push_back(result);
    templates_[caller] = templates;
    result->propagate();
    return result;
  } else {
    std::vector<MethodTemplate*>& templates = it->second;
    for (unsigned i = 0; i < templates.size(); i++) {
      MethodTemplate* candidate = templates[i];
      if (candidate->matches(target, arguments)) {
        return candidate;
      }
    }
    MethodTemplate* result = instantiate(target, arguments);
    templates.push_back(result);
    result->propagate();
    return result;
  }
}

MethodTemplate* TypePropagator::instantiate(Method method, std::vector<int> arguments) {
  MethodTemplate* result = new MethodTemplate(this, method, arguments);
  return result;
}

bool TypeResult::merge(TypePropagator* propagator, TypeSet other) {
  if (!type_.add_all(other, words_per_type_)) return false;
  for (unsigned i = 0; i < users_.size(); i++) {
    propagator->enqueue(users_[i]);
  }
  return true;
}

bool TypeStack::merge(TypeStack* other) {
  bool result = false;
  for (unsigned i = 0; i < sp_; i++) {
    TypeSet existing_type = get(i);
    TypeSet other_type = other->get(i);
    result = existing_type.add_all(other_type, words_per_type_) || result;
  }
  return result;
}

TypeSet TypeStack::push_empty() {
  TypeSet result = get(++sp_);
  result.clear(words_per_type_);
  return result;
}

void TypeStack::push_any() {
  TypeSet result = get(++sp_);
  result.fill(words_per_type_);
}

void TypeStack::push_null(Program* program) {
  TypeSet type = push_empty();
  type.add(program->null_class_id()->value());
}

void TypeStack::push_smi(Program* program) {
  TypeSet type = push_empty();
  type.add(program->smi_class_id()->value());
}

void TypeStack::push_bool(Program* program) {
  TypeSet type = push_empty();
  type.add(program->true_class_id()->value());
  type.add(program->false_class_id()->value());
}

void TypeStack::push_instance(unsigned id) {
  TypeSet type = push_empty();
  type.add(id);
}

void TypeStack::push(Program* program, Object* object) {
  TypeSet type = push_empty();
  if (is_heap_object(object)) {
    type.add(HeapObject::cast(object)->class_id()->value());
  } else {
    type.add(program->smi_class_id()->value());
  }
}

void TypeStack::seed_arguments(std::vector<int> arguments) {
  for (unsigned i = 0; i < arguments.size(); i++) {
    TypeSet type = get(i);
    type.add(arguments[i]);
  }
}

// TODO(kasper): Poor name.
struct WorkItem {
  uint8* bcp;
  TypeStack* stack;
};

class Worklist {
 public:
  Worklist(uint8* entry, TypeStack* stack) {
    stacks_[entry] = stack;
    unprocessed_.push_back(entry);
  }

  void add(uint8* bcp, TypeStack* stack) {
    auto it = stacks_.find(bcp);
    if (it == stacks_.end()) {
      stacks_[bcp] = stack->copy();
      unprocessed_.push_back(bcp);
    } else {
      TypeStack* existing = it->second;
      if (existing->merge(stack)) {
        unprocessed_.push_back(bcp);
      }
    }
  }

  bool has_next() const {
    return !unprocessed_.empty();
  }

  WorkItem next() {
    uint8* bcp = unprocessed_[unprocessed_.size() - 1];
    unprocessed_.pop_back();
    return WorkItem {
      .bcp = bcp,
      .stack = stacks_[bcp]->copy()
    };
  }

  ~Worklist() {
    for (auto it = stacks_.begin(); it != stacks_.end(); it++) {
      delete it->second;
    }
  }

 private:
  std::vector<uint8*> unprocessed_;
  std::unordered_map<uint8*, TypeStack*> stacks_;
};

static void process(MethodTemplate* method, WorkItem item, Worklist& worklist) {
#define LABEL(opcode, length, format, print) &&interpret_##opcode,
  static void* dispatch_table[] = {
    BYTECODES(LABEL)
  };
#undef LABEL

  TypePropagator* propagator = method->propagator();
  Program* program = propagator->program();
  uint8* bcp = item.bcp;
  TypeStack* stack = item.stack;

  DISPATCH(0);

  OPCODE_BEGIN_WITH_WIDE(LOAD_LOCAL, stack_offset);
    stack->push(stack->local(stack_offset));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_0);
    stack->push(stack->local(0));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_1);
    stack->push(stack->local(1));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_2);
    stack->push(stack->local(2));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_3);
    stack->push(stack->local(3));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_4);
    stack->push(stack->local(4));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_LOCAL_5);
    stack->push(stack->local(5));
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_LOCAL);
    B_ARG1(stack_offset);
    TypeSet local = stack->local(stack_offset + 1);
    stack->set_local(0, local);
  OPCODE_END();

  OPCODE_BEGIN(STORE_LOCAL);
    B_ARG1(stack_offset);
    TypeSet top = stack->local(stack_offset);
    stack->set_local(stack_offset, top);
  OPCODE_END();

  OPCODE_BEGIN(STORE_LOCAL_POP);
    B_ARG1(stack_offset);
    stack->set_local(stack_offset, stack->local(0));
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(STORE_OUTER);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_FIELD, index);
    TypeSet instance = stack->local(0);
    stack->pop();
    stack->push_any();  // TODO(kasper): Not great.
  OPCODE_END();

  OPCODE_BEGIN(LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field = encoded >> 4;
    TypeSet instance = stack->local(local);
    stack->push_any();  // TODO(kasper): Not great.
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field = encoded >> 4;
    TypeSet instance = stack->local(local + 1);
    stack->pop();
    stack->push_any();  // TODO(kasper): Not great.
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_FIELD, index);
    TypeSet value = stack->local(0);
    TypeSet receiver = stack->local(1);
    // TODO(kasper): Update field.
    stack->pop();
    stack->pop();
    stack->push(value);
  OPCODE_END();

  OPCODE_BEGIN(STORE_FIELD_POP);
    TypeSet value = stack->local(0);
    TypeSet receiver = stack->local(1);
    // TODO(kasper): Update field.
    stack->pop();
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_LITERAL, literal_index);
    Object* literal = program->literals.at(literal_index);
    stack->push(program, literal);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_NULL);
    stack->push_null(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_0);
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMIS_0);
    B_ARG1(number_of_zeros);
    for (int i = 0; i < number_of_zeros; i++) stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_1);
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U8);
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U16);
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_SMI_U32);
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, index);
    TypeResult* variable = propagator->global_variable(index);
    stack->push(variable->use(method));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_GLOBAL_VAR_DYNAMIC);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR_LAZY, index);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_GLOBAL_VAR, index);
    TypeResult* variable = propagator->global_variable(index);
    TypeSet top = stack->local(0);
    variable->merge(propagator, top);
  OPCODE_END();

  OPCODE_BEGIN(STORE_GLOBAL_VAR_DYNAMIC);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(LOAD_BLOCK);
    stack->push_null(program);  // TODO(kasper): This is quite wrong.
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER_BLOCK);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(POP);
    B_ARG1(index);
    for (int i = 0; i < index; i++) stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(POP_1);
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(ALLOCATE, class_index);
    stack->push_instance(class_index);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_CLASS, encoded);
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_INTERFACE, encoded);
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_CLASS, encoded);
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    if (!top.remove_typecheck_class(program, class_index, is_nullable)) return;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    if (!top.remove_typecheck_interface(program, interface_selector_index, is_nullable)) return;
  OPCODE_END();

  OPCODE_BEGIN(AS_LOCAL);
    B_ARG1(encoded);
    int stack_offset = encoded >> 5;
    bool is_nullable = false;
    int class_index = encoded & 0x1F;
    TypeSet local = stack->local(stack_offset);
    if (!local.remove_typecheck_class(program, class_index, is_nullable)) return;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC);
    S_ARG1(offset);
    Method target(program->bytecodes, program->dispatch_table[offset]);
    propagator->call_static(method, stack, bcp, target);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC_TAIL);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_BLOCK);
    B_ARG1(index);
    for (int i = 0; i < index; i++) stack->pop();
    stack->push_any();  // TODO(kasper): Not great.
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_INITIALIZER_TAIL);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(INVOKE_VIRTUAL, arity);
    int offset = Utils::read_unaligned_uint16(bcp + 2);
    propagator->call_virtual(method, stack, bcp, arity + 1, offset);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_GET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, stack, bcp, 1, offset);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_SET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, stack, bcp, 2, offset);
  OPCODE_END();

#define INVOKE_VIRTUAL_BINARY(opcode)                         \
  OPCODE_BEGIN(opcode);                                       \
    int offset = program->invoke_bytecode_offset(opcode);     \
    propagator->call_virtual(method, stack, bcp, 2, offset);  \
  OPCODE_END();

  INVOKE_VIRTUAL_BINARY(INVOKE_EQ)
  INVOKE_VIRTUAL_BINARY(INVOKE_LT)
  INVOKE_VIRTUAL_BINARY(INVOKE_LTE)
  INVOKE_VIRTUAL_BINARY(INVOKE_GT)
  INVOKE_VIRTUAL_BINARY(INVOKE_GTE)

  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_OR)
  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_XOR)
  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_AND)

  INVOKE_VIRTUAL_BINARY(INVOKE_ADD)
  INVOKE_VIRTUAL_BINARY(INVOKE_SUB)
  INVOKE_VIRTUAL_BINARY(INVOKE_MUL)
  INVOKE_VIRTUAL_BINARY(INVOKE_DIV)
  INVOKE_VIRTUAL_BINARY(INVOKE_MOD)
  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_SHL)
  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_SHR)
  INVOKE_VIRTUAL_BINARY(INVOKE_BIT_USHR)

  INVOKE_VIRTUAL_BINARY(INVOKE_AT)
#undef INVOKE_VIRTUAL_BINARY

  OPCODE_BEGIN(INVOKE_AT_PUT);
    int offset = program->invoke_bytecode_offset(INVOKE_AT_PUT);
    propagator->call_virtual(method, stack, bcp, 3, offset);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH);
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_TRUE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_FALSE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK);
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_TRUE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_FALSE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, stack);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_LAMBDA_TAIL);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(PRIMITIVE);
    stack->push_any();
    method->ret(propagator, stack);
    stack->push_any();  // This is the primitive failure.
  OPCODE_END();

  OPCODE_BEGIN(THROW);
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN);
    method->ret(propagator, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN_NULL);
    stack->push_null(program);
    method->ret(propagator, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN_WIDE);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_BRANCH);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(UNLINK);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(UNWIND);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(HALT);
    return;
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_SMI_REPEAT);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_ARRAY_DO);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_DO);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_FIND);
    UNIMPLEMENTED();
  OPCODE_END();
}

void MethodTemplate::propagate() {
  printf("[propagating types through %p]\n", method_.entry());

  int words_per_type = propagator_->words_per_type();
  int sp = method_.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method_.max_height() + 1, words_per_type);
  stack->seed_arguments(arguments_);
  Worklist worklist(method_.entry(), stack);

  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    process(this, item, worklist);
    delete item.stack;
  }
}

} // namespace toit::compiler
} // namespace toit
