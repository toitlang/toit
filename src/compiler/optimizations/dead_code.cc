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

#include "dead_code.h"

namespace toit {
namespace compiler {

using namespace ir;

static bool expression_terminates(Expression* expression,
                                  TypeDatabase* propagated_types) {
  if (expression->is_Return()) {
    return true;
  }
  if (expression->is_If()) {
    return expression_terminates(expression->as_If()->no(), propagated_types) &&
        expression_terminates(expression->as_If()->yes(), propagated_types);
  }
  if (expression->is_Sequence()) {
    // We know that all subexpressions are already optimized. As such, we only need to check
    //   the last expression in the list of subexpressions.
    List<Expression*> subexpressions = expression->as_Sequence()->expressions();
    return !subexpressions.is_empty() &&
        expression_terminates(subexpressions.last(), propagated_types);
  }
  if (propagated_types != null && expression->is_Call()) {
    if (expression->is_CallBuiltin()) return false;
    return propagated_types->does_not_return(expression->as_Call());
  }
  if (expression->is_CallStatic()) {
    auto target_method = expression->as_CallStatic()->target()->target();
    return target_method->does_not_return();
  }
  return false;
}

static bool is_dead_code(Expression* expression) {
  return expression->is_Literal() ||
      // A reference to a global could have side effects and we don't
      // know if it requires lazy initialization yet.
      expression->is_ReferenceBlock() ||
      expression->is_ReferenceClass() ||
      expression->is_ReferenceLocal() ||
      expression->is_ReferenceMethod() ||
      expression->is_FieldLoad() ||
      expression->is_Nop();
}

Sequence* eliminate_dead_code(Sequence* node, TypeDatabase* propagated_types) {
  List<Expression*> expressions = node->expressions();
  int initial_length = expressions.length();
  int target_index = 0;
  for (int i = 0; i < initial_length; i++) {
    if (i != initial_length - 1 &&  // The last expression is the value of the sequence.
        is_dead_code(expressions[i])) continue;
    expressions[target_index++] = expressions[i];
  }

  if (target_index != expressions.length()) {
    expressions = expressions.sublist(0, target_index);
  }

  for (int i = 0; i < expressions.length() - 1; i++) {
    if (expression_terminates(expressions[i], propagated_types)) {
      expressions = expressions.sublist(0, i + 1);
      break;
    }
  }

  if (expressions.length() == initial_length) return node;
  return _new Sequence(expressions, node->range());
}

class DeadCodeEliminator : public ReturningVisitor<Node*> {
 public:
  class Helper {
   public:
    explicit Helper(DeadCodeEliminator* eliminator)
        : eliminator_(eliminator)
        , previous_(null)
        , terminates_(false) {}

    explicit Helper(Helper* previous)
        : eliminator_(previous->eliminator_)
        , previous_(previous)
        , terminates_(previous->terminates_) {}

    Node* result(Expression* node, bool terminates = false) {
      if (!terminates_) {
        return terminates ? eliminator_->terminate(node) : node;
      }
      int c = count();
      if (c == 0) return eliminator_->terminate(null);
      List<Expression*> expressions;
      if (c > 1) expressions = ListBuilder<Expression*>::allocate(c);
      int index = c - 1;
      const Helper* helper = this;
      while (index >= 0) {
        Expression* r = helper->result_;
        helper = helper->previous_;
        if (!r) continue;
        if (c == 1) return eliminator_->terminate(r);
        expressions[index--] = r;
      }
      Sequence* sequence = _new Sequence(expressions, node->range());
      return eliminator_->terminate(sequence);
    }

    void visit(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return;
      Node* result = eliminator_->visit(node, &terminates_);
      if (result) result_ = result->as_Expression();
    }

    void visit_for_value(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return;
      Node* result = eliminator_->visit_for_value(node, &terminates_);
      if (result) result_ = result->as_Expression();
    }

    void visit_for_effect(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return;
      Node* result = eliminator_->visit_for_effect(node, &terminates_);
      if (result) result_ = result->as_Expression();
    }

   private:
    DeadCodeEliminator* const eliminator_;
    Helper* const previous_;

    Expression* result_ = null;
    bool terminates_;

    int count() const {
      int result = 0;
      const Helper* helper = this;
      while (helper != null) {
        if (helper->result_) result++;
        helper = helper->previous_;
      }
      return result;
    }
  };

  DeadCodeEliminator(TypeDatabase* propagated_types)
      : propagated_types_(propagated_types)
      , terminator_(null, Symbol::invalid()) {}

  Node* visit(Node* node, bool* terminates) {
    Node* result = node->accept(this);
    bool is_terminator = (result == &terminator_);
    if (is_terminator) {
      result = terminator_.receiver();
      terminator_.replace_receiver(null);
    }
    if (terminates) *terminates = is_terminator;
    return result;
  }

  Node* visit_for_value(Node* node, bool* terminates) {
    bool old = is_for_value_;
    is_for_value_ = true;
    Node* result = visit(node, terminates);
    is_for_value_ = old;
    return result;
  }

  Node* visit_for_effect(Node* node, bool* terminates) {
    bool old = is_for_value_;
    is_for_value_ = false;
    Node* result = visit(node, terminates);
    is_for_value_ = old;
    return result;
  }

  Node* visit_Expression(Expression* node) {
    UNREACHABLE();
    return null;
  }

  Node* visit_Nop(Nop* node) {
    return null;
  }

  Node* visit_Sequence(Sequence* node) {
    List<Expression*> expressions = node->expressions();
    int length = expressions.length();
    int index = 0;
    bool terminates;
    for (int i = 0; i < length; i++) {
      Expression* entry = expressions[i];
      // ...
      Node* node = (i == length - 1) ? visit(entry, &terminates) : visit_for_effect(entry, &terminates);
      if (node) expressions[index++] = node->as_Expression();
      if (terminates) break;
    }
    Expression* result = (index < length)
        ? _new Sequence(expressions.sublist(0, index), node->range())
        : node;
    return terminates ? terminate(result) : result;
  }

  Node* visit_FieldLoad(FieldLoad* node) {
    Helper helper(this);
    helper.visit(node->receiver());
    return helper.result(node);
  }

  Node* visit_FieldStore(FieldStore* node) {
    Helper helper(this);
    helper.visit_for_value(node->receiver());
    Helper helper2(&helper);
    helper2.visit_for_value(node->value());
    return helper2.result(node);
  }

  Node* visit_Return(Return* node) {
    Helper helper(this);
    helper.visit_for_value(node->value());
    return helper.result(node, true);
  }

  Node* visit_If(If* node) {
    bool terminates;
    Node* condition = visit_for_value(node->condition(), &terminates);
    if (terminates) return terminate(condition ? condition->as_Expression() : null);

    bool terminates_yes;
    Node* yes = visit(node->yes(), &terminates_yes);
    bool terminates_no;
    Node* no = visit(node->no(), &terminates_no);
    if (!terminates_yes && !terminates_no) return node;
    Expression* result = _new If(
        condition->as_Expression(),
        yes ? yes->as_Expression() : _new Nop(node->yes()->range()),
        no  ? no->as_Expression()  : _new Nop(node->no()->range()),
        node->range());
    return (terminates_yes && terminates_no) ? terminate(result) : result;
  }

  Node* visit_Not(Not* node) {
    Helper helper(this);
    helper.visit(node->value());
    return helper.result(node);
  }

  Node* visit_LogicalBinary(LogicalBinary* node) {
    return node;
  }

  Node* visit_TryFinally(TryFinally* node) {
    return node;
  }

  Node* visit_While(While* node) {
    return node;
  }

  Node* visit_LoopBranch(LoopBranch* node) {
    return node;
  }

  Node* visit_Reference(Reference* node) {
    return is_for_effect() ? null : node;
  }

  Node* visit_ReferenceGlobal(ReferenceGlobal* node) {
    // May have side-effects due to lazy initialization.
    return node;
  }

  Node* visit_ReferenceClass(ReferenceClass* node) { return visit_Reference(node); }
  Node* visit_ReferenceMethod(ReferenceMethod* node) { return visit_Reference(node); }
  Node* visit_ReferenceLocal(ReferenceLocal* node) { return visit_Reference(node); }
  Node* visit_ReferenceBlock(ReferenceBlock* node) { return visit_Reference(node); }

  Node* visit_Assignment(Assignment* node) { return node; }
  Node* visit_AssignmentLocal(AssignmentLocal* node) { return visit_Assignment(node); }
  Node* visit_AssignmentGlobal(AssignmentGlobal* node) { return visit_Assignment(node); }
  Node* visit_AssignmentDefine(AssignmentDefine* node) { return visit_Assignment(node); }

  Node* visit_Call(Call* node, Expression* receiver) {
    if (receiver) {
      bool terminates;
      Node* result = visit_for_value(receiver, &terminates);
      if (terminates) return terminate(result ? result->as_Expression() : null);
    }

    List<Expression*> arguments = node->arguments();
    int length = arguments.length();
    bool terminates = false;
    int used = 0;
    while (used < length && !terminates) {
      Node* result = visit_for_value(arguments[used], &terminates);
      arguments[used] = result ? result->as_Expression() : null;
      used++;
    }
    Expression* result = node;
    if (used < length) {
      if (receiver) {
        for (int i = used; i > 0; i++) {
          arguments[i] = arguments[i - 1];
        }
        arguments[0] = receiver;
        used++;
      }
      result = _new Sequence(arguments.sublist(0, used), node->range());
    }
    return terminates ? terminate(result) : result;
  }

  Node* visit_Call(Call* node) {
    return visit_Call(node, null);
  }

  Node* visit_CallVirtual(CallVirtual* node) {
    return visit_Call(node, node->receiver());
  }

  Node* visit_CallStatic(CallStatic* node) {
    Node* result = visit_Call(node, null);
    if (result == &terminator_) return result;
    auto target = node->target()->target();
    if (target->does_not_return()) return terminate(result ? result->as_Expression() : null);
    return result;
  }

  Node* visit_CallConstructor(CallConstructor* node) { return visit_CallStatic(node); }
  Node* visit_Lambda(Lambda* node) { return visit_CallStatic(node); }

  Node* visit_CallBlock(CallBlock* node) { return visit_Call(node, null); }
  Node* visit_CallBuiltin(CallBuiltin* node) { return visit_Call(node, null); }

  Node* visit_PrimitiveInvocation(PrimitiveInvocation* node) { return node; }
  Node* visit_Code(Code* node) { return node; }  // Not entirely sure about this one.

  Node* visit_Typecheck(Typecheck* node) {
    Helper helper(this);
    helper.visit_for_value(node->expression());
    return helper.result(node);
  }

  Node* visit_Super(Super* node) {
    Expression* expression = node->expression();
    if (!expression) return null;
    Helper helper(this);
    helper.visit(expression);
    return helper.result(node);
  }

  Node* visit_Literal(Literal* node) {
    return is_for_effect() ? null : node;
  }

  Node* visit_LiteralNull(LiteralNull* node) { return visit_Literal(node); }
  Node* visit_LiteralUndefined(LiteralUndefined* node) { return visit_Literal(node); }
  Node* visit_LiteralInteger(LiteralInteger* node) { return visit_Literal(node); }
  Node* visit_LiteralFloat(LiteralFloat* node) { return visit_Literal(node); }
  Node* visit_LiteralString(LiteralString* node) { return visit_Literal(node); }
  Node* visit_LiteralByteArray(LiteralByteArray* node) { return visit_Literal(node); }
  Node* visit_LiteralBoolean(LiteralBoolean* node) { return visit_Literal(node); }

  Node* visit_Error(Error* node) { UNREACHABLE(); return null; }
  Node* visit_Program(Program* node) { UNREACHABLE(); return null; }
  Node* visit_Class(Class* node) { UNREACHABLE(); return null; }
  Node* visit_Field(Field* node) { UNREACHABLE(); return null; }
  Node* visit_Local(Local* node) { UNREACHABLE(); return null; }
  Node* visit_Parameter(Parameter* node) { UNREACHABLE(); return null; }
  Node* visit_CapturedLocal(CapturedLocal* node) { UNREACHABLE(); return null; }
  Node* visit_Block(Block* node) { UNREACHABLE(); return null; }
  Node* visit_Builtin(Builtin* node) { UNREACHABLE(); return null; }
  Node* visit_Dot(Dot* node) { UNREACHABLE(); return null; }
  Node* visit_LspSelectionDot(LspSelectionDot* node) { UNREACHABLE(); return null; }

  Node* visit_Method(Method* node) { UNREACHABLE(); return null; }
  Node* visit_MethodInstance(MethodInstance* node) { return visit_Method(node); }
  Node* visit_MonitorMethod(MonitorMethod* node) { return visit_Method(node); }
  Node* visit_MethodStatic(MethodStatic* node) { return visit_Method(node); }
  Node* visit_Constructor(Constructor* node) { return visit_Method(node); }
  Node* visit_Global(Global* node) { return visit_Method(node); }
  Node* visit_AdapterStub(AdapterStub* node) { return visit_Method(node); }
  Node* visit_IsInterfaceStub(IsInterfaceStub* node) { return visit_Method(node); }
  Node* visit_FieldStub(FieldStub* node) { return visit_Method(node); }

 private:
  TypeDatabase* propagated_types_;
  bool is_for_value_ = false;

  bool is_for_value() const { return is_for_value_; }
  bool is_for_effect() const { return !is_for_value_; }

  // ...
  Dot terminator_;

  Node* terminate(Expression* value) {
    terminator_.replace_receiver(value);
    return &terminator_;
  }
};

void eliminate_dead_code(Method* method, TypeDatabase* propagated_types) {
  DeadCodeEliminator eliminator(propagated_types);
  Expression* body = method->body();
  if (body == null) return;

  Node* result = eliminator.visit_for_effect(body, null);
  if (result->is_Expression()) {
    method->replace_body(result->as_Expression());
  } else {
    method->replace_body(_new Nop(method->range()));
  }
}

} // namespace toit::compiler
} // namespace toit
