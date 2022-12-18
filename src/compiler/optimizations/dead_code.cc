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
      if (node && !terminates_) {
        return terminates ? eliminator_->terminate(node) : node;
      }
      int c = count();
      if (c == 0) {
        return terminates_ ? eliminator_->terminate(null) : null;
      }
      List<Expression*> expressions;
      if (c > 1) expressions = ListBuilder<Expression*>::allocate(c);
      int index = c - 1;
      const Helper* helper = this;
      while (index >= 0) {
        Expression* r = helper->result_;
        helper = helper->previous_;
        if (!r) continue;
        if (c == 1) {
          return terminates_ ? eliminator_->terminate(r) : r;
        }
        expressions[index--] = r;
      }
      Sequence* sequence = _new Sequence(expressions, node->range());
      return terminates_ ? eliminator_->terminate(sequence) : sequence;
    }

    Expression* visit(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Node* result = eliminator_->visit(node, &terminates_);
      if (!result) return node;
      return result_ = result->as_Expression();
    }

    Expression* visit_for_value(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Node* result = eliminator_->visit_for_value(node, &terminates_);
      if (!result) return node;
      return result_ = result->as_Expression();
    }

    Expression* visit_for_effect(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Node* result = eliminator_->visit_for_effect(node, &terminates_);
      if (!result) return node;
      return result_ = result->as_Expression();
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
    bool terminates = false;
    for (int i = 0; i < length; i++) {
      Expression* entry = expressions[i];
      // TODO(kasper): Explain this to me now! ...
      Node* node = (i == length - 1)
          ? visit(entry, &terminates)
          : visit_for_effect(entry, &terminates);
      if (node) expressions[index++] = node->as_Expression();
      if (terminates) break;
    }
    // TODO(kasper): Maybe return null if index is 0?
    if (index < length) {
      node->replace_expressions(expressions.sublist(0, index));
    }
    return terminates ? terminate(node) : node;
  }

  Node* visit_FieldLoad(FieldLoad* node) {
    Helper helper(this);
    node->replace_receiver(helper.visit(node->receiver()));
    return helper.result(is_for_effect() ? null : node);
  }

  Node* visit_FieldStore(FieldStore* node) {
    Helper helper(this);
    node->replace_receiver(helper.visit_for_value(node->receiver()));
    Helper helper2(&helper);
    node->replace_value(helper2.visit_for_value(node->value()));
    return helper2.result(node);
  }

  Node* visit_Return(Return* node) {
    Helper helper(this);
    node->replace_value(helper.visit_for_value(node->value()));
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

    node->replace_condition(condition->as_Expression());
    node->replace_yes(yes ? yes->as_Expression() : _new Nop(node->yes()->range()));
    node->replace_no(no ? no->as_Expression() : _new Nop(node->no()->range()));
    return (terminates_yes && terminates_no) ? terminate(node) : node;
  }

  Node* visit_Not(Not* node) {
    Helper helper(this);
    node->replace_value(helper.visit(node->value()));
    return helper.result(is_for_effect() ? null : node);
  }

  Node* visit_LogicalBinary(LogicalBinary* node) {
    bool terminates;
    Node* left = visit_for_value(node->left(), &terminates);
    if (terminates) return terminate(left ? left->as_Expression() : null);

    Node* right = visit(node->right(), null);
    node->replace_left(left->as_Expression());
    node->replace_right(right ? right->as_Expression() : _new Nop(node->right()->range()));
    return node;
  }

  Node* visit_TryFinally(TryFinally* node) {
    node->body()->accept(this);
    bool terminates;
    Node* handler = visit_for_effect(node->handler(), &terminates);
    node->replace_handler(handler ? handler->as_Expression() : _new Nop(node->handler()->range()));
    return terminates ? terminate(node) : node;
  }

  Node* visit_While(While* node) {
    bool terminates;
    Node* condition = visit_for_value(node->condition(), &terminates);
    if (terminates) return terminate(condition ? condition->as_Expression() : null);

    Node* body = visit(node->body(), null);
    Node* update = visit(node->update(), null);
    node->replace_condition(condition->as_Expression());
    node->replace_body(body ? body->as_Expression() : _new Nop(node->body()->range()));
    node->replace_update(update ? update->as_Expression() : _new Nop(node->update()->range()));
    return node;
  }

  Node* visit_LoopBranch(LoopBranch* node) {
    return terminate(node);
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

  Node* visit_Assignment(Assignment* node) {
    Helper helper(this);
    node->replace_right(helper.visit_for_value(node->right()));
    return helper.result(node);
  }

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
        for (int i = used; i > 0; i--) {
          arguments[i] = arguments[i - 1];
        }
        arguments[0] = receiver;
        used++;
      }
      result = _new Sequence(arguments.sublist(0, used), node->range());
    }

    if (!terminates && propagated_types_ != null && !node->is_CallBuiltin()) {
      terminates = propagated_types_->does_not_return(node);
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

  Node* visit_Code(Code* node) {
    Node* result = visit_for_value(node->body(), null);
    if (result) {
      node->replace_body(result->as_Expression());
    } else {
      node->replace_body(_new Nop(node->range()));
    }
    return node;
  }

  Node* visit_Typecheck(Typecheck* node) {
    Helper helper(this);
    node->replace_expression(helper.visit_for_value(node->expression()));
    return helper.result(node);
  }

  Node* visit_Super(Super* node) {
    Expression* expression = node->expression();
    if (!expression) return null;
    Helper helper(this);
    node->replace_expression(helper.visit(expression));
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
  if (result) {
    method->replace_body(result->as_Expression());
  } else {
    method->replace_body(_new Nop(method->range()));
  }
}

} // namespace toit::compiler
} // namespace toit
