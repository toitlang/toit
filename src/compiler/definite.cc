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
    result._is_valid = false;
    return result;
  }

  bool is_valid() const { return _is_valid; }

  /// Merges the given [other] state into this state.
  void merge(State other) {
    if (!other._is_valid) return;
    if (!_is_valid) {
      *this = other;
      return;
    }

    auto& other_map = other._map;
    for (auto& p : _map.underlying_map()) {
      if (p.second == UNDEFINED) {
        if (other_map.find(p.first) == other_map.end()) {
          p.second = PARTIALLY_DEFINED;
        }
      }
    }
    // If an element wasn't killed in both paths, add it back.
    for (auto p : other_map.underlying_map()) {
      if (p.second == PARTIALLY_DEFINED) {
        _map[p.first] = PARTIALLY_DEFINED;
      } else if (_map.find(p.first) == _map.end()) {
        _map.add(p.first, PARTIALLY_DEFINED);
      }
    }
    _does_return = _does_return && other.does_return();
  }

  void mark_undefined(Node* variable) {
    ASSERT(is_valid());
    _map[variable] = UNDEFINED;
  }

  void mark_all_as_partially_defined(Local* loop_variable = null) {
    ASSERT(is_valid());
    for (auto& p : _map.underlying_map()) {
      if (p.first != loop_variable) {
        p.second = PARTIALLY_DEFINED;
      }
    }
  }

  void remove(Node* variable) {
    ASSERT(is_valid());
    _map.remove(variable);
  }

  bool is_completely_undefined(Node* node) {
    ASSERT(is_valid());
    auto probe = _map.find(node);
    return probe != _map.end() && probe->second == UNDEFINED;
  }

  bool is_undefined(Node* node) {
    ASSERT(is_valid());
    return _map.find(node) != _map.end();
  }

  void reset() {
    ASSERT(is_valid());
    _map.clear();
    _does_return = false;
  }

  void clear_variables() {
    ASSERT(is_valid());
    _map.clear();
  }

  bool empty() const {
    ASSERT(is_valid());
    return _map.empty();
  }

  bool does_return() const {
    ASSERT(is_valid());
    return _does_return;
  }

  void mark_return() {
    ASSERT(is_valid());
    _does_return = true;
  }

  void set_does_return(bool new_val) {
    ASSERT(is_valid());
    _does_return = new_val;
  }

 private:
  enum UndefinedKind {
    UNDEFINED,
    PARTIALLY_DEFINED,
  };
  // Set of undefined locals and fields.
  UnorderedMap<Node*, UndefinedKind> _map;

  bool _does_return = false;
  bool _is_valid = true;
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
      : _diagnostics(diagnostics)
      , _loop_state(LoopState::invalid()) {}

  void visit(Node* node) {
    node->accept(this);
  }

  // Nodes that need to be handled specially are first.

  void visit_If(If* node) {
    visit(node->condition());
    auto old_state = _state;
    visit(node->yes());
    auto yes_state = _state;
    _state = old_state;
    visit(node->no());
    _state.merge(yes_state);
  }

  void visit_TryFinally(TryFinally* node) {
    auto old_state = _state;
    // Note that we shortcut the `visit_Code` which would reset the
    //   fields (in particular the `_does_return`), as it can't know
    //   that the body is unconditionally executed.
    visit(node->body()->body());
    bool does_return = _state.does_return();
    _state = old_state;
    visit(node->handler());
    // If the body returns or the finally returns, then
    //   we know that the try/finally returns (or throws).
    if (does_return) {
      _state.set_does_return(does_return);
    }
  }

  void visit_While(While* node) {
    visit(node->condition());
    // We assume that the body/update is never executed.
    auto old_state = _state;
    auto old_loop_state = _loop_state;

    _loop_state = LoopState(node);

    // Since we can assume that the body is executed multiple times, we
    //   mark all undefined variables as partially defined.
    // The only exception is the loop-variable itself.
    _state.mark_all_as_partially_defined(node->loop_variable());
    visit(node->body());
    _state.merge(_loop_state.continue_state);
    visit(node->update());

    if (node->condition()->is_LiteralBoolean() &&
        node->condition()->as_LiteralBoolean()->value()) {
      // A while-true loop.
      if (_loop_state.break_state.is_valid()) {
        _state = _loop_state.break_state;
      } else {
        // No break in a while-true loop.
        // Assume there was a return or throw.
        _state.clear_variables();
        _state.mark_return();
      }
    } else {
      _state = old_state;
    }
    _loop_state = old_loop_state;
  }

  void visit_LogicalBinary(LogicalBinary* node) {
    visit(node->left());
    auto left_state = _state;
    visit(node->right());
    // We have to assume that the RHS was never executed.
    _state = left_state;
  }

  void visit_Code(Code* node) {
    auto old_state = _state;

    // We have to assume that the block/lambda is executed multiple times.
    _state.mark_all_as_partially_defined();

    // We keep the loop state: if we reach a break or continue, it's ok to
    //   merge the data.
    visit(node->body());
    // We can't assume that the block/lambda is called.
    _state = old_state;
  }

  void visit_Return(Return* node) {
    if (!node->is_end_of_method_return()) {
      // If we are inside a block/lambda, the `Return` might not leave
      //   the method. For simplicity, we don't track the block depth.
      // We use `has_seen_return` only for different error messages, and
      //   spuriously detecting a return makes the error message only
      //   slightly worse.
      _has_seen_return = true;

      // Otherwise, we don't need to check the depth: if we are inside a block/lambda,
      //   then the state will be reset when we leave the block/lambda (since
      //   the analysis never assumes that the block/lambda is called).
      // Inside the block/lambda, the `return` "works", in that it correctly aborts
      //   any loop, or `if` branch.
      _state.mark_return();
    }
    visit(node->value());
    // No need to report errors/warnings after a return.
    _state.clear_variables();
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
    _method = node;
    _state.reset();
    _has_seen_return = false;
    _loop_state = LoopState::invalid();

    visit(node->body());
    bool should_check_returns = !node->is_constructor() && !node->return_type().is_none();
    if (should_check_returns && !_state.does_return()) {
      if (_has_seen_return) {
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
      _state.mark_undefined(field);
    } else {
      kill(field);
    }
  }

  void visit_FieldLoad(FieldLoad* node) {
    use(node->field(), node->range());
  }

  void visit_Sequence(Sequence* node) {
    auto old_locals = _current_locals;
    _current_locals.clear();
    for (auto expr : node->expressions()) {
      visit(expr);
    }
    for (auto local : _current_locals) {
      kill(local);
    }
    _current_locals = old_locals;
  }

  void visit_Builtin(Builtin* node) { }

  void visit_Not(Not* node) {
    visit(node->value());
  }

  void visit_LoopBranch(LoopBranch* node) {
    if (_loop_state.is_valid()) {
      if (node->is_break()) {
        _loop_state.break_state.merge(_state);
      } else {
        _loop_state.continue_state.merge(_state);
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
    ASSERT(_method->is_constructor());
    if (_state.empty()) return;
    for (auto field : _method->holder()->fields()) {
      if (_state.is_undefined(field)) {
        _state.remove(field);
        if (_method->is_synthetic()) {
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
      _state.clear_variables();
      _state.mark_return();
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
      _state.mark_undefined(node->local());
    }
  }

  void visit_AssignmentLocal(AssignmentLocal* node) {
    auto local = node->local();
    visit(node->right());
    if (node->right()->is_LiteralUndefined()) {
      // This can only happen for loop-variables.
      ASSERT(_state.is_undefined(local));
    } else {
      if (local->is_final() && !_state.is_completely_undefined(local)) {
        if (_state.is_undefined(local)) {
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
  Diagnostics* _diagnostics;

  // The list of undefined locals that is leaves the scope when we
  //   leave the current sequence.
  std::vector<Local*> _current_locals;
  State _state;
  LoopState _loop_state;
  // Only used for nicer error messages. The `_state` tracks flow-sensitive
  //   `return`s. It is ok to set this variable to true, even if there isn't
  //   any real return.
  bool _has_seen_return = false;
  Method* _method;

  Diagnostics* diagnostics() const { return _diagnostics; }

  void kill(Node* variable) { _state.remove(variable); }

  void use(Field* field, Source::Range range) {
    if (_state.is_undefined(field)) {
      report_error(range,
                   "Field '%s' must be initialized before first use",
                   field->name().c_str());
    }
  }

  void use(Local* local, Source::Range range) {
    if (_state.is_undefined(local)) {
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

