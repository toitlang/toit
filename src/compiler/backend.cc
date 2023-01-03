// Copyright (C) 2019 Toitware ApS.
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

#include <algorithm>

#include "backend.h"
#include "byte_gen.h"
#include "ir.h"
#include "program_builder.h"
#include "source_mapper.h"

#include "../interpreter.h"

namespace toit {
namespace compiler {

static void set_entry_points(List<ir::Method*> entry_points,
                             DispatchTable* dispatch_table,
                             ProgramBuilder* program_builder) {
  int i = 0;
#define E(n, lib_name, a) \
  program_builder->set_entry_point_index(i, dispatch_table->slot_index_for(entry_points[i])); \
  i++;
ENTRY_POINTS(E)
#undef E
}

class BackendCollector : public ir::TraversingVisitor {
 public:
  explicit BackendCollector(DispatchTable* dispatch_table)
      : dispatch_table_(dispatch_table) {}

  void visit_Code(ir::Code* node) {
    TraversingVisitor::visit_Code(node);
    max_captured_count_ = std::max(max_captured_count_, node->captured_count());
  }

  void visit_Typecheck(ir::Typecheck* node) {
    TraversingVisitor::visit_Typecheck(node);
    if (node->type().is_class()) {
      auto klass = node->type().klass();
      if (klass->is_interface()) {
        interface_usage_counts_[klass]++;
      } else {
        class_usage_counts_[klass]++;
      }
    }
  }

  void visit_CallStatic(ir::CallStatic* node) {
    TraversingVisitor::visit_CallStatic(node);
    // Some static calls target virtual methods. Some of those
    // virtual methods are never called using a virtual call, so
    // they only have a single entry in the dispatch table and
    // no selector offset. For those methods, we still would like
    // to know the set of classes that the method can
    // be called on (the holder and all subclasses), so we extend
    // the class check table to hold entries for them at the end.
    ir::Method* method = node->target()->target();
    if (method->is_static()) return;
    // Check if the dispatch table has an offset for the selector.
    // If so, the method is already in a fitted row and we don't
    // need to handle it here.
    Selector<PlainShape> selector(method->name(), method->plain_shape());
    if (dispatch_table_->dispatch_offset_for(selector) >= 0) return;
    // Make sure we get a class check table entry for the holder.
    ir::Class* holder = method->holder();
    if (class_usage_counts_.contains_key(holder)) return;
    class_usage_counts_[holder] = 0;
  }

  int max_captured_count() const { return max_captured_count_; }

  /// Returns a list of all classes that were used in typechecks.
  /// The result is sorted by usage-count, most-used first.
  List<ir::Class*> compute_sorted_typecheck_classes() {
    return to_sorted_list(class_usage_counts_);
  }

  /// Returns a list of all interfaces that were used in typechecks.
  /// The result is sorted by usage-count, most-used first.
  List<ir::Class*> compute_sorted_typecheck_interfaces() {
    return to_sorted_list(interface_usage_counts_);
  }

 private:
  DispatchTable* const dispatch_table_;
  int max_captured_count_ = 0;

  Map<ir::Class*, int> class_usage_counts_;
  Map<ir::Class*, int> interface_usage_counts_;

  List<ir::Class*> to_sorted_list(Map<ir::Class*, int>& counts) {
    std::vector<std::pair<ir::Class*, int>> sorted;
    sorted.reserve(counts.size());
    for (auto key : counts.keys()) {
      sorted.push_back(*counts.find(key));
    }
    std::sort(sorted.begin(), sorted.end(), [&](std::pair<ir::Class*, int> a,
                                                std::pair<ir::Class*, int> b) {
      // To make sure we always have a deterministic order, we must
      // handle the case where two entries have the same usage count.
      // We use the source position of the class or interface as the
      // tie breaker, because not everything that flows in here will
      // have an assigned id we can use.
      return a.second == b.second
          ? a.first->range().is_before(b.first->range())
          : a.second > b.second;
    });
    auto result = ListBuilder<ir::Class*>::allocate(sorted.size());
    int index = 0;
    for (auto p : sorted) {
      result[index++] = p.first;
    }
    return result;
  }
};

static List<uint16> encode_typecheck_class_list(const List<ir::Class*> classes) {
  auto result = ListBuilder<uint16>::allocate(classes.length() * 2);
  for (int i = 0; i < classes.length(); i++) {
    auto klass = classes[i];
    result[2 * i] = klass->start_id();
    result[2 * i + 1] = klass->end_id();
  }
  return result;
}

static List<uint16> encode_typecheck_interface_list(const List<ir::Class*> interfaces,
                                                    DispatchTable& dispatch_table) {
  auto result = ListBuilder<uint16>::allocate(interfaces.length());
  for (int i = 0; i < interfaces.length(); i++) {
    auto call_selector = interfaces[i]->typecheck_selector();
    ASSERT(call_selector.is_valid());
    Selector<PlainShape> selector(call_selector.name(), call_selector.shape().to_plain_shape());
    int16 offset = dispatch_table.dispatch_offset_for(selector);
    // We would have already replaced the interface call with a literal false if there
    //  wasn't any class implementing the interface.
    ASSERT(offset >= 0);
    result[i] = offset;
  }
  return result;
}

Program* Backend::emit(ir::Program* ir_program) {
  // Compile everything.

  auto classes = ir_program->classes();
  auto methods = ir_program->methods();
  auto globals = ir_program->globals();
  auto lookup_failure = ir_program->lookup_failure();

  DispatchTable dispatch_table = DispatchTable::build(ir_program);

  dispatch_table.for_each_selector_offset([&](DispatchSelector selector, int offset) {
    source_mapper()->register_selector_offset(offset, selector.name().c_str());
  });

  auto program = _new Program(null, 0);
  ProgramBuilder program_builder(program);
  program_builder.create_dispatch_table(dispatch_table.length());

  // Find the classes and interfaces for which we have a shortcut when doing as-checks.
  BackendCollector collector(&dispatch_table);
  collector.visit(ir_program);
  int max_captured_count = collector.max_captured_count();
  // Get the sorted classes and interface selectors.
  // We sort them by usage count, so that we can use the lowest indexes for the most
  //   frequently used classes/interfaces. This means that most indexes will fit into one
  //   byte and thus not require an `Extend` bytecode.
  auto checked_classes = collector.compute_sorted_typecheck_classes();
  auto checked_interface_selectors = collector.compute_sorted_typecheck_interfaces();
  program_builder.set_class_check_ids(encode_typecheck_class_list(checked_classes));
  program_builder.set_interface_check_offsets(encode_typecheck_interface_list(checked_interface_selectors, dispatch_table));

  UnorderedMap<ir::Class*, int> typecheck_indexes;
  for (int i = 0; i < checked_classes.length(); i++) {
    typecheck_indexes[checked_classes[i]] = i;
  }
  for (int i = 0; i < checked_interface_selectors.length(); i++) {
    typecheck_indexes[checked_interface_selectors[i]] = i;
  }

  int instantiated_classes_count = 0;
  for (auto klass : classes) {
    if (klass->is_instantiated()) instantiated_classes_count++;
  }

  program_builder.create_class_bits_table(instantiated_classes_count);
  int uninstantiated_id = instantiated_classes_count;
  for (auto klass : classes) {
    if (!klass->is_instantiated()) continue;
    emit_class(klass, &dispatch_table, source_mapper(), &program_builder);
  }
  // Initialize base objects.
  program_builder.set_up_skeleton_program();

  // We need two loops, so that the entries are added in order to the source-mapper.
  for (auto klass : classes) {
    if (klass->is_instantiated()) continue;
    // Don't compile the class, but add it to the source_mapper.
    source_mapper()->add_class_entry(uninstantiated_id++, klass);
  }

  ByteGen gen(lookup_failure,
              max_captured_count,
              &dispatch_table,
              &typecheck_indexes,
              source_mapper(),
              &program_builder);

  for (int i = 0; i < globals.length(); i++) {
    auto global = globals[i];
    ASSERT(global->global_id() == i);
    source_mapper()->add_global_entry(global);
    emit_global(global, &gen, &program_builder);
  }
  program_builder.create_global_variables(globals.length());

  for (auto method : methods) {
    emit_method(method, &gen, &typecheck_indexes, &dispatch_table, &program_builder);
  }

  for (auto klass : classes) {
    for (auto method : klass->methods()) {
      emit_method(method, &gen, &typecheck_indexes, &dispatch_table, &program_builder);
    }
  }

  // TODO(kasper): Move this elsewhere? Compute dispatch table offsets for
  // all the optimized virtual invoke bytecodes, so we can use them in case
  // we need to branch to the generic virtual invoke handling in the interpreter.
  for (int i = INVOKE_EQ; i <= INVOKE_AT_PUT; i++) {
    Opcode opcode = static_cast<Opcode>(i);
    int arity = (opcode == INVOKE_AT_PUT) ? 3 : 2;
    CallShape shape(arity, 0);  // No blocks.
    Symbol name = Symbol::for_invoke(opcode);
    Selector<PlainShape> selector(name, shape.to_plain_shape());
    int offset = dispatch_table.dispatch_offset_for(selector);
    program_builder.set_invoke_bytecode_offset(opcode, offset);
  }

  set_entry_points(ir_program->entry_points(), &dispatch_table, &program_builder);
  program_builder.cook();
  return program;
}

void Backend::emit_method(ir::Method* method,
                          ByteGen* gen,
                          UnorderedMap<ir::Class*, int>* typecheck_indexes,
                          DispatchTable* dispatch_table,
                          ProgramBuilder* program_builder) {
  int dispatch_offset;
  bool is_field_accessor;

  if (method->is_static()) {
    dispatch_offset = -1;
    is_field_accessor = false;
  } else {
    ASSERT(method->holder() != null);
    Selector<PlainShape> selector(method->name(), method->plain_shape());
    int table_offset = dispatch_table->dispatch_offset_for(selector);
    is_field_accessor = method->is_FieldStub()
        && !method->as_FieldStub()->is_throwing()
        && !method->as_FieldStub()->is_checking_setter();

    if (table_offset >= 0) {
      dispatch_offset = table_offset;
    } else {
      ASSERT(table_offset == -1);
      if (!typecheck_indexes->contains_key(method->holder())) {
        // TODO(kasper): This is a slightly weird case, where we have a
        // method that is never called but the tree shaker fails to
        // realize this. We end up with an unused entry in the dispatch
        // table at 'dispatch_table->slot_index_for(method)', but at
        // least we do not generate code for this. We should be able
        // to shake this out earlier by realizing that not all static
        // calls lead to live methods.
        return;
      }
      int index = (*typecheck_indexes)[method->holder()];
      ASSERT(index >= 0);
      // Negative indexes are for calls with static targets.
      // -1 is reserved for static methods. Anything below for calls to
      // instance methods that are statically resolved.
      dispatch_offset = -2 - index;
    }
  }

  int id = gen->assemble_method(method, dispatch_offset, is_field_accessor);

  if (dispatch_offset < 0) {
    // A call with a static target occupying a single entry in
    // the dispatch table.
    program_builder->set_dispatch_table_entry(dispatch_table->slot_index_for(method), id);
  } else {
    // A virtual call with a dynamic target occupying entries
    // in the dispatch table for each possible receiver type.
    bool was_executed;
    std::function<void (int)> callback = [&](int index) {
      was_executed = true;
      program_builder->set_dispatch_table_entry(index, id);
    };
    dispatch_table->for_each_slot_index(method,
                                        dispatch_offset,
                                        callback);
    ASSERT(was_executed);
  }
}

void Backend::emit_global(ir::Global* global,
                          ByteGen* gen,
                          ProgramBuilder* program_builder) {
  if (global->is_lazy()) {
    int id = gen->assemble_global(global);
    program_builder->push_lazy_initializer_id(id);
  } else {
    auto body = global->body();
    if (body->is_Sequence()) {
      List<ir::Expression*> sequence = body->as_Sequence()->expressions();
      ASSERT(sequence.length() == 1);
      body = sequence[0];
    }
    auto value = body->as_Return()->value();
    if (value->is_LiteralNull()) {
      program_builder->push_null();
    } else if (value->is_LiteralInteger()) {
      int64 val = value->as_LiteralInteger()->value();
      if (Smi::is_valid(val)) {
        program_builder->push_smi(val);
      } else {
        program_builder->push_large_integer(val);
      }
    } else if (value->is_LiteralString()) {
      ir::LiteralString* string = value->as_LiteralString();
      program_builder->push_string(string->value(), string->length());
    } else if (value->is_LiteralFloat()) {
      program_builder->push_double(value->as_LiteralFloat()->value());
    } else if (value->is_LiteralBoolean()) {
      program_builder->push_boolean(value->as_LiteralBoolean()->value());
    } else {
      UNREACHABLE();
    }
  }
}

void Backend::emit_class(ir::Class* klass,
                         const DispatchTable* dispatch_table,
                         SourceMapper* source_mapper,
                         ProgramBuilder* program_builder) {
  ASSERT(klass->is_instantiated());
  int id = dispatch_table->id_for(klass);
  int total_field_count = klass->total_field_count();
  const char* name = klass->name().c_str();
  source_mapper->add_class_entry(id, klass);
  program_builder->create_class(id,
                                name,
                                Instance::allocation_size(total_field_count),
                                klass->is_runtime_class());
}

} // namespace toit::compiler
} // namespace toit
