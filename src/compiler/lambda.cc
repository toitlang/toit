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

#include "lambda.h"

namespace toit {
namespace compiler {

class BoxVisitor : public ir::ReplacingVisitor {
 public:
  BoxVisitor(ir::Constructor* constructor, ir::Field* field)
      : _constructor(constructor), _field(field) {}

  ir::Method* visit_Method(toit::compiler::ir::Method* node) {
    auto new_method = ir::ReplacingVisitor::visit_Method(node);
    ASSERT(new_method == node);
    ListBuilder<ir::Expression*> new_instructions;

    auto parameters = node->parameters();
    for (int i = 0; i < parameters.length(); i++) {
      auto parameter = parameters[i];
      if (!needs_boxing(parameter)) continue;
      auto range = parameter->range();
      auto box = create_box(new ir::ReferenceLocal(parameter, 0, range), range);
      box->as_CallConstructor()->mark_box_construction();
      new_instructions.add(new ir::AssignmentLocal(parameter, 0, box, range));
    }
    if (new_instructions.is_empty()) return node;
    auto body = node->body();
    if (body->is_Sequence()) {
      auto sequence = body->as_Sequence();
      new_instructions.add(sequence->expressions());
    } else {
      new_instructions.add(body);
    }
    node->replace_body(new ir::Sequence(new_instructions.build(), node->body()->range()));
    return node;
  }

  ir::AssignmentDefine* visit_AssignmentDefine(ir::AssignmentDefine* node) {
    auto new_node = ir::ReplacingVisitor::visit_AssignmentDefine(node);
    ASSERT(new_node == node);

    if (!needs_boxing(node->local())) return node;
    auto box = create_box(node->right(), node->range());
    node->replace_right(box);
    return node;
  }

  ir::Node* visit_ReferenceLocal(ir::ReferenceLocal* node) {
    auto new_reference = ir::ReplacingVisitor::visit_ReferenceLocal(node);
    ASSERT(new_reference == node);
    auto local = node->target();
    auto probe = _capture_replacements.find(local);
    if (probe != _capture_replacements.end()) {
      auto param = probe->second.first;
      auto depth = probe->second.second;
      node = _new ir::ReferenceLocal(param, node->block_depth() - depth, node->range());
    }
    if (!needs_boxing(local)) return node;
    auto field_load = _new ir::FieldLoad(node, _field, node->range());
    field_load->mark_box_load();
    return field_load;
  }

  ir::Node* visit_AssignmentLocal(ir::AssignmentLocal* node) {
    auto new_assig = ir::ReplacingVisitor::visit_AssignmentLocal(node);
    ASSERT(new_assig == node);
    auto local = node->local();
    auto probe = _capture_replacements.find(local);
    if (probe != _capture_replacements.end()) {
      auto param = probe->second.first;
      auto depth = probe->second.second;
      node = _new ir::AssignmentLocal(param, node->block_depth() - depth, node->right(), node->range());
    }
    if (!needs_boxing(local)) return node;
    auto field_store = _new ir::FieldStore(
        _new ir::ReferenceLocal(node->local(), node->block_depth(), node->range()),
        _field,
        node->right(),
        node->range());
    field_store->mark_box_store();
    return field_store;
  }

  ir::While* visit_While(ir::While* node) {
    auto new_while = ir::ReplacingVisitor::visit_While(node)->as_While();
    ASSERT(new_while == node);

    auto loop_variable = node->loop_variable();
    if (needs_boxing(loop_variable)) {
      // The variable is already boxed, but we need to make sure the
      // box is "refreshed" at every iteration.
      auto range = loop_variable->range();
      auto old_value_load = _new ir::FieldLoad(_new ir::ReferenceLocal(loop_variable, 0, range),
                                               _field,
                                               range);
      old_value_load->mark_box_load();
      auto new_box = create_box(old_value_load, range);
      auto box_replacement = _new ir::AssignmentLocal(loop_variable, 0, new_box, range);

      auto update = new_while->update();
      if (update->is_Nop()) {
        node->replace_update(box_replacement);
      } else {
        auto expressions = ListBuilder<ir::Expression*>::build(box_replacement, update);
        node->replace_update(_new ir::Sequence(expressions, node->update()->range()));
      }
    }
    return node;
  }

  ir::Lambda* visit_Lambda(ir::Lambda* node) {
    // The array containing the captured variables is the only place where we
    // don't want to replace accesses to the variables with accesses to the
    // lambda boxes.
    // However, we still need to replace the references, in case a captured
    //   variable is captured inside a lambda.

    ASSERT(_should_box);
    _should_box = false;
    auto new_captured_args = visit(node->captured_args());
    ASSERT(new_captured_args->is_Expression());
    node->set_captured_args(new_captured_args->as_Expression());
    _should_box = true;

    // Add the new additional parameters that are passed on the stack by the interpreter,
    //  and set the mapping, so that we can do the replacements when we see references
    //  to the captured variables.
    Map<ir::Local*, std::pair<ir::CapturedLocal*, int>> capture_replacements;
    auto captured_depths = node->captured_depths();
    if (!captured_depths.empty()) {
      // Add the additional parameters to the code, and add the mapping so we can
      // replace references to the captured variables with the corresponding parameter.
      ListBuilder<ir::Parameter*> new_params;
      new_params.add(node->code()->parameters());
      int parameter_index = node->code()->parameters().length();
      for (auto captured_local : captured_depths.keys()) {
        auto new_param = _new ir::CapturedLocal(captured_local, parameter_index++, captured_local->range());
        new_params.add(new_param);
        capture_replacements[captured_local] = std::make_pair(new_param, captured_depths.at(captured_local));
      }
      node->code()->set_parameters(new_params.build());
    }
    auto old_replacements = _capture_replacements;
    _capture_replacements = capture_replacements;
    auto new_code = node->code()->accept(this);
    ASSERT(new_code = node->code());
    _capture_replacements = old_replacements;
    return node;
  }

 private:
  bool _should_box = true;
  ir::Constructor* _constructor;
  ir::Field* _field;
  Map<ir::Local*, std::pair<ir::CapturedLocal*, int>> _capture_replacements;

  bool needs_boxing(ir::Local* local) {
    return _should_box &&
        local != null &&
        local->is_captured() &&
        !local->is_effectively_final() &&
        !local->is_effectively_final_loop_variable();
  }

  ir::Expression* create_box(ir::Expression* initial_value, Source::Range range) {
    CallBuilder call_builder(range);
    call_builder.add_argument(initial_value, Symbol::invalid());
    auto box = call_builder.call_constructor(new ir::ReferenceMethod(_constructor, range));
    box->as_CallConstructor()->mark_box_construction();
    return box;
  }
};

void add_lambda_boxes(ir::Program* program) {
  ir::Class* box = program->lambda_box();
  ir::Constructor* constructor = box->constructors()[0]->as_Constructor();
  ASSERT(constructor != null);
  ir::Field* field = box->fields()[0];
  BoxVisitor visitor(constructor, field);
  visitor.visit(program);
}


} // namespace toit::compiler
} // namespace toit
