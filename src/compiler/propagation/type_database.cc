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

#include "type_database.h"
#include "type_propagator.h"
#include "type_stack.h"

#include "../source_mapper.h"

#include <sstream>

namespace toit {
namespace compiler {

#define BYTECODE_LENGTH(name, length, format, print) length,
static int opcode_length[] { BYTECODES(BYTECODE_LENGTH) -1 };
#undef BYTECODE_LENGTH

static const int TYPES_BLOCK_SIZE = 1024;
std::unordered_map<Program*, TypeDatabase*> TypeDatabase::cache_;

TypeDatabase::TypeDatabase(Program* program, int words_per_type)
    : program_(program)
    , words_per_type_(words_per_type) {
  add_types_block();
}

TypeDatabase::~TypeDatabase() {
  for (auto it : types_) {
    delete it;
  }
}

void TypeDatabase::check_top(uint8* bcp, Object* value) const {
  int position = program_->absolute_bci_from_bcp(bcp);
  auto probe = usage_.find(position);
  if (probe == usage_.end()) {
    FATAL("usage not analyzed: %d", position);
  }
  TypeSet type = probe->second;
  if (type.is_block()) {
    // TODO(kasper): We should improve the type check
    // for blocks and verify that they point into the
    // right stack section.
    if (is_smi(value)) return;
    FATAL("expected a block at %d", position);
  }
  Smi* class_id = is_smi(value)
      ? program_->smi_class_id()
      : HeapObject::cast(value)->class_id();
  if (type.contains(class_id->value())) return;
  FATAL("didn't expect %d at %d", class_id->value(), position);
}

void TypeDatabase::check_return(uint8* bcp, Object* value) const {
  // TODO(kasper): This isn't super nice, but we have to avoid
  // getting hung up over the intrinsic bytecodes. We sometimes
  // return from a block and restart at the intrinsic bytecode,
  // but we don't care about that for now. We could make the
  // propagator allow any value as the top stack element here,
  // but it would achieve the same things as this check.
  uint8 opcode = *bcp;
  if (opcode > HALT) return;

  int position = program_->absolute_bci_from_bcp(bcp);
  auto probe = returns_.find(position);
  if (probe == returns_.end()) {
    FATAL("return site not analyzed: %d", position);
  }
  TypeSet type = probe->second;
  if (type.is_block()) {
    // TODO(kasper): We should improve the type check
    // for blocks and verify that they point into the
    // right stack section.
    if (is_smi(value)) return;
    FATAL("expected a block at %d", position);
  }
  Smi* class_id = is_smi(value)
      ? program_->smi_class_id()
      : HeapObject::cast(value)->class_id();
  if (type.contains(class_id->value())) return;
  FATAL("didn't expect %d at %d", class_id->value(), position);
}

void TypeDatabase::check_method_entry(Method method, Object** sp) const {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  auto probe = methods_.find(position);
  if (probe == methods_.end()) {
    FATAL("method not analyzed: %d", position);
  }
  TypeStack* stack = probe->second;
  for (int i = 0; i < method.arity(); i++) {
    TypeSet type = stack->get(i);
    Object* argument = sp[1 + (method.arity() - i)];
    if (type.is_block()) {
      // TODO(kasper): We should improve the type check
      // for blocks and verify that they point into the
      // right stack section.
      if (is_smi(argument)) continue;
      FATAL("method expected a block at %d: %d", i, position);
    }
    Smi* class_id = is_smi(argument)
        ? program_->smi_class_id()
        : HeapObject::cast(argument)->class_id();
    if (type.contains(class_id->value())) continue;
    FATAL("method has wrong argument type %d @ %d: %d", class_id->value(), i, position);
  }
}

TypeDatabase* TypeDatabase::compute(Program* program) {
  auto probe = cache_.find(program);
  if (probe != cache_.end()) return probe->second;

  AllowThrowingNew allow;
  uint64 start = OS::get_monotonic_time();
  TypePropagator propagator(program);
  TypeDatabase* types = new TypeDatabase(program, propagator.words_per_type());
  propagator.propagate(types);
  uint64 elapsed = OS::get_monotonic_time() - start;
  if (false) {
    printf("[propagating types through program %p => %lld ms]\n",
        program, elapsed / 1000);
  }
  cache_[program] = types;
  return types;
}

const std::vector<Method> TypeDatabase::methods() const {
  std::vector<Method> result;
  for (auto it : methods_) {
    Method method(program_->bcp_from_absolute_bci(it.first));
    result.push_back(method);
  }
  return result;
}

const std::vector<TypeSet> TypeDatabase::arguments(Method method) const {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  std::vector<TypeSet> result;
  auto probe = methods_.find(position);
  if (probe != methods_.end()) {
    TypeStack* arguments = probe->second;
    for (int i = 0; i < method.arity(); i++) {
      result.push_back(arguments->get(i));
    }
  }
  return result;
}

const TypeSet TypeDatabase::usage(int position) const {
  auto probe = usage_.find(position);
  if (probe == usage_.end()) {
    return TypeSet::invalid();
  } else {
    return probe->second;
  }
}

bool TypeDatabase::is_dead_method(int position) const {
  ASSERT(position >= 0);
  auto probe = methods_.find(position);
  return probe == methods_.end();
}

bool TypeDatabase::is_dead_call(int position) const {
  ASSERT(position >= 0);
  auto probe = returns_.find(position);
  return probe == returns_.end();
}

bool TypeDatabase::does_not_return(int position) const {
  ASSERT(position >= 0);
  auto probe = returns_.find(position);
  if (probe == returns_.end()) return true;
  TypeSet type = probe->second;
  return type.is_empty(words_per_type_);
}

bool TypeDatabase::always_throws(int position) const {
  ASSERT(position >= 0);
  auto probe = returns_.find(position);
  if (probe == returns_.end()) return true;
  TypeSet type = probe->second;
  return !type.contains_true(program_);
}

bool TypeDatabase::never_throws(int position) const {
  ASSERT(position >= 0);
  auto probe = returns_.find(position);
  if (probe == returns_.end()) return false;
  TypeSet type = probe->second;
  return !type.contains_false(program_);
}

std::string TypeDatabase::as_json() const {
  std::stringstream out;
  out << "[\n";

  bool first = true;
  for (auto it : usage_) {
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }
    std::string type_string = it.second.as_json(program_);
    out << "  {\"position\": " << it.first;
    out << ", \"type\": " << type_string << "}";
  }

  for (auto it : methods_) {
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }

    int position = it.first;
    out << "  {\"position\": " << it.first;
    out << ", \"arguments\": [";

    Method method(program_->bcp_from_absolute_bci(position));
    int arity = method.arity();
    TypeStack* arguments = it.second;
    for (int i = 0; i < arity; i++) {
      if (i != 0) {
        out << ",";
      }
      TypeSet type = arguments->get(i);
      std::string type_string = type.as_json(program_);
      out << type_string;
    }
    out << "]}";
  }

  out << "\n]\n";
  return out.str();
}

void TypeDatabase::add_method(Method method) {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  ASSERT(methods_.find(position) == methods_.end());
  methods_[position] = new TypeStack(method.arity() - 1, method.arity(), words_per_type_);
}

void TypeDatabase::add_argument(Method method, int n, const TypeSet type) {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  auto probe = methods_.find(position);
  ASSERT(probe != methods_.end());
  TypeStack* arguments = probe->second;
  arguments->set(n, type);
}

void TypeDatabase::add_usage(int position, const TypeSet type) {
  ASSERT(usage_.find(position) == usage_.end());
  TypeSet copy = copy_type(type);
  uint8 opcode = *(program_->bcp_from_absolute_bci(position));
  usage_.emplace(position, copy);
  returns_.emplace(position + opcode_length[opcode], copy);
}

TypeSet TypeDatabase::copy_type(const TypeSet type) {
  TypeStack* stack = types_.back();
  if (stack->available() == 0) stack = add_types_block();
  stack->push(type);
  return stack->local(0);
}

TypeStack* TypeDatabase::add_types_block() {
  TypeStack* stack = new TypeStack(-1, TYPES_BLOCK_SIZE, words_per_type_);
  types_.push_back(stack);
  return stack;
}

class TypeOraclePopulator : public ir::TraversingVisitor {
 public:
  explicit TypeOraclePopulator(TypeOracle* oracle)
      : oracle_(oracle) {}

  void visit_Method(ir::Method* node) {
    ir::TraversingVisitor::visit_Method(node);
    oracle_->add(node);
  }

  void visit_Code(ir::Code* node) {
    ir::TraversingVisitor::visit_Code(node);
    oracle_->add(node);
  }

  void visit_Call(ir::Call* node) {
    ir::TraversingVisitor::visit_Call(node);
    oracle_->add(node);
  }

  void visit_Typecheck(ir::Typecheck* node) {
    ir::TraversingVisitor::visit_Typecheck(node);
    oracle_->add(node);
  }

 private:
  TypeOracle* const oracle_;
};

void TypeOracle::seed(ir::Program* program) {
  ASSERT(types_ == null);
  TypeOraclePopulator populator(this);
  program->accept(&populator);
}

void TypeOracle::finalize(ir::Program* program, TypeDatabase* types) {
  types_ = types;
  TypeOraclePopulator populator(this);
  program->accept(&populator);
  ASSERT(nodes_.size() == map_.size());
}

void TypeOracle::add(ir::Node* node) {
  if (types_ == null) {
    nodes_.push_back(node);
  } else {
    int index = map_.size();
    ir::Node* existing = nodes_[index];
    map_[node] = existing;
    ASSERT(strcmp(node->node_type(), existing->node_type()) == 0);
    ASSERT(!node->is_Method() || node->as_Method()->range() == existing->as_Method()->range());
    ASSERT(!node->is_Expression() || node->as_Expression()->range() == existing->as_Expression()->range());
  }
}

ir::Node* TypeOracle::lookup(ir::Node* node) const {
  if (types_ == null) return null;
  auto probe = map_.find(node);
  if (probe == map_.end()) return null;
  return probe->second;
}

bool TypeOracle::is_dead(ir::Method* method) const {
  if (method->is_IsInterfaceStub()) return false;
  auto probe = lookup(method);
  if (!probe) return false;
  int position = source_mapper_->position_for_method(probe->as_Method());
  return types_->is_dead_method(position);
}

bool TypeOracle::is_dead(ir::Code* code) const {
  auto probe = lookup(code);
  if (!probe) return false;
  int position = source_mapper_->position_for_method(probe->as_Code());
  return types_->is_dead_method(position);
}

bool TypeOracle::is_dead(ir::Call* call) const {
  auto probe = lookup(call);
  if (!probe) return false;
  int position = source_mapper_->position_for_expression(probe->as_Call());
  return types_->is_dead_call(position);
}

bool TypeOracle::does_not_return(ir::Call* call) const {
  auto probe = lookup(call);
  if (!probe) return false;
  int position = source_mapper_->position_for_expression(probe->as_Call());
  return types_->does_not_return(position);
}

bool TypeOracle::always_throws(ir::Typecheck* check) const {
  auto probe = lookup(check);
  if (!probe) return false;
  int position = source_mapper_->position_for_expression(probe->as_Typecheck());
  return types_->always_throws(position);
}

bool TypeOracle::never_throws(ir::Typecheck* check) const {
  auto probe = lookup(check);
  if (!probe) return false;
  int position = source_mapper_->position_for_expression(probe->as_Typecheck());
  return types_->never_throws(position);
}

} // namespace toit::compiler
} // namespace toit
