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
  TypeStack* stack = new TypeStack(-1, 1, words_per_type());

  // Initialize the types of pre-initialized global variables.
  for (int i = 0; i < program()->global_variables.length(); i++) {
    Object* value = program()->global_variables.at(i);
    if (is_instance(value)) {
      Instance* instance = Instance::cast(value);
      if (instance->class_id() == program()->lazy_initializer_class_id()) continue;
    }
    stack->push(program(), value);
    global_variable(i)->merge(this, stack->local(0));
    stack->pop();
  }

  // Initialize the fields of Task_. We allocate instances of these in
  // the VM, so we need to make sure the type propagator knows about the
  // types we store in the fields.
  int task_fields = program()->instance_size_for(program()->task_class_id());
  for (int i = 0; i < task_fields; i++) {
    if (i == Task::STACK_INDEX) {
      continue;  // Skip the 'stack' field.
    } else if (i == Task::ID_INDEX) {
      stack->push_smi(program());
    } else {
      stack->push_null(program());
    }
    field(program()->task_class_id()->value(), i)->merge(this, stack->local(0));
    stack->pop();
  }

  // Initialize Exception_.value
  ASSERT(program()->instance_fields_for(program()->exception_class_id()) == 2);
  stack->push_any();
  field(program()->exception_class_id()->value(), 0)->merge(this, stack->local(0));
  stack->pop();

  // Initialize Exception_.trace
  stack->push_byte_array(program(), true);
  field(program()->task_class_id()->value(), 1)->merge(this, stack->local(0));
  stack->pop();

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

  std::stringstream out;
  out << "[\n";
  TypeSet type = stack->get(0);
  bool first = true;

  sites_.for_each([&](uint8* site, Set<TypeResult*>& results) {
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
          type.fill(words_per_type());
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
        TypeResult* argument = blocks[i]->argument(n);
        type.add_all(argument->type(), words_per_type());
      }
      std::string type_string = type.as_json(program());
      out << "," << type_string;
    }
    out << "]}";
  }

  out << "\n]\n";
  printf("%s", out.str().c_str());
  delete stack;
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

  Program* program = this->program();
  TypeSet type = stack->local(arity - index);
  if (type.is_block()) {
    arguments.push_back(ConcreteType(type.block()));
    call_method(caller, stack, site, target, arguments);
    arguments.pop_back();
  } else if (type.size(program) > 5) {
    arguments.push_back(ConcreteType());
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

void TypePropagator::load_outer(TypeStack* stack, uint8* site, int index) {
  TypeSet block = stack->local(0);
  TypeStack* outer = stack->outer();
  int n = outer->level() - block.block()->level();
  for (int i = 0; i < n; i++) outer = outer->outer();
  TypeSet value = outer->local(index);
  stack->pop();
  stack->push(value);
  if (value.is_block()) return;
  TypeResult* merged = this->outer(site);
  merged->merge(this, value);
}

TypeResult* TypePropagator::field(unsigned type, int index) {
  auto it = fields_.find(type);
  std::unordered_map<int, TypeResult*>& map = (it == fields_.end())
      ? (fields_[type] = std::unordered_map<int, TypeResult*>())
      : it->second;
  auto itx = map.find(index);
  if (itx == map.end()) {
    TypeResult* variable = new TypeResult(words_per_type());
    map[index] = variable;
    return variable;
  } else {
    return itx->second;
  }
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

TypeResult* TypePropagator::outer(uint8* site) {
  auto it = outers_.find(site);
  if (it == outers_.end()) {
    TypeResult* variable = new TypeResult(words_per_type());
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

void TypePropagator::add_site(uint8* site, TypeResult* result) {
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

TypeSet TypeResult::use(TypePropagator* propagator, MethodTemplate* user, uint8* site) {
  if (site) propagator->add_site(site, this);
  users_.insert(user);
  return type();
}

bool TypeResult::merge(TypePropagator* propagator, TypeSet other) {
  if (!type_.add_all(other, words_per_type_)) return false;
  for (auto it = users_.begin(); it != users_.end(); it++) {
    propagator->enqueue(*it);
  }
  return true;
}

bool TypeStack::merge(TypeStack* other) {
  ASSERT(sp() == other->sp());
  bool result = false;
  for (int i = 0; i <= sp_; i++) {
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

void TypeStack::push_byte_array(Program* program, bool nullable) {
  TypeSet type = push_empty();
  type.add(program->byte_array_class_id()->value());
  if (nullable) type.add(program->null_class_id()->value());
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
    uint8* bcp = unprocessed_.back();
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
    propagator->load_outer(stack, bcp, stack_offset);
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
    BlockTemplate* block = method->find_block(inner, stack->level(), bcp);
    stack->push_block(block);
    block->propagate(method, stack);
  OPCODE_END();

  OPCODE_BEGIN_WITH_WIDE(LOAD_GLOBAL_VAR, index);
    TypeResult* variable = propagator->global_variable(index);
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
    propagator->load_outer(stack, bcp, stack_offset);
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
    TypeSet value = block->use(propagator, method, bcp);
    if (value.is_empty(program)) return;
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

  OPCODE_BEGIN(IDENTICAL);
    stack->pop();
    stack->pop();
    stack->push_bool(program);
  OPCODE_END();

  OPCODE_BEGIN(LINK);
    stack->push_instance(program->exception_class_id()->value());
    stack->push_empty();       // Unwind target.
    stack->push_smi(program);  // Unwind reason.
    stack->push_smi(program);  // Unwind chain next.
  OPCODE_END();

  OPCODE_BEGIN(UNLINK);
    stack->pop();
  OPCODE_END();

  OPCODE_BEGIN(UNWIND);
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
  int words_per_type = propagator_->words_per_type();
  int sp = method_.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method_.max_height() + 1, words_per_type);
  stack->seed_arguments(arguments_);

  Worklist worklist(method_.entry(), stack);
  while (worklist.has_next()) {
    WorkItem item = worklist.next();
    process(this, item.bcp, item.stack, worklist);
    delete item.stack;
  }
}

int BlockTemplate::method_id(Program* program) const {
  return program->absolute_bci_from_bcp(method_.header_bcp());
}

void BlockTemplate::propagate(MethodTemplate* context, TypeStack* outer) {
  int words_per_type = context->propagator()->words_per_type();
  int sp = method_.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method_.max_height() + 1, words_per_type);
  for (int i = 1; i < method_.arity(); i++) {
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
    process(context, item.bcp, item.stack, worklist);
    delete item.stack;
  }

  outer->merge(outer_copy);
  delete outer_copy;
}

} // namespace toit::compiler
} // namespace toit
