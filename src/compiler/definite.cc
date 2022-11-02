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

#include "definite.h"

#include <stdarg.h>

#include "diagnostic.h"
#include "ir.h"
#include "map.h"

namespace toit {
namespace compiler {

using namespace ir;

namespace {  // anonymous.

class State {
 public:
  // Invalid states can't be used to mark locals, or check their properties.
  // However, they can be used in merging, where they are simply ignored.
  // If a valid state is merged into an invalid one, the invalid one becomes a
  //   copy of the other state.
  static State invalid() {
    State result;
    result.is_valid_ = false;
    return result;
  }

  bool is_valid() const { return is_valid_; }

  /// Merges the given [other] state into this state.
  void merge(State other) {
    if (!other.is_valid_) return;
    if (!is_valid_) {
      *this = other;
      return;
    }

    auto& other_map = other.map_;
    for (auto& p : map_.underlying_map()) {
      if (p.second == UNDEFINED) {
        if (other_map.find(p.first) == other_map.end()) {
          p.second = PARTIALLY_DEFINED;
        }
      }
    }
    // If an element wasn't killed in both paths, add it back.
    for (auto p : other_map.underlying_map()) {
      if (p.second == PARTIALLY_DEFINED) {
        map_[p.first] = PARTIALLY_DEFINED;
      } else if (map_.find(p.first) == map_.end()) {
        map_.add(p.first, PARTIALLY_DEFINED);
      }
    }
    does_return_ = does_return_ && other.does_return();
  }

  void mark_undefined(Node* variable) {
    ASSERT(is_valid());
    map_[variable] = UNDEFINED;
  }

  void mark_all_as_partially_defined(Local* loop_variable = null) {
    ASSERT(is_valid());
    for (auto& p : map_.underlying_map()) {
      if (p.first != loop_variable) {
        p.second = PARTIALLY_DEFINED;
      }
    }
  }

  void remove(Node* variable) {
    ASSERT(is_valid());
    map_.remove(variable);
  }

  bool is_completely_undefined(Node* node) {
    ASSERT(is_valid());
    auto probe = map_.find(node);
    return probe != map_.end() && probe->second == UNDEFINED;
  }

  bool is_undefined(Node* node) {
    ASSERT(is_valid());
    return map_.find(node) != map_.end();
  }

  void reset() {
    ASSERT(is_valid());
    map_.clear();
    does_return_ = false;
  }

  void clear_variables() {
    ASSERT(is_valid());
    map_.clear();
  }

  bool empty() const {
    ASSERT(is_valid());
    return map_.empty();
  }

  bool does_return() const {
    ASSERT(is_valid());
    return does_return_;
  }

  void mark_return() {
    ASSERT(is_valid());
    does_return_ = true;
  }

  void set_does_return(bool new_val) {
    ASSERT(is_valid());
    does_return_ = new_val;
  }

 private:
  enum UndefinedKind {
    UNDEFINED,
    PARTIALLY_DEFINED,
  };
  // Set of undefined locals and fields.
  UnorderedMap<Node*, UndefinedKind> map_;

  bool does_return_ = false;
  bool is_valid_ = true;
};

struct LoopState {
  explicit LoopState(While* loop)
      : loop(loop)
      , break_state(State::invalid())
      , continue_state(State::invalid()) { }

  static LoopState invalid() {
    return LoopState(null);
  }

  bool is_valid() const { return loop != null; }

  While* loop;
  State break_state;
  State continue_state;
};

}  // namespace anonymous.

class DefiniteChecker : public Visitor {
 public:
  explicit DefiniteChecker(Diagnostics* diagnostics)
      : diagnostics_(diagnostics)
      , loop_state_(LoopState::invalid()) {}

  void visit(Node* node) {
    node->accept(this);
  }

  // Nodes that need to be handled specially are first.

  void visit_If(If* node) {
    visit(node->condition());
    auto old_state = state_;
    visit(node->yes());
    auto yes_state = state_;
    state_ = old_state;
    visit(node->no());
    state_.merge(yes_state);
  }

  void visit_TryFinally(TryFinally* node) {
    auto old_state = state_;
    // Note that we shortcut the `visit_Code` which would reset the
    //   fields (in particular the `does_return_`), as it can't know
    //   that the body is unconditionally executed.
    visit(node->body()->body());
    bool does_return = state_.does_return();
    state_ = old_state;
    visit(node->handler());
    // If the body returns or the finally returns, then
    //   we know that the try/finally returns (or throws).
    if (does_return) {
      state_.set_does_return(does_return);
    }
  }

  void visit_While(While* node) {
    visit(node->condition());
    // We assume that the body/update is never executed.
    auto old_state = state_;
    auto old_loop_state = loop_state_;

    loop_state_ = LoopState(node);

    // Since we can assume that the body is executed multiple times, we
    //   mark all undefined variables as partially defined.
    // The only exception is the loop-variable itself.
    state_.mark_all_as_partially_defined(node->loop_variable());
    visit(node->body());
    state_.merge(loop_state_.continue_state);
    visit(node->update());

    if (node->condition()->is_LiteralBoolean() &&
        node->condition()->as_LiteralBoolean()->value()) {
      // A while-true loop.
      if (loop_state_.break_state.is_valid()) {
        state_ = loop_state_.break_state;
      } else {
        // No break in a while-true loop.
        // Assume there was a return or throw.
        state_.clear_variables();
        state_.mark_return();
      }
    } else {
      state_ = old_state;
    }
    loop_state_ = old_loop_state;
  }

  void visit_LogicalBinary(LogicalBinary* node) {
    visit(node->left());
    auto left_state = state_;
    visit(node->right());
    // We have to assume that the RHS was never executed.
    state_ = left_state;
  }

  void visit_Code(Code* node) {
    auto old_state = state_;

    // We have to assume that the block/lambda is executed multiple times.
    state_.mark_all_as_partially_defined();

    // We keep the loop state: if we reach a break or continue, it's ok to
    //   merge the data.
    visit(node->body());
    // We can't assume that the block/lambda is called.
    state_ = old_state;
  }

  void visit_Return(Return* node) {
    if (!node->is_end_of_method_return()) {
      // If we are inside a block/lambda, the `Return` might not leave
      //   the method. For simplicity, we don't track the block depth.
      // We use `has_seen_return` only for different error messages, and
      //   spuriously detecting a return makes the error message only
      //   slightly worse.
      has_seen_return_ = true;

      // Otherwise, we don't need to check the depth: if we are inside a block/lambda,
      //   then the state will be reset when we leave the block/lambda (since
      //   the analysis never assumes that the block/lambda is called).
      // Inside the block/lambda, the `return` "works", in that it correctly aborts
      //   any loop, or `if` branch.
      state_.mark_return();
    }
    visit(node->value());
    // No need to report errors/warnings after a return.
    state_.clear_variables();
  }

  void visit_Program(Program* node) {
    for (auto klass: node->classes()) visit(klass);
    for (auto method: node->methods()) visit(method);
    for (auto global: node->globals()) visit(global);
  }

  void visit_Class(Class* node) {
    // Constructors and factories are already visited in `visit_Program` as
    // global methods.
    // Fields don't have any code anymore, since all of the initialization is
    // in the constructors.
    for (auto method: node->methods()) visit(method);
  }

  void visit_Field(Field* node) { UNREACHABLE(); }

  void visit_Method(Method* node) {
    if (!node->has_body()) return;
    method_ = node;
    state_.reset();
    has_seen_return_ = false;
    loop_state_ = LoopState::invalid();

    visit(node->body());
    bool should_check_returns = !node->is_constructor() && !node->return_type().is_none();
    if (should_check_returns && !state_.does_return()) {
      if (has_seen_return_) {
        report_error(node->range(), "Method doesn't return a value on all paths");
      } else {
        report_error(node->range(), "Method doesn't return a value");
      }
    }
  }

  void visit_MethodInstance(MethodInstance* node) { return visit_Method(node); }
  void visit_MonitorMethod(MonitorMethod* node) { return visit_Method(node); }
  void visit_MethodStatic(MethodStatic* node) { return visit_Method(node); }
  void visit_Constructor(Constructor* node) { return visit_Method(node); }
  void visit_Global(Global* node) { return visit_Method(node); }
  void visit_AdapterStub(AdapterStub* node) { return visit_Method(node); }
  void visit_IsInterfaceStub(IsInterfaceStub* node) { return visit_Method(node); }
  void visit_FieldStub(FieldStub* node) { return visit_Method(node); }

  void visit_Expression(Expression* node) { UNREACHABLE(); }
  void visit_Error(Error* node) {
    for (auto expr : node->nested()) {
      visit(expr);
    }
  }

  void visit_Nop(Nop* node) { }

  void visit_FieldStore(FieldStore* node) {
    // First visit the value, before killing it.
    visit(node->value());
    auto field = node->field();
    if (node->value()->is_LiteralUndefined()) {
      state_.mark_undefined(field);
    } else {
      kill(field);
    }
  }

  void visit_FieldLoad(FieldLoad* node) {
    use(node->field(), node->range());
  }

  void visit_Sequence(Sequence* node) {
    auto old_locals = current_locals_;
    current_locals_.clear();
    for (auto expr : node->expressions()) {
      visit(expr);
    }
    for (auto local : current_locals_) {
      kill(local);
    }
    current_locals_ = old_locals;
  }

  void visit_Builtin(Builtin* node) { }

  void visit_Not(Not* node) {
    visit(node->value());
  }

  void visit_LoopBranch(LoopBranch* node) {
    if (loop_state_.is_valid()) {
      if (node->is_break()) {
        loop_state_.break_state.merge(state_);
      } else {
        loop_state_.continue_state.merge(state_);
      }
    }
  }

  void visit_Reference(Reference* node) { UNREACHABLE(); }

  void visit_ReferenceClass(ReferenceClass* node) { UNREACHABLE(); }
  void visit_ReferenceMethod(ReferenceMethod* node) { }

  void visit_ReferenceLocal(ReferenceLocal* node) {
    use(node->target(), node->range());
  }

  void visit_ReferenceBlock(ReferenceBlock* node) { visit_ReferenceLocal(node); }
  void visit_ReferenceGlobal(ReferenceGlobal* node) { }

  void visit_Local(Local* node) { UNREACHABLE(); }
  void visit_Parameter(Parameter* node) { UNREACHABLE(); }
  void visit_CapturedLocal(CapturedLocal* node) { UNREACHABLE(); }
  void visit_Block(Block* node) { UNREACHABLE(); }

  void visit_Dot(Dot* node) { visit(node->receiver()); }

  void visit_LspSelectionDot(LspSelectionDot* node) { visit_Dot(node); }

  void visit_Super(Super* node) {
    ASSERT(method_->is_constructor());
    if (state_.empty()) return;
    for (auto field : method_->holder()->fields()) {
      if (state_.is_undefined(field)) {
        state_.remove(field);
        if (method_->is_synthetic()) {
          report_error(field->range(),
                       "Field '%s' must be initialized in a constructor",
                       field->name().c_str());
        } else if (node->is_explicit()) {
          report_error(node->range(),
                       "Field '%s' not initialized on all paths",
                       field->name().c_str());
        } else if (!node->is_at_end()) {
          report_error(node->range(),
                       "Field '%s' not initialized on all paths before implicit super-call",
                       field->name().c_str());
        } else {
          ASSERT(node->is_at_end());
          report_error(node->range(),
                       "Field '%s' not initialized on all paths in constructor",
                       field->name().c_str());
        }
      }
    }
  }

  void visit_Call(Call* node) {
    visit(node->target());
    for (auto argument : node->arguments()) visit(argument);
  }

  void visit_CallConstructor(CallConstructor* node) { visit_Call(node); }
  void visit_CallStatic(CallStatic* node) {
    visit_Call(node);
    if (node->target()->target()->does_not_return()) {
      // Since we return from the method here, we don't need to worry about
      //   uninitialized fields, and can just do as if they had been set to a
      //   value.
      state_.clear_variables();
      state_.mark_return();
    }
  }
  void visit_Lambda(Lambda* node) {
    // Ignore the captured arguments.
    // We provide error messages only when we encounter the captured variables.
    visit(node->arguments()[0]);
  }
  void visit_CallVirtual(CallVirtual* node) { visit_Call(node); }
  void visit_CallBlock(CallBlock* node) { visit_Call(node); }
  void visit_CallBuiltin(CallBuiltin* node) { visit_Call(node); }

  void visit_Typecheck(Typecheck* node) {
    visit(node->expression());
  }

  void visit_Assignment(Assignment* node) { UNREACHABLE(); }

  void visit_AssignmentDefine(AssignmentDefine* node) {
    visit(node->right());
    if (node->right()->is_LiteralUndefined()) {
      state_.mark_undefined(node->local());
    }
  }

  void visit_AssignmentLocal(AssignmentLocal* node) {
    auto local = node->local();
    visit(node->right());
    if (node->right()->is_LiteralUndefined()) {
      // This can only happen for loop-variables.
      ASSERT(state_.is_undefined(local));
    } else {
      if (local->is_final() && !state_.is_completely_undefined(local)) {
        if (state_.is_undefined(local)) {
          report_error(node->range(), "Can't assign to final local multiple times");
        } else {
          report_error(node->range(), "Can't assign to final local");
        }
      }
      kill(local);
    }
  }

  void visit_AssignmentGlobal(AssignmentGlobal* node) {
    visit(node->right());
  }

  void visit_Literal(Literal* node) { }

  void visit_LiteralNull(LiteralNull* node) { visit_Literal(node); }
  void visit_LiteralUndefined(LiteralUndefined* node) { visit_Literal(node); }
  void visit_LiteralInteger(LiteralInteger* node) { visit_Literal(node); }
  void visit_LiteralFloat(LiteralFloat* node) { visit_Literal(node); }
  void visit_LiteralString(LiteralString* node) { visit_Literal(node); }
  void visit_LiteralBoolean(LiteralBoolean* node) { visit_Literal(node); }
  void visit_LiteralByteArray(LiteralByteArray* node) { visit_Literal(node); }

  void visit_PrimitiveInvocation(PrimitiveInvocation* node) { }

 private:
  Diagnostics* diagnostics_;

  // The list of undefined locals that is leaves the scope when we
  //   leave the current sequence.
  std::vector<Local*> current_locals_;
  State state_;
  LoopState loop_state_;
  // Only used for nicer error messages. The `state_` tracks flow-sensitive
  //   `return`s. It is ok to set this variable to true, even if there isn't
  //   any real return.
  bool has_seen_return_ = false;
  Method* method_;

  Diagnostics* diagnostics() const { return diagnostics_; }

  void kill(Node* variable) { state_.remove(variable); }

  void use(Field* field, Source::Range range) {
    if (state_.is_undefined(field)) {
      report_error(range,
                   "Field '%s' must be initialized before first use",
                   field->name().c_str());
    }
  }

  void use(Local* local, Source::Range range) {
    if (state_.is_undefined(local)) {
      report_error(range,
                   "Local '%s' must be initialized before first use",
                   local->name().c_str());
    }
  }

  void report_error(Source::Range range, const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    diagnostics()->report_error(range, format, arguments);
    va_end(arguments);
  }
};

void check_definite_assignments_returns(ir::Program* program, Diagnostics* diagnostics) {
  DefiniteChecker checker(diagnostics);
  program->accept(&checker);
}

} // namespace toit::compiler
} // namespace toit

