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

#include "type_check.h"

#include <stdarg.h>

#include "cycle_detector.h"
#include "deprecation.h"
#include "diagnostic.h"
#include "ir.h"
#include "lsp/lsp.h"
#include "no_such_method.h"
#include "queryable_class.h"
#include "toitdoc.h"

namespace toit {
namespace compiler {

using namespace ir;

static bool is_arithmetic_operation(const Selector<CallShape>& selector) {
  if (selector.shape() != CallShape(1).with_implicit_this()) return false;
  auto name = selector.name();
  return name == Token::symbol(Token::ADD) ||
         name == Token::symbol(Token::SUB) ||
         name == Token::symbol(Token::MUL) ||
         name == Token::symbol(Token::DIV) ||
         name == Token::symbol(Token::MOD);
}

class TypeChecker : public ReturningVisitor<Type> {
 public:
  TypeChecker(List<Type> literal_types,
              List<ir::Class*> classes,
              const UnorderedMap<ir::Class*, QueryableClass>* queryables,
              const Set<ir::Node*>* deprecated,
              Lsp* lsp,
              Diagnostics* diagnostics)
      : classes_(classes)
      , queryables_(queryables)
      , deprecated_(deprecated)
      , lsp_(lsp)
      , diagnostics_(diagnostics)
      , method_(null)
      , boolean_type_(Type::invalid())
      , integer_type_(Type::invalid())
      , float_type_(Type::invalid())
      , string_type_(Type::invalid())
      , null_type_(Type::invalid()) {

    auto find_type = [=](Symbol symbol) {
      for (auto literal_type : literal_types) {
        if (literal_type.klass()->name() == symbol) return literal_type;
      }
      FATAL("Couldn't find literal type");
      return Type::invalid();
    };

    boolean_type_ = find_type(Symbols::bool_);
    integer_type_ = find_type(Symbols::int_);
    float_type_ = find_type(Symbols::float_);
    string_type_ = find_type(Symbols::string);
    null_type_ = find_type(Symbols::Null_).to_nullable();
  }

  Type visit(Node* node) {
    return node->accept(this);
  }


  Type visit_Program(Program* node) {
    // Visit globals first.
    // While traversing we are inferring their type which will then be used in the
    // other visits.
    for (auto global: node->globals()) visit(global);
    for (auto klass: node->classes()) visit(klass);
    for (auto method: node->methods()) visit(method);
    return Type::invalid();
  }

  Type visit_Class(Class* node) {
    // Constructors and factories are already visited in `visit_Program` as
    // global methods.
    // Fields don't have any code anymore, since all of the initialization is
    // in the constructors.
    for (auto method: node->methods()) visit(method);
    return Type::invalid();
  }

  Type visit_Field(Field* node) { UNREACHABLE(); return Type::invalid(); }

  // Methods are only visited for their side-effect.
  // In theory there should be no user of these types, and they all return `Type::invalid`.
  // The return-type is extracted when the methods are referenced.
  Type visit_Method(Method* node) {
    method_ = node;
    if (node->has_body()) visit(node->body());
    return Type::invalid();
  }
  // Globals are handled like methods. As such, they are only visited for the side-effect.
  // Their return type should not be used and they all return `Type::invalid`.
  // References to globals extract the return-type.
  Type visit_Global(Global* node) {
    if (handled_globals_.contains(node)) return Type::invalid();
    if (node->has_explicit_type()) {
      visit_Method(node);
      handled_globals_.insert(node);
      return Type::invalid();
    }
    if (reported_cyclic_globals_.contains(node)) {
      return Type::invalid();
    }
    bool detected_cycle = globals_cycle_detector_.check_cycle(node, [&](const std::vector<ir::Global*>& cycle) {
      report_cyclic_global_types(cycle);
      reported_cyclic_globals_.insert(node);
    });
    if (detected_cycle) return Type::invalid();
    method_ = node;
    // TODO(florian): this is a bit hacky, but we have already rewritten the expression of
    // the global, so we need to extract it now again.
    auto body = node->body();
    TOIT_CHECK(body->is_Sequence());
    auto expressions = body->as_Sequence()->expressions();
    TOIT_CHECK(expressions.length() == 1);
    auto last = expressions.last();
    if (last->is_CallStatic()) {
      // Call to "uninitialized_global_failure_".
      TOIT_CHECK(last->as_CallStatic()->target()->as_ReferenceMethod()->target()->name() == Symbols::uninitialized_global_failure_);
      // The uninitialized_global_failure_ call references its own global recursively.
      // Mark the node as handled already now and give it the 'any' type.
      // Alternatively, we could also just not visit the body.
      handled_globals_.insert(node);
      node->set_return_type(Type::any());
      visit(node->body());
      return Type::invalid();
    }
    globals_cycle_detector_.start(node);
    TOIT_CHECK(last->is_Return());
    auto ret = last->as_Return();
    auto value_type = visit(ret->value());
    if (value_type.is_none()) {
      report_error(ret->value()->range(), "Globals can't be initialized with 'none'");
      node->set_return_type(Type::any());
    } else if (ret->value()->is_LiteralNull()) {
      node->set_return_type(Type::any());
    } else {
      node->set_return_type(value_type);
    }
    globals_cycle_detector_.stop(node);
    handled_globals_.insert(node);
    return Type::invalid();
  }

  Type visit_MethodInstance(MethodInstance* node) { return visit_Method(node); }
  Type visit_MonitorMethod(MonitorMethod* node) { return visit_Method(node); }
  Type visit_MethodStatic(MethodStatic* node) { return visit_Method(node); }
  Type visit_Constructor(Constructor* node) { return visit_Method(node); }
  Type visit_AdapterStub(AdapterStub* node) { return visit_Method(node); }
  Type visit_IsInterfaceStub(IsInterfaceStub* node) { return visit_Method(node); }
  Type visit_FieldStub(FieldStub* node) { return visit_Method(node); }

  Type visit_Expression(Expression* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_Error(Error* node) {
    for (auto expr : node->nested()) {
      visit(expr);
    }
    return Type::any();
  }

  Type visit_Nop(Nop* node) { return Type::any(); }

  Type visit_FieldStore(FieldStore* node) {
    auto field = node->field();
    if (!method_->is_constructor()) {
      // Don't report warnings for fields that are assigned in the constructor.
      // We would like to report warnings for explicit assignments, but we
      // don't have that information anymore. So we assume that it's the
      // initialization and don't report it.
      check_deprecated(node->range(), field);
    }
    auto value_type = visit(node->value());
    check(node->range(), field->type(), value_type);
    return value_type;
  }

  Type visit_FieldLoad(FieldLoad* node) {
    check_deprecated(node->range(), node->field());
    return node->field()->type();
  }

  Type visit_Sequence(Sequence* node) {
    auto result_type = Type::any();
    for (auto expr : node->expressions()) {
      result_type = visit(expr);
    }
    return result_type;
  }

  Type visit_Builtin(Builtin* node) {
    // The `visit_CallBuiltin` will improve the type of the calls.
    return Type::any();
  }

  Type visit_TryFinally(TryFinally* node) {
    visit(node->body());
    for (int i = 0; i < node->handler_parameters().length(); i++) {
      auto parameter = node->handler_parameters()[i];
      if (!parameter->has_explicit_type()) {
        parameter->set_type(Type::any());
      }
    }
    visit(node->handler());
    // TODO(florian): return the type of the body once #83 is fixed.
    // TODO(florian): should be 'null'-type for now.
    return Type::any();
  }

  Type visit_If(If* node) {
    auto condition_type = visit(node->condition());
    if (condition_type.is_none()) {
      report_error(node->condition()->range(), "Condition can't be 'none'");
    } else if (condition_type != boolean_type_ &&
               condition_type.is_class() &&
               !condition_type.is_nullable()) {
      report_warning(node->range(), "Condition always evaluates to true");
    }
    auto yes_type = visit(node->yes());
    auto no_type = visit(node->no());
    return merge_types(yes_type, no_type);
  }

  Type visit_Not(Not* node) {
    auto value_type = visit(node->value());
    if (value_type.is_none()) {
      report_error(node->value()->range(), "Argument to 'not' can't be 'none'");
    }
    return boolean_type_;
  }

  Type visit_While(While* node) {
    auto condition_type = visit(node->condition());
    if (condition_type.is_none()) {
      report_error(node->condition()->range(), "Condition can't be 'none'");
    } else if (condition_type != boolean_type_ &&
               condition_type.is_class() &&
               !condition_type.is_nullable()) {
      report_warning(node->range(), "Condition always evaluates to true");
    }
    auto result_type = visit(node->body());
    visit(node->update());
    return result_type;
  }

  Type visit_LoopBranch(LoopBranch* node) {
    // TODO(florian): should be 'null'-type.
    return Type::any();
  }

  Type visit_Code(Code* node) {
    visit(node->body());
    // TODO(florian); should be a "Block" or "Code" type.
    return Type::any();
  }

  Type visit_Reference(Reference* node) { UNREACHABLE(); return Type::invalid(); }

  Type visit_ReferenceClass(ReferenceClass* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_ReferenceMethod(ReferenceMethod* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_ReferenceLocal(ReferenceLocal* node) {
    return node->target()->type();
  }
  Type visit_ReferenceBlock(ReferenceBlock* node) { return visit_ReferenceLocal(node); }
  Type visit_ReferenceGlobal(ReferenceGlobal* node) {
    check_deprecated(node->range(), node->target());
    auto target = node->target();
    // The second test (whether the method_ is a global) is just a shortcut, as a non-global 'method_'
    // mean that we already handled all of them.
    if (target->has_explicit_type() || !method_->is_Global()) {
      return target->return_type();
    }
    auto current_method = method_;
    visit_Global(target);
    method_ = current_method;
    auto type = target->return_type();
    if (!type.is_valid()) {
      ASSERT(diagnostics()->encountered_error());
      return Type::any();
    }
    return type;
  }

  Type visit_Local(Local* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_Parameter(Parameter* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_CapturedLocal(CapturedLocal* node) { UNREACHABLE(); return Type::invalid(); }
  Type visit_Block(Block* node) { UNREACHABLE(); return Type::invalid(); }

  Type visit_Dot(Dot* node) {
    return visit(node->receiver());
  }

  Type visit_LspSelectionDot(LspSelectionDot* node) {
    // The target must be handled by the virtual call.
    return visit_Dot(node);
  }

  Type visit_Super(Super* node) {
    if (node->expression() == null) return Type::any();
    return visit(node->expression());
  }

  Type visit_Call(Call* node) {
    visit(node->target());
    for (auto argument : node->arguments()) visit(argument);
    return Type::any();
  }

  Type visit_CallStatic(CallStatic* node) {
    auto arguments = node->arguments();
    auto argument_types = ListBuilder<Type>::allocate(arguments.length());
    for (int i = 0; i < arguments.length(); i++) {
      argument_types[i] = visit(arguments[i]);
    }
    auto target = node->target();
    auto method = target->target();
    check_deprecated(target->range(), method);
    auto parameters = method->parameters();
    int parameter_offset = node->is_CallConstructor() ? 1 : 0;
    if (arguments.length() + parameter_offset != parameters.length()) {
      ASSERT(method->is_setter());  // We already reported an error for this.
    } else {
      for (int i = 0; i < arguments.length(); i++) {
        // TODO(florian): provide more context in the error message.
        auto parameter = parameters[i + parameter_offset];
        auto parameter_type = parameter->type();
        if (parameter->has_default_value()) parameter_type = parameter_type.to_nullable();
        check(arguments[i]->range(), parameter_type, argument_types[i]);
      }
    }
    return method->return_type();
  }

  Type visit_Lambda(Lambda* node) { return visit_CallStatic(node); }
  Type visit_CallConstructor(CallConstructor* node) {
    return visit_CallStatic(node);
  }

  Type visit_CallVirtual(CallVirtual* node) {
    bool is_lsp_selection = node->target()->is_LspSelectionDot();

    auto receiver_type = visit(node->receiver());
    if (is_lsp_selection) {
      lsp_->selection_handler()->call_virtual(node, receiver_type, classes_);
    }
    auto arguments = node->arguments();

    if (receiver_type.is_any()) {
      for (auto argument : arguments) visit(argument);
      return Type::any();
    }

    if (receiver_type.is_none()) {
      report_error(node->range(), "Can't invoke method on 'none' type");
      return Type::any();
    }
    if (!node->selector().is_valid()) {
      ASSERT(diagnostics()->encountered_error());
      return Type::any();
    }

    bool is_equals_call = (node->selector() == Token::symbol(Token::EQ) &&
                           node->shape() == CallShape(1).with_implicit_this());

    auto argument_types = ListBuilder<Type>::allocate(arguments.length());
    for (int i = 0; i < arguments.length(); i++) {
      argument_types[i] = visit(arguments[i]);
    }
    ASSERT(receiver_type.is_class());
    auto klass = receiver_type.klass();
    Selector<CallShape> selector(node->selector(), node->shape());
    auto queryable = queryables_->at(klass);
    auto method = queryable.lookup(selector);
    if (method == null) {
      report_no_such_instance_method(klass, selector, node->range(), diagnostics());
      return Type::any();
    }

    check_deprecated(node->range(), method);

    auto parameters = method->parameters();
    int argument_offset = 1;  // For the receiver, which is given as first argument.
    CallBuilder::match_arguments_with_parameters(node->shape(),
                                                 method->resolution_shape(),
                                                 [&](int argument_pos, int parameter_pos) {
      if (argument_pos == 0) return;  // The `this` parameter.
      auto argument = arguments[argument_pos - argument_offset];
      auto argument_type = argument_types[argument_pos - argument_offset];
      auto parameter_type = parameters[parameter_pos]->type();
      if (parameters[parameter_pos]->has_default_value()) parameter_type = parameter_type.to_nullable();

      // The interpreter shortcuts the `null` equality, and the argument type thus
      //   can effectively be nullable.
      if (is_equals_call) parameter_type = parameter_type.to_nullable();

      // TODO(florian): provide more context in the error message.
      check(argument->range(), parameter_type, argument_type);
    });
    if (method->is_FieldStub() && method->is_setter()) {
      auto field = method->as_FieldStub()->field();
      if (field->is_final()) {
        report_error(node->range(),
                     "Can't assign to final field '%s'",
                     field->name().c_str());
      }
      if (!argument_types[0].is_any()) {
        // We assume that the argument is more precise than the return-type of
        // the store.
        // If it isn't then we would already have reported an error earlier.
        return argument_types[0];
      }
    }
    if (is_arithmetic_operation(selector)) {
      if (receiver_type == integer_type_) {
        if (argument_types[0] == integer_type_) return integer_type_;
        if (argument_types[0] == float_type_) return float_type_;
      }
    }
    return method->return_type();
  }

  Type visit_CallBlock(CallBlock* node) { return visit_Call(node); }

  Type visit_CallBuiltin(CallBuiltin* node) {
    if (node->target()->kind() == Builtin::STORE_GLOBAL) {
      if (node->arguments().length() == 2) {
        auto index_type = visit(node->arguments()[0]);
        check(node->range(), integer_type_, index_type);
        return visit(node->arguments()[1]);
      }
    }

    visit_Call(node);
    switch (node->target()->kind()) {
      case Builtin::THROW:
      case Builtin::HALT:
      case Builtin::EXIT:
        // These are not returning.
        return Type::none();

      case Builtin::INVOKE_LAMBDA:
        return Type::any();

      case Builtin::YIELD:
      case Builtin::DEEP_SLEEP:
        // The result of yield and sleep should not be used.
        return Type::none();

      case Builtin::STORE_GLOBAL:
        return Type::none();

      case Builtin::LOAD_GLOBAL:
        return Type::any();

      case Builtin::INVOKE_INITIALIZER:
        return Type::any();

      case Builtin::GLOBAL_ID:
        ASSERT(node->arguments().length() == 1 && node->arguments()[0]->is_ReferenceGlobal());
        return integer_type_;

      case Builtin::IDENTICAL:
        return boolean_type_;
    };
    UNREACHABLE();
  }

  Type visit_Typecheck(Typecheck* node) {
    auto expression_type = visit(node->expression());
    switch (node->kind()) {
      case Typecheck::IS_CHECK:
        return boolean_type_;
      case Typecheck::AS_CHECK:
        return node->type();
      case Typecheck::PARAMETER_AS_CHECK:
      case Typecheck::LOCAL_AS_CHECK:
      case Typecheck::RETURN_AS_CHECK:
      case Typecheck::FIELD_INITIALIZER_AS_CHECK:
      case Typecheck::FIELD_AS_CHECK:
        // We are not using the type of the check, as we want to give
        //   warnings if the expression type and the checked type don't match.
        return expression_type;
    }
    UNREACHABLE();
    return Type::invalid();
  }

  Type visit_Return(Return* node) {
    auto value_type = visit(node->value());
    if (node->depth() == -1) {
      check(node->range(), method_->return_type(), value_type);
    }
    return Type::none();
  }

  Type visit_LogicalBinary(LogicalBinary* node) {
    Type left_type = visit(node->left());
    Type right_type = visit(node->right());
    if (left_type.is_none()) {
      report_error(node->left()->range(), "Logical operation argument can't be 'none'");
    }
    if (right_type.is_none()) {
      report_error(node->right()->range(), "Logical operation argument can't be 'none'");
    }
    // Logical operators return the last computed value.
    // Frequently this will be the boolean type, but not always.
    if (left_type == right_type) return left_type;
    return Type::any();
  }

  Type visit_Assignment(Assignment* node) { UNREACHABLE(); return Type::invalid(); }

  Type visit_AssignmentDefine(AssignmentDefine* node) {
    auto local = node->local();
    auto right_type = visit(node->right());
    if (local->has_explicit_type()) {
      check(node->range(), local->type(), right_type);
    } else if (right_type.is_none()) {
      report_error(node->right()->range(), "Variable can't be initialized with 'none'");
      local->set_type(Type::any());
    } else {
      if (node->right()->is_LiteralNull()) {
        local->set_type(Type::any());
      } else {
        local->set_type(right_type);
      }
    }
    return right_type;
  }

  Type visit_AssignmentLocal(AssignmentLocal* node) {
    auto local = node->local();
    auto right_type = visit(node->right());
    if (local->type().is_any() && right_type.is_none()) {
      // TODO(florian): check that 'none' types aren't used.
      // report_error(node->right()->range(), "Can't use value of type 'none'");
    } else {
      check(node->range(), local->type(), right_type);
    }
    return right_type;
  }

  Type visit_AssignmentGlobal(AssignmentGlobal* node) {
    auto global = node->global();
    check_deprecated(node->range(), global);
    auto right_type = visit(node->right());
    if (global->return_type().is_any() && right_type.is_none()) {
      // TODO(florian): check that 'none' types aren't used.
      // report_error(node->right()->range(), "Can't use value of type 'none'");
    } else {
      check(node->range(), global->return_type(), right_type);
    }
    return right_type;
  }

  Type visit_Literal(Literal* node) { UNREACHABLE(); return Type::invalid(); }

  Type visit_LiteralNull(LiteralNull* node) {
    return null_type_;
  }
  Type visit_LiteralUndefined(LiteralUndefined* node) {
    // TODO(florian): should have the type of the corresponding assignments.
    return Type::any();
  }
  Type visit_LiteralInteger(LiteralInteger* node) {
    return integer_type_;
  }
  Type visit_LiteralFloat(LiteralFloat* node) {
    return float_type_;
  }
  Type visit_LiteralString(LiteralString* node) {
    return string_type_;
  }
  Type visit_LiteralBoolean(LiteralBoolean* node) {
    return boolean_type_;
  }
  Type visit_LiteralByteArray(LiteralByteArray* node) {
    return Type::any();
  }


  Type visit_PrimitiveInvocation(PrimitiveInvocation* node) {
    // TODO(florian): get the type of primitive invocations.
    return Type::any();
  }

 private:
  List<ir::Class*> classes_;
  const UnorderedMap<ir::Class*, QueryableClass>* queryables_;
  const Set<ir::Node*>* deprecated_;
  Lsp* lsp_;
  Diagnostics* diagnostics_;

  // Since globals can be visited out of order (recursively), we need to
  // keep track which globals are already fully done.
  Set<ir::Global*> handled_globals_;
  CycleDetector<ir::Global*> globals_cycle_detector_;
  UnorderedSet<ir::Global*> reported_cyclic_globals_;

  // The current method.
  Method* method_;

  Type boolean_type_;
  Type integer_type_;
  Type float_type_;
  Type string_type_;
  Type null_type_;

  Diagnostics* diagnostics() const { return diagnostics_; }

  void report_error(Source::Range range, const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    diagnostics()->report_error(range, format, arguments);
    va_end(arguments);
  }

  void report_warning(Source::Range range, const char* format, ...) {
    va_list arguments;
    va_start(arguments, format);
    diagnostics()->report_warning(range, format, arguments);
    va_end(arguments);
  }

  void report_cyclic_global_types(const std::vector<ir::Global*>& cycle) {
    for (auto global : cycle) {
      diagnostics()->start_group();
      diagnostics()->report_error(global->range(), "Cyclic type dependency");
      for (auto cyclic : cycle) {
        if (cyclic == global) continue;
        diagnostics()->report_note(cyclic->range(), "This global contributes to the type-dependency cycle");
      }
      diagnostics()->end_group();
    }
  }

  void check_deprecated(Source::Range range, ir::Node* node) {
    // Don't give warnings for synthetic stubs.
    if (method_->is_FieldStub()) return;
    auto name = Symbol::invalid();
    auto holder_name = Symbol::invalid();
    Class* holder;
    if (node->is_FieldStub()) {
      node = node->as_FieldStub()->field();
    }
    bool is_deprecated = deprecated_->contains(node);
    if (node->is_Method()) {
      auto method = node->as_Method();
      name = method->name();
      holder = method->holder();
      bool holder_is_deprecated = false;
      if (holder != null) {
        holder_is_deprecated = deprecated_->contains(holder);
        holder_name = holder->name();
      }
      if (method->is_constructor() || method->is_factory()) {
        if (holder_is_deprecated) {
          ASSERT(name.is_valid());
          report_warning(range, "Class '%s' is deprecated", holder_name.c_str());
        } else if (is_deprecated) {
          if (name == Symbols::constructor) {
            report_warning(range, "Deprecated constructor of '%s'", holder_name.c_str());
          } else {
            report_warning(range, "Deprecated constructor '%s.%s'", holder_name.c_str(), name.c_str());
          }
        }
        return;
      }
    } else {
      ASSERT(node->is_Field());
      auto field = node->as_Field();
      name = field->name();
      holder = field->holder();
      if (holder != null) {
        holder_name = holder->name();
      }
    }
    if (is_deprecated) {
      if (holder_name.is_valid()) {
        report_warning(range, "Deprecated '%s.%s'", holder_name.c_str(), name.c_str());
      } else {
        report_warning(range, "Deprecated '%s'", name.c_str());
      }
    }
  }

  void check(Source::Range range, Type receiver_type, Type value_type) {
    ASSERT(receiver_type.is_valid());
    ASSERT(value_type.is_valid());
    if (receiver_type.is_any()) return;
    if (value_type.is_any()) return;
    if (receiver_type.is_none()) return;
    if (value_type.is_none()) {
      report_error(range, "Can't use value that is typed 'none'");
      return;
    }
    if (receiver_type.is_nullable() && value_type == null_type_) return;
    if (receiver_type == value_type) return;  // This also covers `Null_` == `null`.

    auto receiver_class = receiver_type.klass();
    auto value_class = value_type.klass();
    auto receiver_name = receiver_class->name();
    auto value_name = value_class->name();
    if (!receiver_type.is_nullable() && value_type == null_type_) {
      if (receiver_name.is_valid()) {
        report_error(range, "Type mismatch: can't assign 'null' to non-nullable '%s'", receiver_name.c_str());
      } else {
        // The receiver-type has no name.
        ASSERT(method_->is_factory() && receiver_class == method_->holder());
        ASSERT(diagnostics()->encountered_error());
        // We just assume that this must be the return-check.
        report_error(range, "Can't return `null` from factory");
      }
      return;
    }
    ASSERT(receiver_type.is_class() && value_type.is_class());
    for (int i = -1; i < value_class->interfaces().length(); i++) {
      Class* current = i == -1 ? value_class : value_class->interfaces()[i];
      do {
        if (current == receiver_class) return;
        current = current->super();
      } while (current != null);
    }
    if (receiver_name.is_valid() && value_name.is_valid()) {
      // TODO(florian); fix internal names (such as "_SmallInteger").
      report_error(range,
                   "Type mismatch. Expected '%s'. Got '%s'",
                   receiver_name.c_str(),
                   value_name.c_str());
    } else if (value_name.is_valid()) {
      // The receiver-type has no name.
      ASSERT(method_->is_factory() && receiver_class == method_->holder());
      ASSERT(diagnostics()->encountered_error());
      // We just assume that this must be the return-check.
      report_error(range,
                   "Can't return incompatible type '%s' from factory",
                   value_name.c_str());
    } else {
      ASSERT(receiver_name.is_valid());
      // The value-type has no name.
      ASSERT(method_->is_constructor() && value_class == method_->holder());
      ASSERT(diagnostics()->encountered_error());
      // We already reported an error that the constructor must not have a
      //   return type.
      // Since we already reported an error, we don't report an error again.
    }
  }

  Type merge_types(Type type1, Type type2) {
    if (type1 == type2) return type1;
    return Type::any();
  }
};

void check_types_and_deprecations(ir::Program* program,
                                  Lsp* lsp,
                                  ToitdocRegistry* toitdocs,
                                  Diagnostics* diagnostics) {
  auto deprecated = collect_deprecated_elements(program, toitdocs);
  auto queryables = build_queryables_from_resolution_shapes(program);
  TypeChecker checker(program->literal_types(), program->classes(), &queryables, &deprecated, lsp, diagnostics);
  program->accept(&checker);
}

} // namespace toit::compiler
} // namespace toit
