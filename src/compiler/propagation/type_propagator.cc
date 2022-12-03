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
#include "type_primitive.h"
#include "type_scope.h"

#include "../../top.h"
#include "../../bytecodes.h"
#include "../../objects.h"
#include "../../program.h"
#include "../../interpreter.h"
#include "../../printing.h"

#include <sstream>

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

TypePropagator::TypePropagator(Program* program)
    : program_(program)
    , words_per_type_(TypeSet::words_per_type(program)) {
  TypePrimitive::set_up();
}

void TypePropagator::propagate() {
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
  stack.push_any();
  field(program()->exception_class_id()->value(), 0)->merge(this, stack.local(0));
  stack.pop();

  // Initialize Exception_.trace
  stack.push_byte_array(program(), true);
  field(program()->task_class_id()->value(), 1)->merge(this, stack.local(0));
  stack.pop();

  // TODO(kasper): Also teach the system about the type of the argument to
  // __entry__spawn. Only do this if we're actually spawning processes.
  std::vector<ConcreteType> main_arguments;
  main_arguments.push_back(ConcreteType(program()->task_class_id()->value()));
  MethodTemplate* entry = instantiate(program()->entry_main(), main_arguments);
  enqueue(entry);
  while (enqueued_.size() != 0) {
    MethodTemplate* last = enqueued_.back();
    enqueued_.pop_back();
    last->clear_enqueued();
    last->propagate();
  }

  stack.push_empty();
  TypeSet type = stack.get(0);

  std::stringstream out;
  out << "[\n";
  bool first = true;

  sites_.for_each([&](uint8* site, Set<TypeVariable*>& results) {
    type.clear(words_per_type());
    for (auto it = results.begin(); it != results.end(); it++) {
      type.add_all((*it)->type(), words_per_type());
    }
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }
    int position = program()->absolute_bci_from_bcp(site);
    std::string type_string = type.as_json(program());
    out << "  {\"position\": " << position;
    out << ", \"type\": " << type_string << "}";
  });

  std::unordered_map<uint8*, std::vector<BlockTemplate*>> blocks;
  for (auto it = templates_.begin(); it != templates_.end(); it++) {
    std::vector<MethodTemplate*>& templates = it->second;
    for (unsigned i = 0; i < templates.size(); i++) {
      templates[i]->collect_blocks(blocks);
    }

    if (first) {
      first = false;
    } else {
      out << ",\n";
    }

    MethodTemplate* method = templates[0];
    int position = method->method_id();
    out << "  {\"position\": " << position;
    out << ", \"arguments\": [";

    int arity = method->arity();
    for (int n = 0; n < arity; n++) {
      type.clear(words_per_type());
      for (unsigned i = 0; i < templates.size(); i++) {
        ConcreteType argument_type = templates[i]->argument(n);
        if (argument_type.is_block()) {
          break;
        } else if (argument_type.is_any()) {
          type.add_any(program());
          break;
        } else {
          type.add(argument_type.id());
        }
      }
      if (n != 0) {
        out << ",";
      }
      std::string type_string = type.as_json(program());
      out << type_string;
    }
    out << "]}";
  }

  for (auto it = blocks.begin(); it != blocks.end(); it++) {
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }
    std::vector<BlockTemplate*>& blocks = it->second;
    BlockTemplate* block = blocks[0];

    int position = block->method_id(program());
    out << "  {\"position\": " << position;
    out << ", \"arguments\": [\"[]\"";

    int arity = block->arity();
    for (int n = 1; n < arity; n++) {
      type.clear(words_per_type());
      for (unsigned i = 0; i < blocks.size(); i++) {
        TypeVariable* argument = blocks[i]->argument(n);
        type.add_all(argument->type(), words_per_type());
      }
      std::string type_string = type.as_json(program());
      out << "," << type_string;
    }
    out << "]}";
  }

  out << "\n]\n";
  printf("%s", out.str().c_str());
}

void TypePropagator::call_method(
    MethodTemplate* caller,
    TypeStack* stack,
    uint8* site,
    Method target,
    std::vector<ConcreteType>& arguments) {
  int arity = target.arity();
  int index = arguments.size();
  if (index == arity) {
    MethodTemplate* callee = find(target, arguments);
    TypeSet result = callee->call(this, caller, site);
    stack->merge_top(result);
    return;
  }

  // This is the heart of the Cartesian Product Algorithm (CPA). We
  // compute the cartesian product of all the argument types and
  // instantiate a method template for each possible combination. This
  // is essentially <arity> nested loops with a few cut-offs for blocks
  // and megamorphic types that tend to blow up the analysis.
  Program* program = this->program();
  TypeSet type = stack->local(arity - index);
  if (type.is_block()) {
    arguments.push_back(ConcreteType(type.block()));
    call_method(caller, stack, site, target, arguments);
    arguments.pop_back();
  } else if (type.size(program) > 5) {
    // If one of the arguments is megamorphic, we analyze the target
    // method with the any type for that argument instead. This cuts
    // down on the number of separate analysis at the cost of more
    // mixing of types and worse propagated types.
    arguments.push_back(ConcreteType::any());
    call_method(caller, stack, site, target, arguments);
    arguments.pop_back();
  } else {
    for (int id = 0; id < program->class_bits.length(); id++) {
      if (!type.contains(id)) continue;
      arguments.push_back(ConcreteType(id));
      call_method(caller, stack, site, target, arguments);
      arguments.pop_back();
    }
  }
}

void TypePropagator::call_static(MethodTemplate* caller, TypeStack* stack, uint8* site, Method target) {
  std::vector<ConcreteType> arguments;
  stack->push_empty();
  call_method(caller, stack, site, target, arguments);
  stack->drop_arguments(target.arity());
}

void TypePropagator::call_virtual(MethodTemplate* caller, TypeStack* stack, uint8* site, int arity, int offset) {
  TypeSet receiver = stack->local(arity - 1);

  std::vector<ConcreteType> arguments;
  stack->push_empty();

  Program* program = this->program();
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!receiver.contains(id)) continue;
    int entry_index = id + offset;
    int entry_id = program->dispatch_table[entry_index];
    if (entry_id == -1) continue;
    Method target(program->bytecodes, entry_id);
    if (target.selector_offset() != offset) continue;
    arguments.push_back(ConcreteType(id));
    call_method(caller, stack, site, target, arguments);
    arguments.pop_back();
  }

  stack->drop_arguments(arity);
}

void TypePropagator::load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index) {
  TypeSet instance = stack->local(0);
  stack->push_empty();

  Program* program = this->program();
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!instance.contains(id)) continue;
    TypeSet result = field(id, index)->use(this, user, site);
    stack->merge_top(result);
  }

  stack->drop_arguments(1);
}

void TypePropagator::store_field(MethodTemplate* user, TypeStack* stack, int index) {
  TypeSet value = stack->local(0);
  TypeSet instance = stack->local(1);

  Program* program = this->program();
  for (int id = 0; id < program->class_bits.length(); id++) {
    if (!instance.contains(id)) continue;
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
  // this particular access site. We use this to exclusively
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

// TODO(kasper): Poor name.
struct WorkItem {
  uint8* bcp;
  TypeScope* scope;
};

class Worklist {
 public:
  Worklist(uint8* entry, TypeScope* scope) {
    // TODO(kasper): We should be able to get away
    // with not copying the initial scope at all and
    // just use it as the working scope.
    scopes_[entry] = scope;
    unprocessed_.push_back(entry);
  }

  void add(uint8* bcp, TypeScope* scope) {
    auto it = scopes_.find(bcp);
    if (it == scopes_.end()) {
      // Make a full copy of the scope so we can use it
      // to collect merged types from all the different
      // paths that can end up in here.
      scopes_[bcp] = scope->copy();
      unprocessed_.push_back(bcp);
    } else {
      TypeScope* existing = it->second;
      if (existing->merge(scope)) {
        unprocessed_.push_back(bcp);
      }
    }
  }

  bool has_next() const {
    return !unprocessed_.empty();
  }

  WorkItem next() {
    uint8* bcp = unprocessed_.back();
    unprocessed_.pop_back();
    return WorkItem {
      .bcp = bcp,
      // The working scope is copied lazily.
      .scope = scopes_[bcp]->copy_lazily()
    };
  }

  ~Worklist() {
    for (auto it = scopes_.begin(); it != scopes_.end(); it++) {
      delete it->second;
    }
  }

 private:
  std::vector<uint8*> unprocessed_;
  std::unordered_map<uint8*, TypeScope*> scopes_;
};

// Propagates the type stack starting at the given bcp in this method context.
// The bcp could be the beginning of the method, a block entry, a branch target, ...
static void process(MethodTemplate* method, uint8* bcp, TypeScope* scope, Worklist& worklist) {
#define LABEL(opcode, length, format, print) &&interpret_##opcode,
  static void* dispatch_table[] = {
    BYTECODES(LABEL)
  };
#undef LABEL

  bool linked = false;
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
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field_index = encoded >> 4;
    TypeSet instance = stack->local(local);
    stack->push(instance);
    propagator->load_field(method, stack, bcp, field_index);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(POP_LOAD_FIELD_LOCAL);
    B_ARG1(encoded);
    int local = encoded & 0x0f;
    int field_index = encoded >> 4;
    TypeSet instance = stack->local(local + 1);
    stack->set_local(0, instance);
    propagator->load_field(method, stack, bcp, field_index);
    if (stack->local(0).is_empty(program)) return;
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

  OPCODE_BEGIN(LOAD_BLOCK_METHOD);
    Method inner = Method(program->bytecodes, Utils::read_unaligned_uint32(bcp + 1));
    // Finds or creates a block-template for the given block.
    // The block's parameters are marked such that a change in their type enqueues this
    // current method template.
    // Note that the method template is for a specific combination of parameter types. As
    // such we evaluate the contained blocks independently too.
    BlockTemplate* block = method->find_block(inner, scope->level(), bcp);
    stack->push_block(block);
    block->propagate(method, scope);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, index);
    TypeVariable* variable = propagator->global_variable(index);
    stack->push(variable->use(propagator, method, bcp));
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(LOAD_GLOBAL_VAR_DYNAMIC);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR_LAZY, index);
    Instance* initializer = Instance::cast(program->global_variables.at(index));
    int method_id = Smi::cast(initializer->at(0))->value();
    Method target(program->bytecodes, method_id);
    propagator->call_static(method, stack, bcp, target);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(STORE_GLOBAL_VAR, index);
    TypeVariable* variable = propagator->global_variable(index);
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
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      // TODO(kasper): We may also need to merge on throws and
      // non-local returns.
      scope->outer()->merge(scope);
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
      // Merge the argument-type.
      // If the type changed, queues the block's surrounding method.
      block->argument(i)->merge(propagator, argument);
    }
    for (int i = 0; i < index; i++) stack->pop();
    // If the return type of this block changes, enqueue the surrounding
    // method again.
    TypeSet value = block->use(propagator, method, bcp);
    if (value.is_empty(program)) {
      if (!linked) return;
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
      TypeSet reason = stack->local(1);
      reason.add_smi(program);  // TODO(kasper): Should this be something better?
    }
    stack->push(value);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_INITIALIZER_TAIL);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(INVOKE_VIRTUAL, arity);
    int offset = Utils::read_unaligned_uint16(bcp + 2);
    propagator->call_virtual(method, stack, bcp, arity + 1, offset);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_GET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, stack, bcp, 1, offset);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_VIRTUAL_SET);
    int offset = Utils::read_unaligned_uint16(bcp + 1);
    propagator->call_virtual(method, stack, bcp, 2, offset);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

#define INVOKE_VIRTUAL_BINARY(opcode)                         \
  OPCODE_BEGIN(opcode);                                       \
    int offset = program->invoke_bytecode_offset(opcode);     \
    propagator->call_virtual(method, stack, bcp, 2, offset);  \
    if (stack->local(0).is_empty(program)) return;            \
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
    worklist.add(target, scope);
    return;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_TRUE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, scope);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_IF_FALSE);
    stack->pop();
    uint8* target = bcp + Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, scope);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK);
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, scope);
    return;
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_TRUE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, scope);
  OPCODE_END();

  OPCODE_BEGIN(BRANCH_BACK_IF_FALSE);
    stack->pop();
    uint8* target = bcp - Utils::read_unaligned_uint16(bcp + 1);
    worklist.add(target, scope);
  OPCODE_END();

  OPCODE_BEGIN(INVOKE_LAMBDA_TAIL);
    UNIMPLEMENTED();
  OPCODE_END();

  OPCODE_BEGIN(PRIMITIVE);
    B_ARG1(primitive_module);
    unsigned primitive_index = Utils::read_unaligned_uint16(bcp + 2);
    const TypePrimitiveEntry* primitive = TypePrimitive::at(primitive_module, primitive_index);
    if (primitive == null) return;
    TypePrimitive::Entry* entry = reinterpret_cast<TypePrimitive::Entry*>(primitive->function);
    stack->push_empty();
    stack->push_empty();
    entry(program, stack->local(0), stack->local(1));
    method->ret(propagator, stack);
    if (stack->local(0).is_empty(program)) return;
  OPCODE_END();

  OPCODE_BEGIN(THROW);
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN);
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      // TODO(kasper): We may also need to merge on throws and
      // non-local returns.
      scope->outer()->merge(scope);
    } else {
      method->ret(propagator, stack);
    }
    return;
  OPCODE_END();

  OPCODE_BEGIN(RETURN_NULL);
    stack->push_null(program);
    if (scope->level() > 0) {
      TypeSet receiver = stack->get(0);
      BlockTemplate* block = receiver.block();
      block->ret(propagator, stack);
      // TODO(kasper): We may also need to merge on throws and
      // non-local returns.
      scope->outer()->merge(scope);
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

  OPCODE_BEGIN(IDENTICAL);
    stack->pop();
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    stack->push_instance(program->exception_class_id()->value());
    stack->push_empty();       // Unwind target.
    stack->push_empty();       // Unwind reason.
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
    TypeSet reason = stack->local(0);
    bool unwind = !reason.is_empty(program);
    if (unwind) return;
    stack->pop();
    stack->pop();
    stack->pop();
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

BlockTemplate* MethodTemplate::find_block(Method method, int level, uint8* site) {
  auto it = blocks_.find(site);
  if (it == blocks_.end()) {
    BlockTemplate* block = new BlockTemplate(method, level, propagator_->words_per_type());
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

  Worklist worklist(method_.entry(), scope);
  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    process(this, item.bcp, item.scope, worklist);
    delete item.scope;
  }
}

int BlockTemplate::method_id(Program* program) const {
  return program->absolute_bci_from_bcp(method_.header_bcp());
}

void BlockTemplate::propagate(MethodTemplate* context, TypeScope* scope) {
  TypeScope* inner = new TypeScope(this, scope);

  Worklist worklist(method_.entry(), inner);
  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    process(context, item.bcp, item.scope, worklist);
    delete item.scope;
  }
}

} // namespace toit::compiler
} // namespace toit
