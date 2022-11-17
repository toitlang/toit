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
  if (is_block()) {
    printf(" block=%p", block());
  } else {
    bool first = true;
    for (unsigned id = 0; id < program->class_bits.length(); id++) {
      if (!contains(id)) continue;
      if (first) printf(" ");
      else printf(", ");
      printf("%d", id);
      first = false;
    }
  }
  printf(" }");
}

int TypeSet::size(Program* program) const {
  if (is_block()) return 1;
  int size = 0;
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (contains(id)) size++;
  }
  return size;
}

bool TypeSet::is_empty(Program* program) const {
  if (is_block()) return false;
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (contains(id)) return false;
  }
  return true;
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
  return !is_empty(program);
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
  return !is_empty(program);
}

TypePropagator::TypePropagator(Program* program)
    : program_(program) {
}

int TypePropagator::words_per_type() const {
  int classes = program_->class_bits.length();
  int words_per_type = (classes + WORD_BIT_SIZE - 1) / WORD_BIT_SIZE;
  return Utils::max(words_per_type + 1, 2);  // Need at least two words for block types.
}

void TypePropagator::propagate() {
  MethodTemplate* entry = instantiate(program_->entry_main(), std::vector<ConcreteType>());
  enqueue(entry);

  while (enqueued_.size() != 0) {
    MethodTemplate* last = enqueued_[enqueued_.size() - 1];
    enqueued_.pop_back();
    last->clear_enqueued();
    last->propagate();
  }

  printf("[\n");

  TypeStack* stack = new TypeStack(-1, 1, words_per_type());
  TypeSet type = stack->get(0);
  bool first = true;
  for (auto it = templates_.begin(); it != templates_.end(); it++) {
    type.clear(words_per_type());
    std::vector<MethodTemplate*>& templates = it->second;
    for (unsigned i = 0; i < templates.size(); i++) {
      MethodTemplate* method = templates[i];
      type.add_all(method->type(), words_per_type());
    }
    if (first) {
      first = false;
    } else {
      printf(",\n");
    }
    int position = program()->absolute_bci_from_bcp(it->first);
    printf("{ \"position\": %d, \"type\": [", position);
    bool first_n = true;
    for (unsigned id = 0; id < program()->class_bits.length(); id++) {
      if (!type.contains(id)) continue;
      if (first_n) {
        first_n = false;
      } else {
        printf(", ");
      }
      printf("%u", id);
    }
    printf("]}");
  }

  printf("\n]\n");
}

void TypePropagator::call_method(
    MethodTemplate* caller,
    TypeStack* stack,
    uint8* callsite,
    Method target,
    std::vector<ConcreteType>& arguments) {
  int arity = target.arity();
  int index = arguments.size();
  if (index == arity) {
    if (false) {
      printf("[%p - invoke method:", callsite);
      for (unsigned i = 0; i < arguments.size(); i++) {
        if (arguments[i].is_block()) {
          printf(" %p", arguments[i].block());
        } else {
          printf(" %d", arguments[i].id());
        }
      }
      printf("]\n");
    }
    MethodTemplate* callee = find(callsite, target, arguments);
    TypeSet result = callee->call(caller);
    stack->merge_top(result);
    return;
  }

  Program* program = this->program();
  TypeSet type = stack->local(arity - index);
  if (type.is_block()) {
    arguments.push_back(ConcreteType(type.block()));
    call_method(caller, stack, callsite, target, arguments);
    arguments.pop_back();
  } else if (type.size(program) > 5) {
    arguments.push_back(ConcreteType());
    call_method(caller, stack, callsite, target, arguments);
    arguments.pop_back();
  } else {
    for (unsigned id = 0; id < program->class_bits.length(); id++) {
      if (!type.contains(id)) continue;
      arguments.push_back(ConcreteType(id));
      call_method(caller, stack, callsite, target, arguments);
      arguments.pop_back();
    }
  }
}

void TypePropagator::call_static(MethodTemplate* caller, TypeStack* stack, uint8* callsite, Method target) {
  std::vector<ConcreteType> arguments;
  stack->push_empty();
  call_method(caller, stack, callsite, target, arguments);
  stack->drop_arguments(target.arity());
}

void TypePropagator::call_virtual(MethodTemplate* caller, TypeStack* stack, uint8* callsite, int arity, int offset) {
  TypeSet receiver = stack->local(arity - 1);

  std::vector<ConcreteType> arguments;
  stack->push_empty();

  Program* program = this->program();
  for (unsigned id = 0; id < program->class_bits.length(); id++) {
    if (!receiver.contains(id)) continue;
    int entry_index = id + offset;
    int entry_id = program->dispatch_table[entry_index];
    if (entry_id == -1) continue;
    Method target(program->bytecodes, entry_id);
    if (target.selector_offset() != offset) continue;
    arguments.push_back(ConcreteType(id));
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

MethodTemplate* TypePropagator::find(uint8* caller, Method target, std::vector<ConcreteType> arguments) {
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

MethodTemplate* TypePropagator::instantiate(Method method, std::vector<ConcreteType> arguments) {
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
  ASSERT(sp() == other->sp());
  bool result = false;
  for (unsigned i = 0; i < sp_; i++) {
    TypeSet existing_type = get(i);
    TypeSet other_type = other->get(i);
    if (existing_type.is_block()) {
      ASSERT(existing_type.block() == other_type.block());
    } else {
      result = existing_type.add_all(other_type, words_per_type_) || result;
    }
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

void TypeStack::push_int(Program* program) {
  TypeSet type = push_empty();
  type.add(program->smi_class_id()->value());
  type.add(program->large_integer_class_id()->value());
}

void TypeStack::push_float(Program* program) {
  TypeSet type = push_empty();
  type.add(program->double_class_id()->value());
}

void TypeStack::push_string(Program* program) {
  TypeSet type = push_empty();
  type.add(program->string_class_id()->value());
}

void TypeStack::push_array(Program* program) {
  TypeSet type = push_empty();
  type.add(program->array_class_id()->value());
}

void TypeStack::push_byte_array(Program* program) {
  TypeSet type = push_empty();
  type.add(program->byte_array_class_id()->value());
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

void TypeStack::push_block(BlockTemplate* block) {
  TypeSet type = push_empty();
  type.set_block(block);
}

void TypeStack::seed_arguments(std::vector<ConcreteType> arguments) {
  for (unsigned i = 0; i < arguments.size(); i++) {
    TypeSet type = get(i);
    ConcreteType argument_type = arguments[i];
    if (argument_type.is_block()) {
      type.set_block(argument_type.block());
    } else if (argument_type.is_any()) {
      type.fill(words_per_type_);
    } else {
      type.add(argument_type.id());
    }
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

static void process(MethodTemplate* method, uint8* bcp, TypeStack* stack, Worklist& worklist) {
#define LABEL(opcode, length, format, print) &&interpret_##opcode,
  static void* dispatch_table[] = {
    BYTECODES(LABEL)
  };
#undef LABEL

  TypePropagator* propagator = method->propagator();
  Program* program = propagator->program();
  DISPATCH(0);

  OPCODE_BEGIN_WITH_WIDE(LOAD_LOCAL, stack_offset);
    TypeSet local = stack->local(stack_offset);
    stack->push(local);
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
    TypeSet top = stack->local(0);
    stack->set_local(stack_offset, top);
  OPCODE_END();

  OPCODE_BEGIN(STORE_LOCAL_POP);
    B_ARG1(stack_offset);
    stack->set_local(stack_offset, stack->local(0));
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER);
    B_ARG1(stack_offset);
    TypeSet block = stack->local(0);
    TypeStack* outer = stack->outer();
    int n = outer->level() - block.block()->level();
    for (int i = 0; i < n; i++) outer = outer->outer();
    TypeSet value = outer->local(stack_offset);
    stack->pop();
    stack->push(value);
  OPCODE_END();

  OPCODE_BEGIN(STORE_OUTER);
    B_ARG1(stack_offset);
    TypeSet value = stack->local(0);
    TypeSet block = stack->local(1);
    TypeStack* outer = stack->outer();
    int n = outer->level() - block.block()->level();
    for (int i = 0; i < n; i++) outer = outer->outer();
    outer->set_local(stack_offset, value);
    stack->pop();
    stack->pop();
    stack->push(value);
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

  OPCODE_BEGIN(LOAD_BLOCK_METHOD);
    Method inner = Method(program->bytecodes, Utils::read_unaligned_uint32(bcp + 1));
    BlockTemplate* block = method->find_block(inner, stack->level(), bcp);
    stack->push_block(block);
    block->propagate(method, stack);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, index);
    TypeResult* variable = propagator->global_variable(index);
    stack->push(variable->use(method));
  OPCODE_END();

  OPCODE_BEGIN(LOAD_GLOBAL_VAR_DYNAMIC);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR_LAZY, index);
    stack->push_any();  // TODO(kasper): Not so great.
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
    B_ARG1(index);
    TypeSet block = stack->local(index);
    ASSERT(block.is_block());
    stack->push(block);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER_BLOCK);
    B_ARG1(stack_offset);
    TypeSet block = stack->local(0);
    TypeStack* outer = stack->outer();
    int n = outer->level() - block.block()->level();
    for (int i = 0; i < n; i++) outer = outer->outer();
    TypeSet value = outer->local(stack_offset);
    ASSERT(value.is_block());
    stack->pop();
    stack->push(value);
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
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC_TAIL);
    S_ARG1(offset);
    Method target(program->bytecodes, program->dispatch_table[offset]);
    propagator->call_static(method, stack, bcp, target);
    if (stack->local(0).is_empty(program)) return;
    if (stack->outer()) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
    } else {
      method->ret(propagator, stack);
    }
    return;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_BLOCK);
    B_ARG1(index);
    TypeSet receiver = stack->local(index - 1);
    BlockTemplate* block = receiver.block();
    for (int i = 1; i < block->arity(); i++) {
      TypeSet argument = stack->local(index - (i + 1));
      block->argument(i)->merge(propagator, argument);
    }
    for (int i = 0; i < index; i++) stack->pop();
    TypeSet value = block->use(method);
    stack->push(value);
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
    B_ARG1(primitive_module);
    unsigned primitive_index = Utils::read_unaligned_uint16(bcp + 2);
    bool known = false;
    if (primitive_module == 0) {
      switch (primitive_index) {
        case 0:   // core.write_string_on_stdout
        case 24:  // core.string_add
        case 28:  // core.smi_to_string_base_10
          stack->push_string(program);
          known = true;
          break;

        case 15:  // core.array_new
          stack->push_array(program);
          known = true;
          break;

        case 31:   // core.blob_equals
        case 34:   // core.object_equals  <--- CANNOT FAIL
        case 81:   // core.smi_equals
        case 82:   // core.float_equals
        case 145:  // core.large_integer_equals
          stack->push_bool(program);
          known = true;
          break;

/*
          stack->push_smi(program);
          known = true;
          break;
*/

        case 53:   // core.smi_divide
        case 70:   // core.smi_mod
        case 92:   // core.number_to_integer
        case 143:  // core.large_integer_divide
        case 144:  // core.large_integer_mod
          stack->push_int(program);
          known = true;
          break;

        case 41:  // core.number_to_float
        case 58:  // core.float_divide
        case 59:  // core.float_mod
          stack->push_float(program);
          known = true;
          break;

        case 156: // core.encode_error
          stack->push_byte_array(program);
          known = true;
          break;

        default:
          // Do nothing.
          break;
      }
    }
    if (!known) {
      if (false) printf("[primitive %d:%u => any]\n", primitive_module, primitive_index);
      stack->push_any();
    }
    method->ret(propagator, stack);
    stack->push_string(program);  // Primitive failures are typically strings.
  OPCODE_END();

  OPCODE_BEGIN(THROW);
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN);
    if (stack->outer()) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
    } else {
      method->ret(propagator, stack);
    }
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN_NULL);
    stack->push_null(program);
    if (stack->outer()) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
    } else {
      method->ret(propagator, stack);
    }
    return;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN);
    stack->pop();  // Pop block.
    method->ret(propagator, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN_WIDE);
    stack->pop();  // Pop block.
    method->ret(propagator, stack);
    return;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_BRANCH);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    stack->push_smi(program);
    stack->push_any();  // TODO(kasper): is_exception
    stack->push_any();  // TODO(kasper): Exception
    stack->push_smi(program);
  OPCODE_END();

  OPCODE_BEGIN(UNLINK);
    stack->pop();

  OPCODE_END();

  OPCODE_BEGIN(UNWIND);
    return;
  OPCODE_END();

  OPCODE_BEGIN(HALT);
    return;
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_SMI_REPEAT);
    // Fall-through to generic case.
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_ARRAY_DO);
    // Fall-through to generic case.
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_DO);
    // Fall-through to generic case.
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(INTRINSIC_HASH_FIND);
    // Fall-through to generic case.
    for (int i = 0; i < 7; i++) stack->pop();
  OPCODE_END();
}

BlockTemplate* MethodTemplate::find_block(Method method, int level, uint8* bcp) {
  auto it = blocks_.find(bcp);
  if (it == blocks_.end()) {
    BlockTemplate* block = new BlockTemplate(method, level, propagator_->words_per_type());
    for (int i = 1; i < method.arity(); i++) {
      block->argument(i)->use(this);
    }
    blocks_[bcp] = block;
    return block;
  } else {
    return it->second;
  }
}

static int MTL = 0;

void MethodTemplate::propagate() {
  if (false) printf("[propagating types through %p (%d)]\n", method_.entry(), MTL);
  MTL++;

  int words_per_type = propagator_->words_per_type();
  int sp = method_.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method_.max_height() + 1, words_per_type);
  stack->seed_arguments(arguments_);

  Worklist worklist(method_.entry(), stack);
  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    if (false) printf("  --- %p\n", item.bcp);
    process(this, item.bcp, item.stack, worklist);
    delete item.stack;
  }

  MTL--;
}

void BlockTemplate::propagate(MethodTemplate* context, TypeStack* outer) {
  if (false) printf("[propagating types through block %p]\n", method_.entry());

  int words_per_type = context->propagator()->words_per_type();
  int sp = method_.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method_.max_height() + 1, words_per_type);
  for (unsigned i = 1; i < method_.arity(); i++) {
    TypeSet type = argument(i)->type();
    stack->set(i, type);
  }

  stack->push_block(this);
  TypeSet receiver = stack->local(0);
  stack->set(0, receiver);
  stack->pop();

  TypeStack* outer_copy = outer->copy();
  stack->set_outer(outer_copy);

  Worklist worklist(method_.entry(), stack);
  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    if (false) printf("  --- %p\n", item.bcp);
    process(context, item.bcp, item.stack, worklist);
    delete item.stack;
  }

  outer->merge(outer_copy);
  delete outer_copy;
}

} // namespace toit::compiler
} // namespace toit
