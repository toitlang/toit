// Copyright (C) 2018 Toitware ApS.
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

#include "constant_propagation.h"

#include <math.h>

#include "../set.h"

namespace toit {
namespace compiler {

using namespace ir;

class MutationVisitor : public TraversingVisitor {
 public:
  void visit_AssignmentGlobal(AssignmentGlobal* node) {
    TraversingVisitor::visit_AssignmentGlobal(node);
    mutated_globals_.insert(node->global());
  }

  UnorderedSet<Global*> mutated_globals() { return mutated_globals_; }

 private:
  UnorderedSet<Global*> mutated_globals_;
};

class DependencyVisitor : public MutationVisitor {
 public:
  void visit_ReferenceGlobal(ReferenceGlobal* node) {
    MutationVisitor::visit_ReferenceGlobal(node);
    dependencies_.insert(node->target());
  }

  Set<Global*> global_dependencies() { return dependencies_; }

 private:
  Set<Global*> dependencies_;
};

static bool is_inlineable(Expression* expression) {
  if (expression->is_Sequence()) {
    auto expressions = expression->as_Sequence()->expressions();
    if (expressions.length() == 1) return is_inlineable(expressions.first());
    return false;
  }
  if (!expression->is_Return()) return false;
  auto value = expression->as_Return()->value();
  return value->is_Literal();
}

static Literal* inlined_value_for(Expression* expression) {
  ASSERT(is_inlineable(expression));
  if (expression->is_Sequence()) {
    auto expressions = expression->as_Sequence()->expressions();
    if (expressions.length() == 1) return inlined_value_for(expressions.first());
    UNREACHABLE();
  }
  ASSERT(expression->is_Return());
  return expression->as_Return()->value()->as_Literal();
}

class FoldingInliningVisitor : public ReplacingVisitor {
 public:
  FoldingInliningVisitor(const UnorderedSet<Global*>& mutated_globals)
      : mutated_globals_(mutated_globals) { }

  Expression* visit_ReferenceGlobal(ReferenceGlobal* node) {
    node = ReplacingVisitor::visit_ReferenceGlobal(node)->as_ReferenceGlobal();
    auto global = node->target();
    if (mutated_globals_.contains(global)) return node;
    if (is_inlineable(global->body())) {
      // We don't make a copy of the literal, which means that we end up having a DAG.
      return inlined_value_for(global->body());
    }
    return node;
  }

  Expression* visit_CallVirtual(CallVirtual* node) {
    node = ReplacingVisitor::visit_CallVirtual(node)->as_CallVirtual();
    Expression* result = null;
    if (node->receiver()->is_LiteralInteger() || node->receiver()->is_LiteralFloat()) {
      if (node->arguments().length() == 1) {
        auto arg = node->arguments().first();
        if (node->receiver()->is_LiteralInteger()) {
          int64 left = node->receiver()->as_LiteralInteger()->value();
          if (arg->is_LiteralInteger()) {
            int64 right = arg->as_LiteralInteger()->value();
            result = fold_int_int(left, right, node->selector(), node->range());
          } else if (arg->is_LiteralFloat()) {
            double right = arg->as_LiteralFloat()->value();
            result = fold_float_float(left, right, node->selector(), node->range());
          }
        } else {
          ASSERT(node->receiver()->is_LiteralFloat());
          double left = node->receiver()->as_LiteralFloat()->value();
          if (arg->is_LiteralInteger()) {
            int64 right = arg->as_LiteralInteger()->value();
            result = fold_float_float(left, right, node->selector(), node->range());
          } else if (arg->is_LiteralFloat()) {
            double right = arg->as_LiteralFloat()->value();
            result = fold_float_float(left, right, node->selector(), node->range());
          }
        }
      }
    }
    if (result != null) return result;
    return node;
  }

  Expression* visit_Not(Not* node) {
    node = ReplacingVisitor::visit_Not(node)->as_Not();
    auto value = node->value();
    if (value->is_LiteralBoolean()) {
      return _new ir::LiteralBoolean(!value->as_LiteralBoolean()->value(), value->range());
    }
    if (value->is_LiteralNull()) return _new ir::LiteralBoolean(true, value->range());
    if (value->is_Literal()) return _new ir::LiteralBoolean(false, value->range());
    return node;
  }

  Expression* visit_If(If* node) {
    node = ReplacingVisitor::visit_If(node)->as_If();
    auto condition = node->condition();
    if (condition->is_Literal()) {
      if (condition->is_LiteralNull() ||
          (condition->is_LiteralBoolean() && !condition->as_LiteralBoolean()->value())) {
        return node->no();
      } else {
        return node->yes();
      }
    }
    return node;
  }

 private:
  UnorderedSet<Global*> mutated_globals_;

  Expression* fold_int_int(int64 left, int64 right, Symbol selector, Source::Range range);
  Expression* fold_float_float(double left, double right, Symbol selector, Source::Range range);
};

Expression* FoldingInliningVisitor::fold_int_int(int64 left, int64 right, Symbol selector, Source::Range range) {
  if (selector == Token::symbol(Token::ADD)) {
    return _new ir::LiteralInteger(left + right, range);
  } else if (selector == Token::symbol(Token::SUB)) {
    return _new ir::LiteralInteger(left - right, range);
  } else if (selector == Token::symbol(Token::MUL)) {
    return _new ir::LiteralInteger(left * right, range);
  } else if (selector == Token::symbol(Token::MOD) && right != 0) {
    return _new ir::LiteralInteger(left % right, range);
  } else if (selector == Token::symbol(Token::DIV) && right != 0) {
    return _new ir::LiteralInteger(left / right, range);
  } else if (selector == Token::symbol(Token::BIT_OR)) {
    return _new ir::LiteralInteger(left | right, range);
  } else if (selector == Token::symbol(Token::BIT_XOR)) {
    return _new ir::LiteralInteger(left ^ right, range);
  } else if (selector == Token::symbol(Token::BIT_AND)) {
    return _new ir::LiteralInteger(left & right, range);
  } else if (selector == Token::symbol(Token::BIT_SHL)) {
    if (right >= 64) {
      return _new ir::LiteralInteger(0, range);
    } else if (right >= 0) {
      return _new ir::LiteralInteger(left << right, range);
    }
  } else if (selector == Token::symbol(Token::BIT_SHR)) {
    if (right >= 64) {
      return _new ir::LiteralInteger(left < 0 ? -1 : 0, range);
    } else if (right >= 0) {
      return _new ir::LiteralInteger(left >> right, range);
    }
  } else if (selector == Token::symbol(Token::BIT_USHR)) {
    if (right >= 64) {
      return _new ir::LiteralInteger(0, range);
    } else if (right > 0) {
      uint64 unsigned_left = static_cast<uint64>(left);
      int64 shifted = static_cast<int64>(unsigned_left >> right);
      return _new ir::LiteralInteger(shifted, range);
    }
  } else if (selector == Token::symbol(Token::EQ)) {
    return _new ir::LiteralBoolean(left == right, range);
  } else if (selector == Token::symbol(Token::LT)) {
    return _new ir::LiteralBoolean(left < right, range);
  } else if (selector == Token::symbol(Token::GT)) {
    return _new ir::LiteralBoolean(left > right, range);
  } else if (selector == Token::symbol(Token::LTE)) {
    return _new ir::LiteralBoolean(left <= right, range);
  } else if (selector == Token::symbol(Token::GTE)) {
    return _new ir::LiteralBoolean(left >= right, range);
  }
  return null;
}

Expression* FoldingInliningVisitor::fold_float_float(double left, double right, Symbol selector, Source::Range range) {
  if (selector == Token::symbol(Token::ADD)) {
    return _new ir::LiteralFloat(left + right, range);
  } else if (selector == Token::symbol(Token::SUB)) {
    return _new ir::LiteralFloat(left - right, range);
  } else if (selector == Token::symbol(Token::MUL)) {
    return _new ir::LiteralFloat(left * right, range);
  } else if (selector == Token::symbol(Token::MOD)) {
    return _new ir::LiteralFloat(fmod(left, right), range);
  } else if (selector == Token::symbol(Token::DIV)) {
    return _new ir::LiteralFloat(left / right, range);
  } else if (selector == Token::symbol(Token::BIT_OR)) {
  } else if (selector == Token::symbol(Token::EQ)) {
    return _new ir::LiteralBoolean(left == right, range);
  } else if (selector == Token::symbol(Token::LT)) {
    return _new ir::LiteralBoolean(left < right, range);
  } else if (selector == Token::symbol(Token::GT)) {
    return _new ir::LiteralBoolean(left > right, range);
  } else if (selector == Token::symbol(Token::LTE)) {
    return _new ir::LiteralBoolean(left <= right, range);
  } else if (selector == Token::symbol(Token::GTE)) {
    return _new ir::LiteralBoolean(left >= right, range);
  }
  return null;
}

static void add_to_global_list(Global* global,
                               UnorderedMap<Global*, Set<Global*>>& all_dependencies,
                               ListBuilder<Global*>* builder,
                               UnorderedSet<Global*>* seen) {
  if (seen->contains(global)) return;
  // By adding the global to the seen set this early, we ensure that we don't have
  //   infinite recursion problems.
  seen->insert(global);
  auto probe = all_dependencies.find(global);
  if (probe != all_dependencies.end()) {
    for (auto dep : probe->second) {
      add_to_global_list(dep, all_dependencies, builder, seen);
    }
  }
  builder->add(global);
}

void propagate_constants(Program* program) {
  MutationVisitor mutation_visitor;
  for (auto klass : program->classes()) {
    for (auto method : klass->methods()) {
      mutation_visitor.visit(method);
    }
  }
  for (auto method : program->methods()) {
    mutation_visitor.visit(method);
  }

  UnorderedSet<Global*> mutated_globals = mutation_visitor.mutated_globals();
  UnorderedMap<Global*, Set<Global*>> all_dependencies;

  for (auto global : program->globals()) {
    if (mutated_globals.contains(global)) {
      // We won't inline the value of this global. Just search for other mutations.
      MutationVisitor visitor;
      visitor.visit(global);
      mutated_globals.insert_all(visitor.mutated_globals());
    } else {
      DependencyVisitor visitor;
      visitor.visit(global);
      mutated_globals.insert_all(visitor.mutated_globals());
      all_dependencies[global] = visitor.global_dependencies();
    }
  }

  // Propagate globals first.
  // Sort them by dependencies, so we can inline globals that fold to constant
  //   values.
  ListBuilder<Global*> builder;
  UnorderedSet<Global*> seen;
  for (auto global : program->globals()) {
    add_to_global_list(global, all_dependencies, &builder, &seen);
  }
  auto sorted = builder.build();

  FoldingInliningVisitor folding_visitor(mutated_globals);
  for (auto global : sorted) {
    folding_visitor.visit(global);
  }
  for (auto method : program->methods()) {
    folding_visitor.visit(method);
  }

  for (auto klass : program->classes()) {
    for (auto method : klass->methods()) {
      folding_visitor.visit(method);
    }
  }

  // Remove all globals that were inlineable.
  ListBuilder<Global*> remaining_globals;
  for (auto global : sorted) {
    if (mutated_globals.contains(global) ||
        !is_inlineable(global->body())) {
      remaining_globals.add(global);
    }
  }
  program->replace_globals(remaining_globals.build());
}

} // namespace toit::compiler
} // namespace toit
