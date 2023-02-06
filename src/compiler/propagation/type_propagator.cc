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

  // Initialize Map fields. We allocate the map instances from within
  // the VM when decoding messages.
  stack.push_smi(program());
  field(program()->map_class_id()->value(), Instance::MAP_SIZE_INDEX)->merge(this, stack.local(0));
  field(program()->map_class_id()->value(), Instance::MAP_SPACES_LEFT_INDEX)->merge(this, stack.local(0));
  stack.pop();
  stack.push_null(program());
  field(program()->map_class_id()->value(), Instance::MAP_INDEX_INDEX)->merge(this, stack.local(0));
  field(program()->map_class_id()->value(), Instance::MAP_BACKING_INDEX)->merge(this, stack.local(0));
  stack.pop();
  stack.push_array(program());
  field(program()->map_class_id()->value(), Instance::MAP_BACKING_INDEX)->merge(this, stack.local(0));
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

  if (has_entry_task_) {
    // If we've analyzed the __entry__task method, we need to note
    // that we can return to the bytecode that follows the initial
    // faked 'load null' one. The top of stack will be a task.
    uint8* entry = program()->entry_task().entry();
    type.clear(words_per_type());
    type.add_instance(program()->task_class_id());
    types->add_output(program()->absolute_bci_from_bcp(entry), type);
  }

  output_.for_each([&](uint8* site, Set<TypeVariable*>& output) {
    type.clear(words_per_type());
    for (auto it = output.begin(); it != output.end(); it++) {
      type.add_all_also_blocks((*it)->type(), words_per_type());
    }
    int position = program()->absolute_bci_from_bcp(site);
    types->add_output(position, type);
  });

  input_.for_each([&](uint8* site, std::vector<TypeVariable*>& variables) {
    int position = program()->absolute_bci_from_bcp(site);
    for (unsigned i = 0; i < variables.size(); i++) {
      types->add_input(position, i, variables.size(), variables[i]->type());
    }
  });

  // Group the methods and blocks based on the bytecode position, so
  // we can collect the type information in a form that is indexable
  // by bytecode pointers.
  std::unordered_map<uint8*, std::vector<MethodTemplate*>> methods;
  for (auto it = methods_.begin(); it != methods_.end(); it++) {
    MethodTemplate* method = it->second;
    do {
      method->collect_method(&methods);
      method = method->next();
    } while (method);
  }

  std::unordered_map<uint8*, std::vector<BlockTemplate*>> blocks;
  for (auto it = blocks_.begin(); it != blocks_.end(); it++) {
    BlockTemplate* block = it->second;
    do {
      block->collect_block(&blocks);
      block = block->next();
    } while (block);
  }

  for (auto it = methods.begin(); it != methods.end(); it++) {
    std::vector<MethodTemplate*>& list = it->second;
    MethodTemplate* method = list[0];
    types->add_method(method->method());
    int arity = method->arity();
    for (int n = 0; n < arity; n++) {
      bool is_block = false;
      type.clear(words_per_type());
      for (unsigned i = 0; i < list.size(); i++) {
        ConcreteType argument_type = list[i]->argument(n);
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
    std::vector<BlockTemplate*>& list = it->second;
    BlockTemplate* block = list[0];
    types->add_method(block->method());

    type.clear(words_per_type());
    type.set_block(block);
    types->add_argument(block->method(), 0, type);

    int arity = block->arity();
    for (int n = 1; n < arity; n++) {
      type.clear(words_per_type());
      for (unsigned i = 0; i < list.size(); i++) {
        TypeVariable* argument = list[i]->argument(n);
        type.add_all(argument->type(), words_per_type());
      }
      types->add_argument(block->method(), n, type);
    }
  }
}

// The arguments vector is used as a stack, so we
// temporarily modify it while in (recursive) call.
// Once we return, the vector appears untouched because
// the additional elements will have been popped
// off from the end of the vector.
void TypePropagator::call_method(MethodTemplate* caller,
                                 TypeScope* scope,
                                 uint8* site,
                                 Method target,
                                 std::vector<ConcreteType>& arguments) {
  TypeStack* stack = scope->top();
  int arity = target.arity();
  int index = arguments.size();
  if (index == arity) {
    MethodTemplate* callee = find_method(target, arguments);
    // TODO(kasper): Analyzing the callee method eagerly while still
    // in the process of analyzing the caller is an optimization. It
    // would be interesting to see the effect of avoiding that and
    // just enqueuing the callee for analysis instead. It would lead
    // to a re-analysis of the caller method.
    if (!callee->analyzed()) callee->propagate();
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
  int arity = target.arity();
  if (site) add_input(site, stack, arity);

  std::vector<ConcreteType> arguments;
  stack->push_empty();

  int offset = target.selector_offset();
  bool handle_as_static = (offset == -1);
  if (offset >= 0) {
    ASSERT(arity > 0);
    TypeSet receiver = stack->local(arity);
    // If the receiver is a single type, we don't need
    // to do virtual lookups. This allows us to handle
    // super calls where we cannot find the (virtual)
    // super method in the dispatch table entries for
    // the receiver because they have been overridden.
    handle_as_static = receiver.size(words_per_type_) <= 1;
  }

  if (handle_as_static) {
    call_method(caller, scope, site, target, arguments);
  } else {
    // We're handling this as a call to a virtual method,
    // but if the offset is negative it indirectly encodes
    // the range of classes that inherit the method from
    // the holder class. We can find the class id limits
    // for the range in the class check table.
    Program* program = this->program();
    unsigned limit_lower = 0;
    unsigned limit_upper = 0;
    if (offset < 0) {
      ASSERT(offset <= -2);
      int index = -(offset + 2);
      limit_lower = program->class_check_ids[2 * index];
      limit_upper = program->class_check_ids[2 * index + 1];
    }
    // Run over all receiver type variants like we do for
    // virtual calls. If and only if the target method
    // can be looked up on the receiver we analyze the case.
    // Otherwise, we ignore it and avoid marking this as
    // a possible lookup error, because we trust the compiler
    // to be right about the types.
    TypeSet receiver = stack->local(arity);
    TypeSet::Iterator it(receiver, words_per_type_);
    while (it.has_next()) {
      unsigned id = it.next();
      if (offset >= 0) {
        int entry_index = id + offset;
        int entry_id = program->dispatch_table[entry_index];
        // If the type propagator knows less about the types we
        // can encounter than the compiler, we risk loading
        // from areas of the dispatch table the compiler didn't
        // anticipate. Guard against that.
        if (entry_id < 0) continue;
        Method entry = Method(program->bytecodes, entry_id);
        if (entry.header_bcp() != target.header_bcp()) continue;
      } else if (id < limit_lower || id >= limit_upper) {
        // Skip ids that are outside the limits.
        continue;
      }
      arguments.push_back(ConcreteType(id));
      call_method(caller, scope, site, target, arguments);
      arguments.pop_back();
    }
  }

  stack->drop_arguments(target.arity());
}

void TypePropagator::call_virtual(MethodTemplate* caller, TypeScope* scope, uint8* site, int arity, int offset) {
  TypeStack* stack = scope->top();
  TypeSet receiver = stack->local(arity - 1);
  if (site) add_input(site, stack, arity);

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

void TypePropagator::call_block(TypeScope* scope, uint8* site, int arity) {
  TypeStack* stack = scope->top();
  TypeSet receiver = stack->local(arity - 1);
  BlockTemplate* block = receiver.block();
  if (site) add_input(site, stack, arity);

  // If we're passing too few arguments to the block, this will
  // throw so we do not need to update the block's argument types.
  if (arity >= block->arity()) {
    for (int i = 1; i < block->arity(); i++) {
      TypeSet argument = stack->local(arity - (i + 1));
      // Merge the argument type. If the type changed, we enqueue
      // the block's surrounding method because it has used the
      // argument type variable. We always start at the method,
      // so we have the full scope available to all blocks when
      // propagating types through them.
      block->argument(i)->merge(this, argument);
    }
  }

  // Drop the arguments from the stack.
  for (int i = 0; i < arity; i++) stack->pop();

  // If the return type of this block changes, we enqueue the
  // current surrounding method (not the block's) again.
  if (arity >= block->arity()) {
    TypeSet value = block->invoke(this, scope, site);
    stack->push(value);
  } else {
    stack->push_empty();
  }

  // For all we know, invoking the block can throw. We can
  // improve on this by propagating information about which
  // blocks throw.
  ensure_code_failure();
  scope->throw_maybe();
}

void TypePropagator::load_block(MethodTemplate* loader, TypeScope* scope, Method method, bool linked, std::vector<Worklist*>& worklists) {
  ASSERT(method.is_block_method());
  // Finds or creates a block-template for the given block.
  // The block's parameters are marked such that a change in their type enqueues this
  // current method template.
  // Note that the method template is for a specific combination of parameter types. As
  // such we evaluate the contained blocks independently too.
  BlockTemplate* block = find_block(loader, method, scope->level());
  scope->top()->push_block(block);
  // If the block might be used in a try-block, we need to know
  // so we can correctly merge the type of outer locals. If we're
  // not in a try-block, changes to outer locals cannot be seen
  // when we unwind, but potentially being in a try block changes that.
  block->propagate(scope, worklists, linked || block->is_invoked_from_try_block());
}

void TypePropagator::load_lambda(TypeScope* scope, Method method) {
  ASSERT(method.is_lambda_method());
  std::vector<ConcreteType> arguments;
  for (int i = 0; i < method.arity(); i++) {
    // We're instantiating a lambda instance here, so we don't
    // know which arguments will be passed to it when it is
    // invoked. For now, we conservatively assume it can be
    // anything even though that isn't great.
    arguments.push_back(ConcreteType::any());
  }
  MethodTemplate* callee = find_method(method, arguments);
  scope->top()->push_smi(program());  // Method of lambda.
  callee->propagate();
}

void TypePropagator::load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index) {
  TypeSet instance = stack->local(0);
  if (site) add_input(site, stack, 1);

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
  // We keep track of the types we've seen for outer locals for
  // this particular access site. We use this merged type exclusively
  // for the output of the type propagator, so we don't actually
  // use the merged type anywhere in the analysis.
  TypeVariable* merged = this->output(site);
  merged->type().add_all_also_blocks(value, words_per_type());
}

bool TypePropagator::handle_typecheck_result(TypeScope* scope, uint8* site, bool as_check, int result) {
  TypeStack* stack = scope->top();
  bool can_fail = (result & TypeSet::TYPECHECK_CAN_FAIL) != 0;
  bool can_succeed = (result & TypeSet::TYPECHECK_CAN_SUCCEED) != 0;
  if (can_succeed && can_fail)  {
    stack->push_bool(program());
  } else if (can_succeed) {
    stack->push_bool_specific(program(), true);
  } else {
    ASSERT(can_fail);
    stack->push_bool_specific(program(), false);
    if (as_check) {
      ensure_as_check_failure();
      scope->throw_maybe();
    }
  }
  output(site)->type().add_all(stack->local(0), words_per_type());
  if (as_check) stack->pop();
  return can_succeed;
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

TypeVariable* TypePropagator::output(uint8* site) {
  auto it = outers_.find(site);
  if (it == outers_.end()) {
    TypeVariable* output = new TypeVariable(words_per_type());
    outers_[site] = output;
    add_output(site, output);
    return output;
  } else {
    return it->second;
  }
}

void TypePropagator::enqueue(MethodTemplate* method) {
  if (!method || method->enqueued()) return;
  method->mark_enqueued();
  enqueued_.push_back(method);
}

void TypePropagator::add_input(uint8* site, TypeStack* input, int n) {
  auto probe = input_.find(site);
  if (probe != input_.end()) {
    std::vector<TypeVariable*>& variables = probe->second;
    ASSERT(static_cast<int>(variables.size()) == n);
    for (int i = 0; i < n; i++) {
      TypeVariable* variable = variables[i];
      variable->type().add_all_also_blocks(input->local(n - i - 1), words_per_type());
    }
    return;
  }

  std::vector<TypeVariable*> variables;
  for (int i = 0; i < n; i++) {
    TypeVariable* variable = new TypeVariable(words_per_type());
    variable->type().add_all_also_blocks(input->local(n - i - 1), words_per_type());
    variables.push_back(variable);
  }
  input_[site] = variables;
}

void TypePropagator::add_output(uint8* site, TypeVariable* output) {
  output_[site].insert(output);
}

MethodTemplate* TypePropagator::find_method(Method target, std::vector<ConcreteType> arguments) {
  uint32 key = ConcreteType::hash(target, arguments, false);
  auto it = methods_.find(key);
  MethodTemplate* head = (it != methods_.end()) ? it->second : null;
  for (MethodTemplate* candidate = head; candidate; candidate = candidate->next()) {
    if (candidate->matches(target, arguments)) return candidate;
  }
  MethodTemplate* result = new MethodTemplate(head, this, target, arguments);
  methods_[key] = result;
  return result;
}

BlockTemplate* TypePropagator::find_block(MethodTemplate* origin, Method target, int level) {
  uint32 key = ConcreteType::hash(target, origin->arguments(), true);
  auto it = blocks_.find(key);
  BlockTemplate* head = (it != blocks_.end()) ? it->second : null;
  for (BlockTemplate* candidate = head; candidate; candidate = candidate->next()) {
    if (candidate->matches(target, origin)) {
      candidate->use(this, origin);
      return candidate;
    }
  }
  BlockTemplate* result = new BlockTemplate(head, target, level, words_per_type());
  blocks_[key] = result;
  result->use(this, origin);
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
      bool is_inner_linked = bcp[LOAD_METHOD_LENGTH] == LINK;
      propagator->load_block(method, scope, inner, is_inner_linked, worklists);
    } else {
      propagator->load_lambda(scope, inner);
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
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    int result = top.remove_typecheck_class(program, class_index, is_nullable);
    stack->pop();
    propagator->handle_typecheck_result(scope, bcp, false, result);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(IS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    int result = top.remove_typecheck_interface(program, interface_selector_index, is_nullable);
    stack->pop();
    propagator->handle_typecheck_result(scope, bcp, false, result);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_CLASS, encoded);
    int class_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    int result = top.remove_typecheck_class(program, class_index, is_nullable);
    if (!propagator->handle_typecheck_result(scope, bcp, true, result)) return scope;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(AS_INTERFACE, encoded);
    int interface_selector_index = encoded >> 1;
    bool is_nullable = (encoded & 1) != 0;
    TypeSet top = stack->local(0);
    int result = top.remove_typecheck_interface(program, interface_selector_index, is_nullable);
    if (!propagator->handle_typecheck_result(scope, bcp, true, result)) return scope;
  OPCODE_END();

  OPCODE_BEGIN(AS_LOCAL);
    B_ARG1(encoded);
    int stack_offset = encoded >> 5;
    bool is_nullable = false;
    int class_index = encoded & 0x1F;
    TypeSet local = stack->local(stack_offset);
    int result = local.remove_typecheck_class(program, class_index, is_nullable);
    if (!propagator->handle_typecheck_result(scope, bcp, true, result)) return scope;
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
    propagator->call_block(scope, bcp, index);
    if (stack->top_is_empty()) {
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
      TypeSet target = stack->local(3);
      target.add_smi(program);  // We don't know the target, but we know we have one.
    }
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
    if (stack->top_is_empty()) return scope;                  \
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
    if (stack->top_is_empty()) return scope;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH);
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    return worklists.back()->add(target, scope, false);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_TRUE);
    TypeSet top = stack->local(0);
    bool can_be_falsy = top.can_be_falsy(program);
    bool can_be_truthy = top.can_be_truthy(program);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    if (!can_be_falsy) {
      // Unconditionally continue at the branch target.
      ASSERT(can_be_truthy);
      return worklists.back()->add(target, scope, false);
    }
    if (can_be_truthy) {
      scope = worklists.back()->add(target, scope, true);
      stack = scope->top();
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_FALSE);
    TypeSet top = stack->local(0);
    bool can_be_falsy = top.can_be_falsy(program);
    bool can_be_truthy = top.can_be_truthy(program);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    if (!can_be_truthy) {
      // Unconditionally continue at the branch target.
      ASSERT(can_be_falsy);
      return worklists.back()->add(target, scope, false);
    }
    if (can_be_falsy) {
      scope = worklists.back()->add(target, scope, true);
      stack = scope->top();
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK);
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    return worklists.back()->add(target, scope, false);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_TRUE);
    TypeSet top = stack->local(0);
    bool can_be_falsy = top.can_be_falsy(program);
    bool can_be_truthy = top.can_be_truthy(program);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    if (!can_be_falsy) {
      // Unconditionally continue at the branch target.
      ASSERT(can_be_truthy);
      return worklists.back()->add(target, scope, false);
    }
    if (can_be_truthy) {
      scope = worklists.back()->add(target, scope, true);
      stack = scope->top();
    }
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_FALSE);
    TypeSet top = stack->local(0);
    bool can_be_falsy = top.can_be_falsy(program);
    bool can_be_truthy = top.can_be_truthy(program);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    if (!can_be_truthy) {
      // Unconditionally continue at the branch target.
      ASSERT(can_be_falsy);
      return worklists.back()->add(target, scope, false);
    }
    if (can_be_falsy) {
      scope = worklists.back()->add(target, scope, true);
      stack = scope->top();
    }
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
    // For 'continue.label' the pushed block is the block from which the
    // non-local return should return.
    int level = stack->local(0).block()->level();
    stack->pop();  // Pop block.
    if (level == 0) {
      method->ret(propagator, stack);
    } else {
      // The worklists keep track of the blocks they correspond
      // to. The outermost worklist has a null block because it
      // corresponds to a method.
      BlockTemplate* block = worklists[level]->block();
      block->ret(propagator, stack);
    }
    scope->outer()->merge(scope, TypeScope::MERGE_UNWIND);
    return scope;
  OPCODE_END();

  OPCODE_BEGIN(NON_LOCAL_RETURN_WIDE);
    int level = stack->local(0).block()->level();
    stack->pop();  // Pop block.
    if (level == 0) {
      method->ret(propagator, stack);
    } else {
      BlockTemplate* block = worklists[level]->block();
      block->ret(propagator, stack);
    }
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
    // Find the right outer scope. The outer scope knows if it
    // is linked and it knows its own outer scope, so it has
    // the information necessary to continue analysis in the
    // outer method or block.
    int target_level = block.block()->level();
    TypeScope* outer = scope;
    while (outer->level() != target_level) outer = outer->outer();
    // Copy the scope using the computed outer scope as the target
    // and drop the top stack slots as indicated by the height
    // difference encoded in the bytecode.
    TypeScope* target_scope = scope->copy_lazy(outer);
    TypeStack* target_top = target_scope->top();
    for (int i = 0; i < height_diff; i++) target_top->pop();
    // Add the copied scope to the correct outer worklist. If we
    // already have a scope registered for the branch target, we
    // will merge into it and end up with a superfluous scope.
    // Otherwise, we will get null back.
    TypeScope* superfluous =
        worklists[target_level]->add(target_bcp, target_scope, false);
    delete superfluous;
    // We're done. Return the scope, so we can deallocate it.
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

bool MethodTemplate::matches(Method target, std::vector<ConcreteType>& arguments) const {
  if (target.entry() != method_.entry()) return false;
  return ConcreteType::equals(arguments_, arguments, false);
}

void MethodTemplate::collect_method(std::unordered_map<uint8*, std::vector<MethodTemplate*>>* map) {
  auto key = method_.header_bcp();
  auto probe = map->find(key);
  if (probe == map->end()) {
    std::vector<MethodTemplate*> methods;
    methods.push_back(this);
    (*map)[key] = methods;
  } else {
    std::vector<MethodTemplate*>& blocks = probe->second;
    blocks.push_back(this);
  }
}

void BlockTemplate::collect_block(std::unordered_map<uint8*, std::vector<BlockTemplate*>>* map) {
  if (!is_invoked_) return;
  auto key = method_.header_bcp();
  auto probe = map->find(key);
  if (probe == map->end()) {
    std::vector<BlockTemplate*> methods;
    methods.push_back(this);
    (*map)[key] = methods;
  } else {
    std::vector<BlockTemplate*>& blocks = probe->second;
    blocks.push_back(this);
  }
}

int MethodTemplate::method_id() const {
  return propagator_->program()->absolute_bci_from_bcp(method_.header_bcp());
}

void MethodTemplate::propagate() {
  TypeScope* scope = new TypeScope(this);
  TypeStack* stack = scope->top();
  analyzed_ = true;

  // Check that virtual methods are always called with a
  // concrete receiver type; not any.
  bool is_normal = method_.is_normal_method() ||
      method_.is_field_accessor();
  bool is_virtual = is_normal && method_.selector_offset() >= 0;
  if (is_virtual) {
    ASSERT(arguments_.size() >= 1);
    ConcreteType receiver = argument(0);
    ASSERT(!receiver.is_any());
    ASSERT(!receiver.is_block());
  }

  // We need to special case the 'operator ==' method, because the interpreter
  // does a manual null check on both arguments, which means that null never
  // flows into the method body. We have to simulate that.
  Program* program = propagator_->program();
  if (method_.selector_offset() == program->invoke_bytecode_offset(INVOKE_EQ)) {
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

  // If we're calling the special '__entry__task' method, we need to
  // take the specialized calling conventions for that particular
  // method into account. The method is entered after the first bytecode
  // and it expects that the stack looks like we just returned from a
  // call to 'task_transfer'.
  uint8* entry = method_.entry();
  if (entry == program->entry_task().entry()) {
    entry = method_.bcp_from_bci(LOAD_NULL_LENGTH);
    stack->push_instance(program->task_class_id()->value());
  }

  std::vector<Worklist*> worklists;
  Worklist worklist(entry, scope, null);
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

bool BlockTemplate::matches(Method target, MethodTemplate* user) const {
  if (target.entry() != method_.entry()) return false;
  return ConcreteType::equals(last_user_->arguments(), user->arguments(), true);
}

void BlockTemplate::use(TypePropagator* propagator, MethodTemplate* user) {
  if (!users_.insert(user)) return;
  for (int i = 1; i < method_.arity(); i++) {
    argument(i)->use(propagator, user, null);
  }
  last_user_ = user;
}

TypeSet BlockTemplate::invoke(TypePropagator* propagator, TypeScope* scope, uint8* site) {
  if (!is_invoked_) {
    // If this block is being invoked for the first time,
    // we mark it as 'invoked' and make sure to re-analyze
    // the surrounding method in all its variants.
    is_invoked_ = true;
    for (auto it : users_) propagator->enqueue(it);
  }
  if (scope->is_in_try_block()) {
    invoke_from_try_block();
  }
  return result_.use(propagator, scope->method(), site);
}

void BlockTemplate::invoke_from_try_block() {
  if (is_invoked_from_try_block_) return;
  // If we find that this block may have been invoked from
  // within a try-block, we re-analyze the surrounding
  // method, so we can track stores to outer locals that
  // may be visible because of caught exceptions or
  // stopped unwinding.
  is_invoked_from_try_block_ = true;
  for (auto it : users_) {
    it->propagator()->enqueue(it);
  }
}

void BlockTemplate::propagate(TypeScope* scope, std::vector<Worklist*>& worklists, bool linked) {
  // We avoid having empty types on the stack while we analyze
  // block methods by bailing out if this block hasn't been
  // invoked yet.
  if (!is_invoked_) return;

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

    ASSERT(level() == static_cast<int>(worklists.size()) - 1);
    Worklist worklist(method_.entry(), inner, this);
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
