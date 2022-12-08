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
#include "type_database.h"
#include "type_primitive.h"
#include "type_scope.h"

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

static const int INITIALIZER_ID_INDEX = 0;

TypePropagator::TypePropagator(Program* program)
    : program_(program)
    , words_per_type_(TypeSet::words_per_type(program)) {
  TypePrimitive::set_up();
}

void TypePropagator::ensure_entry_main() {
  if (has_entry_main_) return;
  TypeScope scope(1, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_instance(program()->task_class_id()->value());
  Method target = program()->entry_main();
  call_static(null, &scope, null, target);
  has_entry_main_ = true;
}

void TypePropagator::ensure_entry_spawn() {
  if (has_entry_spawn_) return;
  TypeScope scope(1, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_instance(program()->task_class_id()->value());
  Method target = program()->entry_spawn();
  call_static(null, &scope, null, target);
  has_entry_spawn_ = true;
}

void TypePropagator::ensure_entry_task() {
  if (has_entry_task_) return;
  TypeScope scope(1, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_any(program());  // TODO(kasper): Should be lambda.
  Method target = program()->entry_task();
  call_static(null, &scope, null, target);
  has_entry_task_ = true;
}

void TypePropagator::ensure_lookup_failure() {
  if (has_lookup_failure_) return;
  TypeScope scope(2, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_any(program());  // receiver
  // We always pass the selector offset for implicit lookup
  // failures. The compiler sometimes generates explicit calls
  // to 'lookup_failure' and pass string selectors for those.
  stack->push_smi(program());  // selector_offset
  Method target = program()->lookup_failure();
  call_static(null, &scope, null, target);
  has_lookup_failure_ = true;
}

void TypePropagator::ensure_as_check_failure() {
  if (has_as_check_failure_) return;
  TypeScope scope(2, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_any(program());  // receiver
  // We always pass the bci for implicit as check failures.
  // The compiler sometimes generates explicit calls to
  // 'as_check_failure' and pass string class names for those.
  stack->push_smi(program());  // bci
  Method target = program()->as_check_failure();
  call_static(null, &scope, null, target);
  has_as_check_failure_ = true;
}

void TypePropagator::ensure_primitive_lookup_failure() {
  if (has_primitive_lookup_failure_) return;
  TypeScope scope(2, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_smi(program());  // module
  stack->push_smi(program());  // index
  Method target = program()->primitive_lookup_failure();
  call_static(null, &scope, null, target);
  has_primitive_lookup_failure_ = true;
}

void TypePropagator::ensure_code_failure() {
  if (has_code_failure_) return;
  TypeScope scope(4, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_bool(program());  // is_block
  stack->push_smi(program());   // expected
  stack->push_smi(program());   // provided
  stack->push_smi(program());   // bci
  Method target = program()->code_failure();
  call_static(null, &scope, null, target);
  has_code_failure_ = true;
}

void TypePropagator::ensure_program_failure() {
  if (has_program_failure_) return;
  TypeScope scope(1, words_per_type());
  TypeStack* stack = scope.top();
  stack->push_smi(program());  // bci
  Method target = program()->program_failure();
  call_static(null, &scope, null, target);
  has_program_failure_ = true;
}

void TypePropagator::ensure_run_global_initializer() {
  if (has_run_global_initializer_) return;
  TypeScope scope(2, words_per_type());
  TypeStack* stack = scope.top();
  // Seed the type of LazyInitializer_.id_or_tasks_ field.
  int initializer_class_id = program()->lazy_initializer_class_id()->value();
  TypeVariable* id_field = field(initializer_class_id, INITIALIZER_ID_INDEX);
  stack->push_smi(program());
  id_field->merge(this, stack->local(0));
  stack->pop();
  // Run the static helper method.
  stack->push_smi(program());
  stack->push_instance(initializer_class_id);
  Method target = program()->run_global_initializer();
  call_static(null, &scope, null, target);
  has_run_global_initializer_ = true;
}

void TypePropagator::propagate(TypeDatabase* types) {
  TypeStack stack(-1, 1, words_per_type());

  // Initialize the types of pre-initialized global variables.
  for (int i = 0; i < program()->global_variables.length(); i++) {
    Object* value = program()->global_variables.at(i);
    if (is_instance(value)) {
      Instance* instance = Instance::cast(value);
      if (instance->class_id() == program()->lazy_initializer_class_id()) continue;
    }
    stack.push(program(), value);
    global_variable(i)->merge(this, stack.local(0));
    stack.pop();
  }

  // Initialize the fields of Task_. We allocate instances of these in
  // the VM, so we need to make sure the type propagator knows about the
  // types we store in the fields.
  int task_fields = program()->instance_size_for(program()->task_class_id());
  for (int i = 0; i < task_fields; i++) {
    if (i == Task::STACK_INDEX) {
      continue;  // Skip the 'stack' field.
    } else if (i == Task::ID_INDEX) {
      stack.push_smi(program());
    } else {
      stack.push_null(program());
    }
    field(program()->task_class_id()->value(), i)->merge(this, stack.local(0));
    stack.pop();
  }

  // Initialize Exception_.value
  ASSERT(program()->instance_fields_for(program()->exception_class_id()) == 2);
  stack.push_any(program());
  field(program()->exception_class_id()->value(), 0)->merge(this, stack.local(0));
  stack.pop();

  // Initialize Exception_.trace
  stack.push_byte_array(program(), true);
  field(program()->task_class_id()->value(), 1)->merge(this, stack.local(0));
  stack.pop();

  ensure_entry_main();
  ensure_program_failure();  // Used in weird situations.

  while (enqueued_.size() != 0) {
    MethodTemplate* last = enqueued_.back();
    enqueued_.pop_back();
    last->clear_enqueued();
    last->propagate();
  }

  stack.push_empty();
  TypeSet type = stack.get(0);
  sites_.for_each([&](uint8* site, Set<TypeVariable*>& results) {
    type.clear(words_per_type());
    for (auto it = results.begin(); it != results.end(); it++) {
      type.add_all((*it)->type(), words_per_type());
    }
    int position = program()->absolute_bci_from_bcp(site);
    types->add_usage(position, type);
  });

  std::unordered_map<uint8*, std::vector<BlockTemplate*>> blocks;
  for (auto it = templates_.begin(); it != templates_.end(); it++) {
    std::vector<MethodTemplate*>& templates = it->second;
    for (unsigned i = 0; i < templates.size(); i++) {
      templates[i]->collect_blocks(blocks);
    }
    MethodTemplate* method = templates[0];
    types->add_method(method->method());
    int arity = method->arity();
    for (int n = 0; n < arity; n++) {
      bool is_block = false;
      type.clear(words_per_type());
      for (unsigned i = 0; i < templates.size(); i++) {
        ConcreteType argument_type = templates[i]->argument(n);
        if (argument_type.is_block()) {
          if (!is_block) type.set_block(argument_type.block());
          is_block = true;
        } else if (argument_type.is_any()) {
          ASSERT(!is_block);
          type.add_any(program());
        } else {
          ASSERT(!is_block);
          type.add(argument_type.id());
        }
      }
      types->add_argument(method->method(), n, type);
    }
  }

  for (auto it = blocks.begin(); it != blocks.end(); it++) {
    std::vector<BlockTemplate*>& blocks = it->second;
    BlockTemplate* block = blocks[0];
    types->add_method(block->method());

    type.clear(words_per_type());
    type.set_block(block);
    types->add_argument(block->method(), 0, type);

    int arity = block->arity();
    for (int n = 1; n < arity; n++) {
      type.clear(words_per_type());
      for (unsigned i = 0; i < blocks.size(); i++) {
        TypeVariable* argument = blocks[i]->argument(n);
        type.add_all(argument->type(), words_per_type());
      }
      types->add_argument(block->method(), n, type);
    }
  }
}

void TypePropagator::call_method(
    MethodTemplate* caller,
    TypeScope* scope,
    uint8* site,
    Method target,
    std::vector<ConcreteType>& arguments) {
  TypeStack* stack = scope->top();
  int arity = target.arity();
  int index = arguments.size();
  if (index == arity) {
    MethodTemplate* callee = find(target, arguments);
    TypeSet result = callee->call(this, caller, site);
    stack->merge_top(result);
    // For all we know, the call might throw. We should
    // propagate more information, so we know that certain
    // methods never throw.
    scope->throw_maybe();
    return;
  }

  // This is the heart of the Cartesian Product Algorithm (CPA). We
  // compute the cartesian product of all the argument types and
  // instantiate a method template for each possible combination. This
  // is essentially <arity> nested loops with a few cut-offs for blocks
  // and megamorphic types that tend to blow up the analysis.
  TypeSet type = stack->local(arity - index);
  if (type.is_block()) {
    arguments.push_back(type.block()->pass_as_argument(scope));
    call_method(caller, scope, site, target, arguments);
    arguments.pop_back();
  } else if (type.size(words_per_type_) > 5) {
    // If one of the arguments is megamorphic, we analyze the target
    // method with the any type for that argument instead. This cuts
    // down on the number of separate analysis at the cost of more
    // mixing of types and worse propagated types.
    arguments.push_back(ConcreteType::any());
    call_method(caller, scope, site, target, arguments);
    arguments.pop_back();
  } else {
    TypeSet::Iterator it(type, words_per_type_);
    while (it.has_next()) {
      unsigned id = it.next();
      arguments.push_back(ConcreteType(id));
      call_method(caller, scope, site, target, arguments);
      arguments.pop_back();
    }
  }
}

void TypePropagator::call_static(MethodTemplate* caller, TypeScope* scope, uint8* site, Method target) {
  TypeStack* stack = scope->top();
  std::vector<ConcreteType> arguments;
  stack->push_empty();
  call_method(caller, scope, site, target, arguments);
  stack->drop_arguments(target.arity());
}

void TypePropagator::call_virtual(MethodTemplate* caller, TypeScope* scope, uint8* site, int arity, int offset) {
  TypeStack* stack = scope->top();
  TypeSet receiver = stack->local(arity - 1);

  std::vector<ConcreteType> arguments;
  stack->push_empty();

  Program* program = this->program();
  TypeSet::Iterator it(receiver, words_per_type_);
  while (it.has_next()) {
    unsigned id = it.next();
    int entry_index = id + offset;
    int entry_id = program->dispatch_table[entry_index];
    Method target = (entry_id >= 0)
        ? Method(program->bytecodes, entry_id)
        : Method::invalid();
    if (!target.is_valid() || target.selector_offset() != offset) {
      // There is a chance we'll get a lookup error thrown here.
      ensure_lookup_failure();
      scope->throw_maybe();
      continue;
    }
    arguments.push_back(ConcreteType(id));
    call_method(caller, scope, site, target, arguments);
    arguments.pop_back();
  }

  stack->drop_arguments(arity);
}

void TypePropagator::propagate_through_lambda(Method method) {
  ASSERT(method.is_lambda_method());
  std::vector<ConcreteType> arguments;
  // TODO(kasper): Can we at least push an instance of the Lambda class
  // as the receiver type?
  for (int i = 0; i < method.arity(); i++) {
    // We're instantiating a lambda instance here, so we don't
    // know which arguments will be passed to it when it is
    // invoked. For now, we conservatively assume it can be
    // anything even though that isn't great.
    arguments.push_back(ConcreteType::any());
  }
  find(method, arguments);
}

void TypePropagator::load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index) {
  TypeSet instance = stack->local(0);
  stack->push_empty();

  TypeSet::Iterator it(instance, words_per_type_);
  while (it.has_next()) {
    unsigned id = it.next();
    TypeSet result = field(id, index)->use(this, user, site);
    stack->merge_top(result);
  }

  stack->drop_arguments(1);
}

void TypePropagator::store_field(MethodTemplate* user, TypeStack* stack, int index) {
  TypeSet value = stack->local(0);
  TypeSet instance = stack->local(1);

  TypeSet::Iterator it(instance, words_per_type_);
  while (it.has_next()) {
    unsigned id = it.next();
    field(id, index)->merge(this, value);
  }

  stack->drop_arguments(1);
}

void TypePropagator::load_outer(TypeScope* scope, uint8* site, int index) {
  TypeStack* stack = scope->top();
  TypeSet block = stack->local(0);
  TypeSet value = scope->load_outer(block, index);
  stack->pop();
  stack->push(value);
  if (value.is_block()) return;
  // We keep track of the types we've seen for outer locals for
  // this particular access site. We use this merged type exclusively
  // for the output of the type propagator, so we don't actually
  // use the merged type anywhere in the analysis.
  TypeVariable* merged = this->outer(site);
  merged->merge(this, value);
}

TypeVariable* TypePropagator::field(unsigned type, int index) {
  auto it = fields_.find(type);
  if (it != fields_.end()) {
    std::unordered_map<int, TypeVariable*>& map = it->second;
    auto itx = map.find(index);
    if (itx != map.end()) return itx->second;
    TypeVariable* variable = new TypeVariable(words_per_type());
    map[index] = variable;
    return variable;
  }

  std::unordered_map<int, TypeVariable*> map;
  TypeVariable* variable = new TypeVariable(words_per_type());
  map[index] = variable;
  fields_[type] = map;
  return variable;
}

TypeVariable* TypePropagator::global_variable(int index) {
  auto it = globals_.find(index);
  if (it == globals_.end()) {
    TypeVariable* variable = new TypeVariable(words_per_type());
    globals_[index] = variable;
    return variable;
  } else {
    return it->second;
  }
}

TypeVariable* TypePropagator::outer(uint8* site) {
  auto it = outers_.find(site);
  if (it == outers_.end()) {
    TypeVariable* variable = new TypeVariable(words_per_type());
    outers_[site] = variable;
    add_site(site, variable);
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

void TypePropagator::add_site(uint8* site, TypeVariable* result) {
  sites_[site].insert(result);
}

MethodTemplate* TypePropagator::find(Method target, std::vector<ConcreteType> arguments) {
  uint8* key = target.header_bcp();
  auto it = templates_.find(key);
  if (it == templates_.end()) {
    std::vector<MethodTemplate*> templates;
    MethodTemplate* result = instantiate(target, arguments);
    templates.push_back(result);
    templates_[key] = templates;
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

// Propagates the type stack starting at the given bcp in this method context.
// The bcp could be the beginning of the method, a block entry, a branch target, ...
static TypeScope* process(TypeScope* scope, uint8* bcp, std::vector<Worklist*>& worklists) {
#define LABEL(opcode, length, format, print) &&interpret_##opcode,
  static void* dispatch_table[] = {
    BYTECODES(LABEL)
  };
#undef LABEL

  bool linked = false;
  MethodTemplate* method = scope->method();
  TypePropagator* propagator = method->propagator();
  Program* program = propagator->program();
  TypeStack* stack = scope->top();
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
    propagator->load_outer(scope, bcp, stack_offset);
  OPCODE_END();

  OPCODE_BEGIN(STORE_OUTER);
    B_ARG1(stack_offset);
    TypeSet value = stack->local(0);
    TypeSet block = stack->local(1);
    scope->store_outer(block, stack_offset, value);
    stack->pop();
    stack->pop();
    stack->push(value);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_FIELD, field_index);
    propagator->load_field(method, stack, bcp, field_index);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field_index = encoded >> 4;
    TypeSet instance = stack->local(local);
    stack->push(instance);
    propagator->load_field(method, stack, bcp, field_index);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field_index = encoded >> 4;
    TypeSet instance = stack->local(local + 1);
    stack->set_local(0, instance);
    propagator->load_field(method, stack, bcp, field_index);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_FIELD, field_index);
    propagator->store_field(method, stack, field_index);
  OPCODE_END();

  OPCODE_BEGIN(STORE_FIELD_POP);
    B_ARG1(field_index);
    propagator->store_field(method, stack, field_index);
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

  OPCODE_BEGIN(LOAD_METHOD);
    Method inner = Method(program->bytecodes, Utils::read_unaligned_uint32(bcp + 1));
    if (inner.is_block_method()) {
      // Finds or creates a block-template for the given block.
      // The block's parameters are marked such that a change in their type enqueues this
      // current method template.
      // Note that the method template is for a specific combination of parameter types. As
      // such we evaluate the contained blocks independently too.
      BlockTemplate* block = method->find_block(inner, scope->level(), bcp);
      stack->push_block(block);
      // If the block might be used in a try-block, we need to know
      // so we can correctly merge the type of outer locals. If we're
      // not in a try-block, changes to outer locals cannot be seen
      // when we unwind, but potentially being in a try block changes that.
      bool is_inner_linked = bcp[LOAD_METHOD_LENGTH] == LINK;
      block->propagate(scope, worklists, is_inner_linked || block->is_invoked_from_try_block());
    } else {
      propagator->propagate_through_lambda(inner);
      stack->push_smi(program);
    }
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, index);
    TypeVariable* variable = propagator->global_variable(index);
    stack->push(variable->use(propagator, method, bcp));
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR_LAZY, index);
    // The interpreter calls 'run_global_initializer_' to ensure
    // that we deal with reentrant initialization correctly. This
    // can throw.
    propagator->ensure_run_global_initializer();
    scope->throw_maybe();
    // Analyze a call to the initializer method.
    Instance* initializer = Instance::cast(program->global_variables.at(index));
    int method_id = Smi::cast(initializer->at(INITIALIZER_ID_INDEX))->value();
    Method target(program->bytecodes, method_id);
    propagator->call_static(method, scope, null, target);
    // Merge the initializer result into the global variable.
    TypeVariable* variable = propagator->global_variable(index);
    variable->merge(propagator, stack->local(0));
    stack->pop();
    // Push the resulting type.
    stack->push(variable->use(propagator, method, bcp));
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_GLOBAL_VAR, index);
    TypeVariable* variable = propagator->global_variable(index);
    TypeSet top = stack->local(0);
    variable->merge(propagator, top);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_BLOCK);
    B_ARG1(index);
    TypeSet block = stack->local(index);
    ASSERT(block.is_block());
    stack->push(block);
  OPCODE_END();

  OPCODE_BEGIN(LOAD_GLOBAL_VAR_DYNAMIC);
    // Global variables that need lazy initialization
    // are handled as part of the LOAD_GLOBAL_VAR_LAZY
    // bytecode. The LOAD_GLOBAL_VAR_DYNAMIC bytecode
    // is only used from within the special entry point
    // 'run_global_initializer_' and in that context
    // it can produce any value.
    stack->pop();  // Drop the id.
    stack->push_any(program);
  OPCODE_END();

  OPCODE_BEGIN(STORE_GLOBAL_VAR_DYNAMIC);
    // Just ignore stores. The LOAD_GLOBAL_VAR_DYNAMIC
    // bytecode conservatively assumes that anything can
    // be stored in the global variable.
    stack->pop();  // Drop the value.
    stack->pop();  // Drop the id.
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_INITIALIZER_TAIL);
    // The initializer is analyzed as a call directly
    // from the LOAD_GLOBAL_VAR_LAZY bytecode. Here, it
    // is fine to let it produce any value.
    stack->pop();  // Drop the id.
    stack->push_any(program);
    method->ret(propagator, stack);
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(LOAD_OUTER_BLOCK);
    B_ARG1(stack_offset);
    propagator->load_outer(scope, bcp, stack_offset);
    TypeSet value = stack->local(0);
    ASSERT(value.is_block());
  OPCODE_END();

  OPCODE_BEGIN(POP);
    B_ARG1(index);
    for (int i = 0; i < index; i++) stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(POP_1);
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(ALLOCATE, class_index);
    // TODO(kasper): Can we check if the fields we
    // mark as being nullable are guaranteed to be overwritten?
    int fields = program->instance_fields_for(Smi::from(class_index));
    for (int i = 0; i < fields; i++) {
      stack->push_null(program);
      propagator->field(class_index, i)->merge(propagator, stack->local(0));
      stack->pop();
    }
    stack->push_instance(class_index);
    // Allocating an instance can throw.
    scope->throw_maybe();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_CLASS, encoded);
    USE(encoded);
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_INTERFACE, encoded);
    USE(encoded);
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_CLASS, encoded);
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    // For all we know, doing the 'as' check can throw.
    propagator->ensure_as_check_failure();
    scope->throw_maybe();
    if (!top.remove_typecheck_class(program, class_index, is_nullable)) return scope;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    // For all we know, doing the 'as' check can throw.
    propagator->ensure_as_check_failure();
    scope->throw_maybe();
    if (!top.remove_typecheck_interface(program, interface_selector_index, is_nullable)) return scope;
  OPCODE_END();

  OPCODE_BEGIN(AS_LOCAL);
    B_ARG1(encoded);
    int stack_offset = encoded >> 5;
    bool is_nullable = false;
    int class_index = encoded & 0x1F;
    TypeSet local = stack->local(stack_offset);
    // For all we know, doing the 'as' check can throw.
    propagator->ensure_as_check_failure();
    scope->throw_maybe();
    if (!local.remove_typecheck_class(program, class_index, is_nullable)) return scope;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC);
    S_ARG1(offset);
    Method target(program->bytecodes, program->dispatch_table[offset]);
    propagator->call_static(method, scope, bcp, target);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_STATIC_TAIL);
    S_ARG1(offset);
    Method target(program->bytecodes, program->dispatch_table[offset]);
    propagator->call_static(method, scope, bcp, target);
    if (stack->top_is_empty()) return scope;
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      scope->outer()->merge(scope, TypeScope::MERGE_RETURN);
    } else {
      method->ret(propagator, stack);
    }
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_BLOCK);
    B_ARG1(index);
    TypeSet receiver = stack->local(index - 1);
    BlockTemplate* block = receiver.block();
    // If we're passing too few arguments to the block, this will
    // throw and we should not continue analyzing on this path.
    if (index < block->arity()) {
      scope->throw_maybe();
      return scope;
    }
    for (int i = 1; i < block->arity(); i++) {
      TypeSet argument = stack->local(index - (i + 1));
      // Merge the argument type. If the type changed, we enqueue
      // the block's surrounding method because it has used the
      // argument type variable. We always start at the method,
      // so we have the full scope available to all blocks when
      // propagating types through them.
      block->argument(i)->merge(propagator, argument);
    }
    for (int i = 0; i < index; i++) stack->pop();
    // If the return type of this block changes, we enqueue the
    // surrounding method again.
    TypeSet value = block->invoke(propagator, scope, bcp);
    // For all we know, invoking the block can throw. We can
    // improve on this by propagating information about which
    // blocks throw.
    propagator->ensure_code_failure();
    scope->throw_maybe();

    if (value.is_empty(propagator->words_per_type())) {
      if (!linked) return scope;
      // We've just invoked a try-block that is guaranteed
      // to unwind as indicated by the empty return type.
      // We propagate this information to the 'unwind' bytecode which is
      // guaranteed to follow this bytecode after a few other bytecodes (like
      // POP and UNLINK). This way it can avoid propagating types through the
      // code that follows it (fall through) because there are
      // cases (like the monitor methods that call 'locked_')
      // where the compiler assumes that we will not execute
      // that part and avoids terminating the method with a
      // 'return' bytecode.
      TypeSet target = stack->local(2);
      target.add_smi(program);  // We don't know the target, but we know we have one.
    }
    stack->push(value);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(INVOKE_VIRTUAL, arity);
    int offset = Utils::read_unaligned_uint16(bcp + 2);
    propagator->call_virtual(method, scope, bcp, arity + 1, offset);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_GET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, scope, bcp, 1, offset);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_SET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, scope, bcp, 2, offset);
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

#define INVOKE_VIRTUAL_BINARY(opcode)                         \
  OPCODE_BEGIN(opcode);                                       \
    int offset = program->invoke_bytecode_offset(opcode);     \
    propagator->call_virtual(method, scope, bcp, 2, offset);  \
    if (stack->top_is_empty()) return scope;                   \
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
    propagator->call_virtual(method, scope, bcp, 3, offset);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH);
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    return worklists.back()->add(target, scope, false);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_TRUE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    scope = worklists.back()->add(target, scope, true);
    stack = scope->top();
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_FALSE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    scope = worklists.back()->add(target, scope, true);
    stack = scope->top();
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK);
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    return worklists.back()->add(target, scope, false);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_TRUE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    scope = worklists.back()->add(target, scope, true);
    stack = scope->top();
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_FALSE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    scope = worklists.back()->add(target, scope, true);
    stack = scope->top();
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_LAMBDA_TAIL);
    propagator->ensure_code_failure();
    scope->throw_maybe();
    stack->push_any(program);
    method->ret(propagator, stack);
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(PRIMITIVE);
    B_ARG1(module);
    unsigned index = Utils::read_unaligned_uint16(bcp + 2);
    const TypePrimitiveEntry* primitive = TypePrimitive::at(module, index);
    if (primitive == null) return scope;
    propagator->ensure_primitive_lookup_failure();
    TypePrimitive::Entry* entry = reinterpret_cast<TypePrimitive::Entry*>(primitive->function);
    stack->push_empty();
    stack->push_empty();
    entry(program, stack->local(0), stack->local(1));
    method->ret(propagator, stack);
    if (stack->top_is_empty()) return scope;
    if (TypePrimitive::uses_entry_task(module, index)) {
      propagator->ensure_entry_task();
    }
    if (TypePrimitive::uses_entry_spawn(module, index)) {
      propagator->ensure_entry_spawn();
    }
  OPCODE_END();

  OPCODE_BEGIN(THROW);
    scope->throw_maybe();
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(RETURN);
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      scope->outer()->merge(scope, TypeScope::MERGE_RETURN);
    } else {
      method->ret(propagator, stack);
    }
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(RETURN_NULL);
    stack->push_null(program);
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      scope->outer()->merge(scope, TypeScope::MERGE_RETURN);
    } else {
      method->ret(propagator, stack);
    }
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN);
    stack->pop();  // Pop block.
    method->ret(propagator, stack);
    scope->outer()->merge(scope, TypeScope::MERGE_UNWIND);
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN_WIDE);
    stack->pop();  // Pop block.
    method->ret(propagator, stack);
    scope->outer()->merge(scope, TypeScope::MERGE_UNWIND);
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_BRANCH);
    // TODO(kasper): We should be able to do better here, because
    // we're only unwinding to a specific scope level and we may
    // not be crossing the try-block.
    scope->outer()->merge(scope, TypeScope::MERGE_UNWIND);
    // Decode the branch target and enqueue the processing work
    // in the worklist associated with the target scope.
    B_ARG1(height_diff);
    uint32 target_bci = Utils::read_unaligned_uint32(bcp + 2);
    uint8* target_bcp = program->bcp_from_absolute_bci(target_bci);
    TypeSet block = stack->local(0);
    int target_level = block.block()->level();
    TypeScope* target_scope = scope->copy_lazy(target_level);
    for (int i = 0; i < height_diff; i++) target_scope->top()->pop();
    TypeScope* extra = worklists[target_level]->add(target_bcp, target_scope, false);
    delete extra;
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(IDENTICAL);
    stack->pop();
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    stack->push_instance(program->exception_class_id()->value());
    stack->push_empty();       // Unwind target.
    stack->push_smi(program);  // Unwind reason. Looked at by finally blocks with parameters.
    stack->push_smi(program);  // Unwind chain next.
    // Try/finally is implemented as:
    //   LINK, LOAD BLOCK, INVOKE BLOCK, POP, UNLINK, <finally code>, UNWIND.
    // As such we can never have nested linked code, as the block would be
    // evaluated independently.
    ASSERT(!linked);
    linked = true;
  OPCODE_END();

  OPCODE_BEGIN(UNLINK);
    stack->pop();
    linked = false;
  OPCODE_END();

  OPCODE_BEGIN(UNWIND);
    // If the try-block is guaranteed to cause unwinding,
    // we avoid analyzing the bytecodes following this one.
    TypeSet target = stack->local(1);
    bool unwind = !target.is_empty(propagator->words_per_type());
    if (unwind) return scope;
    stack->pop();
    stack->pop();
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(HALT);
    return scope;
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

BlockTemplate* MethodTemplate::find_block(Method method, int level, uint8* site) {
  auto it = blocks_.find(site);
  if (it == blocks_.end()) {
    BlockTemplate* block = new BlockTemplate(this, method, level, propagator_->words_per_type());
    for (int i = 1; i < method.arity(); i++) {
      block->argument(i)->use(propagator_, this, null);
    }
    blocks_[site] = block;
    return block;
  } else {
    return it->second;
  }
}

void MethodTemplate::collect_blocks(std::unordered_map<uint8*, std::vector<BlockTemplate*>>& map) {
  for (auto it = blocks_.begin(); it != blocks_.end(); it++) {
    auto inner = map.find(it->first);
    if (inner == map.end()) {
      std::vector<BlockTemplate*> blocks;
      blocks.push_back(it->second);
      map[it->first] = blocks;
      continue;
    }
    std::vector<BlockTemplate*>& blocks = inner->second;
    blocks.push_back(it->second);
  }
}

int MethodTemplate::method_id() const {
  return propagator_->program()->absolute_bci_from_bcp(method_.header_bcp());
}

void MethodTemplate::propagate() {
  TypeScope* scope = new TypeScope(this);

  // We need to special case the 'operator ==' method, because the interpreter
  // does a manual null check on both arguments, which means that null never
  // flows into the method body. We have to simulate that.
  Program* program = propagator_->program();
  if (method_.selector_offset() == program->invoke_bytecode_offset(INVOKE_EQ)) {
    TypeStack* stack = scope->top();
    ConcreteType null_type = ConcreteType(program->null_class_id()->value());
    bool receiver_is_null = argument(0).matches(null_type);
    bool argument_is_null = argument(1).matches(null_type);
    if (receiver_is_null || argument_is_null) {
      stack->push_bool_specific(program, receiver_is_null && argument_is_null);
      ret(propagator_, stack);
      delete scope;
      return;
    }
    for (int i = 0; i < arity(); i++) {
      TypeSet argument = stack->get(i);
      argument.remove_null(program);
    }
  }

  std::vector<Worklist*> worklists;
  Worklist worklist(method_.entry(), scope);
  worklists.push_back(&worklist);

  while (worklist.has_next()) {
    Worklist::Item item = worklist.next();
    TypeScope* scope = process(item.scope, item.bcp, worklists);
    delete scope;
  }
}

int BlockTemplate::method_id(Program* program) const {
  return program->absolute_bci_from_bcp(method_.header_bcp());
}

void BlockTemplate::invoke_from_try_block() {
  if (is_invoked_from_try_block_) return;
  // If we find that this block may have been invoked from
  // within a try-block, we re-analyze the surrounding
  // method, so we can track stores to outer locals that
  // may be visible because of caught exceptions or
  // stopped unwinding.
  is_invoked_from_try_block_ = true;
  origin_->propagator()->enqueue(origin_);
}

void BlockTemplate::propagate(TypeScope* scope, std::vector<Worklist*>& worklists, bool linked) {
  // TODO(kasper): It feels wasteful to re-analyze blocks that
  // do not depend on the outer local types that were updated
  // by an inner block (or the blocks themselves).
  while (true) {
    // We create a lazy copy of the current scope, so it becomes
    // easy to track if an inner block has modified the scope.
    // This is very close to how we handle loops, so the lazy
    // copy ends up corresponding to the lazy copy we create when
    // we re-analyze from the beginning of a loop if the loop
    // or any nested loop changes local types.
    TypeScope* copy = scope->copy_lazy();
    TypeScope* inner = new TypeScope(this, copy, linked);

    Worklist worklist(method_.entry(), inner);
    worklists.push_back(&worklist);

    while (worklist.has_next()) {
      Worklist::Item item = worklist.next();
      TypeScope* scope = process(item.scope, item.bcp, worklists);
      delete scope;
    }

    worklists.pop_back();
    bool done = !scope->merge(copy, TypeScope::MERGE_LOCAL);
    delete copy;
    if (done) return;
  }
}

} // namespace toit::compiler
} // namespace toit
