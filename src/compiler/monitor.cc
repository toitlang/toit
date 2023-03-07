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
#include "list.h"
#include "set.h"

namespace toit {
namespace compiler {

using namespace ir;

class MonitorVisitor : public ReplacingVisitor {
 public:
  Method* visit_MonitorMethod(MonitorMethod* node) {
    if (!node->has_body()) return node;
    ASSERT(parameters_.empty());
    for (auto parameter : node->parameters()) {
      parameters_.insert(parameter);
    }
    // Transform the original body into a block.
    // All references to parameters will increase the block-depth so they are
    //   accessed correctly.
    auto blocked_body = visit(node->body())->as_Expression();
    parameters_.clear();
    auto code = _new Code(List<Parameter*>(),
                          blocked_body,
                          true,  // It's a block.
                          node->range());

    // Build call to `locked_` instance method:
    //
    //  locked_: <blocked method-body>
    auto this_reference = _new ir::ReferenceLocal(node->parameters()[0], 0, node->range());
    CallBuilder call_builder(node->range());
    call_builder.add_argument(code, Symbol::invalid());
    auto dot = _new ir::Dot(this_reference, Symbols::locked_);
    // The optimizer will make this a static call.
    auto lock_call = call_builder.call_instance(dot);
    node->replace_body(lock_call);
    return node;
  }

  Method* visit_Method(Method* node) {
    // No need to go into non-monitor methods.
    return node;
  }

  ReferenceLocal* visit_ReferenceLocal(ReferenceLocal* node) {
    auto target = node->target();
    if (target->is_Parameter() && parameters_.contains(target->as_Parameter())) {
      return _new ir::ReferenceLocal(target, node->block_depth() + 1, node->range());
    }
    return node;
  }

  AssignmentLocal* visit_AssignmentLocal(AssignmentLocal* node) {
    auto new_assig = ir::ReplacingVisitor::visit_AssignmentLocal(node);
    ASSERT(new_assig == node);
    auto local = node->local();
    if (local->is_Parameter() && parameters_.contains(local->as_Parameter())) {
      return _new ir::AssignmentLocal(local, node->block_depth() + 1, node->right(), node->range());
    }
    return node;
  }

 private:
  UnorderedSet<Parameter*> parameters_;
};

void add_monitor_locks(ir::Program* program) {
  MonitorVisitor visitor;
  visitor.visit(program);
}

} // namespace toit::compiler
} // namespace toit
