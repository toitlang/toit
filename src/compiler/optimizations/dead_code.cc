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

    Node* result(Expression* expression, bool terminates = false) {
      // If the expression wasn't eliminated and evaluating the
      // intermediate parts didn't terminate, we return the
      // expression possibly tagged as terminating if the expression
      // is a return.
      if (expression && !terminates_) return eliminator_->tag(expression, terminates);
      // If we didn't gather any results, we return null.
      int count = this->count();
      if (count == 0) return eliminator_->tag(null, terminates_);
      // Run through the gathered results and build a sequence of
      // them. Optimize for the common case where we don't need to
      // build a new list for the result because it is a single
      // value that we can just tag.
      List<Expression*> expressions;
      if (count > 1) expressions = ListBuilder<Expression*>::allocate(count);
      int index = count - 1;  // List is filled from the back.
      const Helper* helper = this;
      while (index >= 0) {
        Expression* result = helper->result_;
        helper = helper->previous_;
        if (!result) continue;
        if (count == 1) return eliminator_->tag(result, terminates_);
        expressions[index] = result;
        index--;
      }
      Sequence* sequence = _new Sequence(expressions, expression->range());
      return eliminator_->tag(sequence, terminates_);
    }

    Expression* visit(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Expression* result = eliminator_->visit(node, &terminates_);
      result_ = result;
      return result;
    }

    Expression* visit_for_value(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Expression* result = eliminator_->visit_for_value(node, &terminates_);
      result_ = result;
      return result;
    }

    Expression* visit_for_effect(Expression* node) {
      ASSERT(result_ == null);
      if (terminates_) return node;
      Expression* result = eliminator_->visit_for_effect(node, &terminates_);
      result_ = result;
      return result;
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

  Expression* visit(Expression* node, bool* terminates) {
    Node* result = node->accept(this);
    bool is_terminator = (result == &terminator_);
    if (is_terminator) {
      result = terminator_.receiver();
      terminator_.replace_receiver(null);
    }
    if (terminates) *terminates = is_terminator;
    return result ? result->as_Expression() : null;
  }

  Expression* visit_for_value(Expression* node, bool* terminates) {
    bool old = is_for_value_;
    is_for_value_ = true;
    Expression* result = visit(node, terminates);
    is_for_value_ = old;
    return result;
  }

  Expression* visit_for_effect(Expression* node, bool* terminates) {
    bool old = is_for_value_;
    is_for_value_ = false;
    Expression* result = visit(node, terminates);
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
      // Visit the last expression in the sequence in the same
      // state as we visit the sequence, so we produce a value
      // if necessary. The other expressions just need to be
      // evaluated for effect.
      Expression* visited = (i == length - 1)
          ? visit(entry, &terminates)
          : visit_for_effect(entry, &terminates);
      if (visited) expressions[index++] = visited;
      if (terminates) break;
    }
    if (index == 0) {
      node = null;
    } else if (index < length) {
      node->replace_expressions(expressions.sublist(0, index));
    }
    return tag(node, terminates);
  }

  Node* visit_FieldLoad(FieldLoad* node) {
    Helper helper(this);
    node->replace_receiver(helper.visit(node->receiver()));
    return helper.result(is_for_effect() ? null : node);
  }

  Node* visit_FieldStore(FieldStore* node) {
    Helper receiver_helper(this);
    node->replace_receiver(receiver_helper.visit_for_value(node->receiver()));
    Helper value_helper(&receiver_helper);
    node->replace_value(value_helper.visit_for_value(node->value()));
    return value_helper.result(node);
  }

  Node* visit_Return(Return* node) {
    Helper helper(this);
    node->replace_value(helper.visit_for_value(node->value()));
    return helper.result(node, true);
  }

  Node* visit_If(If* node) {
    bool terminates;
    Expression* condition = visit_for_value(node->condition(), &terminates);
    if (terminates) return terminate(condition);

    bool terminates_yes;
    Expression* yes = visit(node->yes(), &terminates_yes);
    bool terminates_no;
    Expression* no = visit(node->no(), &terminates_no);

    node->replace_condition(condition);
    node->replace_yes(yes ? yes : _new Nop(node->yes()->range()));
    node->replace_no(no ? no : _new Nop(node->no()->range()));
    return tag(node, terminates_yes && terminates_no);
  }

  Node* visit_Not(Not* node) {
    Helper helper(this);
    node->replace_value(helper.visit(node->value()));
    return helper.result(is_for_effect() ? null : node);
  }

  Node* visit_LogicalBinary(LogicalBinary* node) {
    bool terminates;
    Expression* left = visit_for_value(node->left(), &terminates);
    if (terminates) return terminate(left);

    Expression* right = visit(node->right(), null);
    node->replace_left(left);
    node->replace_right(right ? right : _new Nop(node->right()->range()));
    return node;
  }

  Node* visit_TryFinally(TryFinally* node) {
    node->body()->accept(this);
    bool terminates;
    Expression* handler = visit_for_effect(node->handler(), &terminates);
    node->replace_handler(handler ? handler : _new Nop(node->handler()->range()));
    return tag(node, terminates);
  }

  Node* visit_While(While* node) {
    bool terminates;
    Expression* condition = visit_for_value(node->condition(), &terminates);
    if (terminates) return terminate(condition);

    Expression* body = visit(node->body(), null);
    Expression* update = visit(node->update(), null);
    node->replace_condition(condition);
    node->replace_body(body ? body : _new Nop(node->body()->range()));
    node->replace_update(update ? update : _new Nop(node->update()->range()));
    return node;
  }

  Node* visit_LoopBranch(LoopBranch* node) {
    return terminate(node);
  }

  Node* visit_Reference(Reference* node) {
    return is_for_effect() ? null : node;
  }

  Node* visit_ReferenceGlobal(ReferenceGlobal* node) {
    Global* global = node->target();
    if (global->is_dead()) {
      return is_for_effect() ? terminate(null) : terminate(_new Nop(node->range()));
    }
    return (global->is_lazy() || is_for_value()) ? node : null;
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
  Node* visit_AssignmentDefine(AssignmentDefine* node) { return visit_Assignment(node); }

  Node* visit_AssignmentGlobal(AssignmentGlobal* node) {
    Global* global = node->global();
    if (global->is_dead()) {
      return terminate(visit(node->right(), null));
    } else {
      return visit_Assignment(node);
    }
  }

  Node* visit_Call(Call* node, Expression* receiver) {
    if (receiver) {
      bool terminates;
      Expression* result = visit_for_value(receiver, &terminates);
      // If evaluating the receiver always terminates, then we turn the
      // entire call into just the receiver evaluation without looking
      // at the arguments at all.
      if (terminates) return terminate(result);
    }

    // Now, we run thrugh the arguments until one of them (if any)
    // terminates. We count the number of arguments we've visited
    // and used, so we can turn the call into a sequence if the
    // evaluation of one of the arguments terminates the evaluation
    // of the arguments abruptly.
    List<Expression*> arguments = node->arguments();
    int length = arguments.length();
    bool terminates = false;
    int used = 0;
    while (used < length && !terminates) {
      Expression* result = visit_for_value(arguments[used], &terminates);
      arguments[used] = result;
      used++;
    }

    Expression* result = node;
    if (used < length) {
      // Not all the arguments were used, so we need to turn the
      // call into a sequence. If we have a receiver, we put it
      // in as the first element in the sequence by shifting the
      // arguments up.
      if (receiver) {
        for (int i = used; i > 0; i--) arguments[i] = arguments[i - 1];
        arguments[0] = receiver;
        used++;
      }
      result = _new Sequence(arguments.sublist(0, used), node->range());
      ASSERT(terminates);
    } else if (propagated_types_ != null && !node->is_CallBuiltin()) {
      // If we have propagated type information, we might know that
      // this call does not return. If so, we make sure to tag the
      // result correctly, so we drop code that follows the call.
      terminates = propagated_types_->does_not_return(node);
    }
    return tag(result, terminates);
  }

  Node* visit_Call(Call* node) {
    return visit_Call(node, null);
  }

  Node* visit_CallVirtual(CallVirtual* node) {
    return visit_Call(node, node->receiver());
  }

  Node* visit_CallStatic(CallStatic* node) {
    if (node->target()->target()->is_dead()) {
      List<Expression*> arguments = node->arguments();
      int length = arguments.length();
      int index = 0;
      for (int i = 0; i < length; i++) {
        bool terminates = false;
        Expression* result = visit_for_effect(arguments[i], &terminates);
        if (result) arguments[index++] = result;
        if (terminates) break;
      }
      if (index == 0) {
        return is_for_effect() ? terminate(null) : terminate(_new Nop(node->range()));
      } else {
        return terminate(_new Sequence(arguments.sublist(0, index), node->range()));
      }
    }

    Node* result = visit_Call(node, null);
    if (result == &terminator_) return result;
    Expression* call = result ? result->as_Expression() : null;
    // For some methods, we statically know that they
    // are not going to return (think: throw).
    auto target = node->target()->target();
    return tag(call, target->does_not_return());
  }

  Node* visit_CallConstructor(CallConstructor* node) { return visit_CallStatic(node); }
  Node* visit_Lambda(Lambda* node) { return visit_CallStatic(node); }
  Node* visit_CallBlock(CallBlock* node) { return visit_Call(node, null); }
  Node* visit_CallBuiltin(CallBuiltin* node) { return visit_Call(node, null); }

  Node* visit_PrimitiveInvocation(PrimitiveInvocation* node) { return node; }

  Node* visit_Code(Code* node) {
    Expression* result = null;
    if (!node->is_dead()) result = visit_for_value(node->body(), null);
    node->replace_body(result ? result : _new Nop(node->range()));
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

  // We use a recognizable marker for the expressions that
  // terminate. This way, we can continue to return Node*
  // but still tell if an expression is guaranteed to
  // terminate abruptly.
  Dot terminator_;

  Node* tag(Expression* value, bool terminates) {
    return terminates ? terminate(value) : value;
  }

  Node* terminate(Expression* value) {
    terminator_.replace_receiver(value);
    return &terminator_;
  }
};

void eliminate_dead_code(Method* method, TypeDatabase* propagated_types) {
  DeadCodeEliminator eliminator(propagated_types);
  Expression* body = method->body();
  if (body == null) return;

  Expression* result = eliminator.visit_for_effect(body, null);
  method->replace_body(result ? result : _new Nop(method->range()));
}

} // namespace toit::compiler
} // namespace toit
