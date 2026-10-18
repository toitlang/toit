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
#include <functional>
#include <string>

#include "cycle_detector.h"
#include "deprecation.h"
#include "diagnostic.h"
#include "ir.h"
#include "lsp/lsp.h"
#include "no_such_method.h"
#include "queryable_class.h"
#include "toitdoc.h"
#include "zone.h"

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
              Lsp* lsp,
              UnorderedSet<CallVirtual*>* never_calls,
              Diagnostics* diagnostics)
      : classes_(classes)
      , queryables_(queryables)
      , lsp_(lsp)
      , diagnostics_(diagnostics)
      , method_(null)
      , never_calls_(never_calls)
      , boolean_type_(Type::invalid())
      , true_type_(Type::invalid())
      , false_type_(Type::invalid())
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
    true_type_ = find_type(Symbols::True);
    false_type_ = find_type(Symbols::False);
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
    check_overrides(node);
    return Type::invalid();
  }

  /// Reports instance methods of [klass] whose signature is incompatible with
  /// a method they override in a supertype: return types must be covariant,
  /// parameter types related (contravariant, or narrowed to a subtype).
  /// Overrides of `-> never` methods must be `-> never`.
  void check_overrides(Class* klass) {
    std::vector<Class*> supertypes;
    UnorderedSet<Class*> seen;
    std::function<void (Class*)> add_supertypes;
    add_supertypes = [&](Class* current) {
      if (current == null || seen.contains(current)) return;
      seen.insert(current);
      supertypes.push_back(current);
      add_supertypes(current->super());
      for (auto inter : current->interfaces()) add_supertypes(inter);
      for (auto mixin : current->mixins()) add_supertypes(mixin);
    };
    add_supertypes(klass->super());
    for (auto inter : klass->interfaces()) add_supertypes(inter);
    for (auto mixin : klass->mixins()) add_supertypes(mixin);
    if (supertypes.empty()) return;

    for (auto method : klass->methods()) {
      if (method->kind() != Method::INSTANCE) continue;
      for (auto supertype : supertypes) {
        bool reported = false;
        for (auto overridden : supertype->methods()) {
          if (overridden->kind() != Method::INSTANCE) continue;
          if (overridden->name() != method->name()) continue;
          if (!method->resolution_shape().overlaps_with(overridden->resolution_shape())) continue;
          if (check_override(method, overridden)) continue;
          reported = true;
          break;
        }
        // Report each override at most once.
        if (reported) break;
      }
    }
  }

  /// Checks [method] against the [overridden] method.
  ///
  /// Returns false and reports a diagnostic if they are incompatible.
  bool check_override(Method* method, Method* overridden) {
    auto report = [&](const std::string& detail) {
      diagnostics()->start_group();
      report_warning(method->range(),
                     "Override of '%s' is incompatible with '%s.%s': %s",
                     method->name().c_str(),
                     overridden->holder()->name().c_str(),
                     overridden->name().c_str(),
                     detail.c_str());
      diagnostics()->report_note(overridden->range(), "Overridden method");
      diagnostics()->end_group();
      return false;
    };

    // Virtual calls to `-> never` methods rely on this.
    if (overridden->return_type().is_never() && !method->return_type().is_never()) {
      report_error(method->range(),
                   "Override of '%s' must have return type 'never', like '%s.%s'",
                   method->name().c_str(),
                   overridden->holder()->name().c_str(),
                   overridden->name().c_str());
      return false;
    }

    // View the overridden signature through the type arguments [method]'s
    // holder passes to the supertype.
    auto environment = type_environment(method->holder()->self_type(), overridden->holder());

    auto check_parameter = [&](int index, int overridden_index) {
      auto parameter = method->parameters()[index];
      auto overridden_type = overridden->parameters()[overridden_index]->type().substitute(environment);
      if (!parameter->type().is_valid() || !overridden_type.is_valid()) return true;
      // Parameters are contravariant. Narrowing to a subtype is allowed too:
      // the parameter's as-check catches violations at runtime, and it is
      // common (for example `compare-to other/Time`).
      if (is_assignable(parameter->type(), overridden_type)) return true;
      if (is_assignable(overridden_type, parameter->type())) return true;
      // Field setters have a synthetic parameter name.
      std::string kind = method->is_FieldStub() ? "field '" : "parameter '";
      auto name = method->is_FieldStub() ? method->name() : parameter->name();
      return report(kind + name.c_str() +
                    "' has type '" + type_name(parameter->type()) +
                    "', unrelated to '" + type_name(overridden_type) + "'");
    };

    auto shape = method->resolution_shape();
    auto overridden_shape = overridden->resolution_shape();
    // Parameters are ordered: unnamed non-block parameters (starting with
    // `this`), unnamed blocks, and then named parameters in the order of
    // the shape's names.
    int unnamed = std::min(shape.max_unnamed_non_block(), overridden_shape.max_unnamed_non_block());
    for (int i = 1; i < unnamed; i++) {
      if (!check_parameter(i, i)) return false;
    }
    int blocks_start = shape.max_unnamed_non_block();
    int overridden_blocks_start = overridden_shape.max_unnamed_non_block();
    ASSERT(shape.unnamed_block_count() == overridden_shape.unnamed_block_count());
    for (int i = 0; i < shape.unnamed_block_count(); i++) {
      if (!check_parameter(blocks_start + i, overridden_blocks_start + i)) return false;
    }
    int names_start = blocks_start + shape.unnamed_block_count();
    int overridden_names_start = overridden_blocks_start + overridden_shape.unnamed_block_count();
    auto names = shape.names();
    auto overridden_names = overridden_shape.names();
    for (int i = 0; i < names.length(); i++) {
      for (int j = 0; j < overridden_names.length(); j++) {
        if (names[i] != overridden_names[j]) continue;
        if (shape.is_block_name(i) != overridden_shape.is_block_name(j)) continue;
        if (!check_parameter(names_start + i, overridden_names_start + j)) return false;
      }
    }

    auto return_type = method->return_type();
    auto overridden_return_type = overridden->return_type().substitute(environment);
    if (!return_type.is_valid() || !overridden_return_type.is_valid()) return true;
    // Callers ignore the value of a `none` method.
    if (overridden_return_type.is_none()) return true;
    // An unannotated method (inferred `none`) that never returns, like
    // `foo: unreachable`.
    if (return_type.is_none() && diverging_bodies_.contains(method)) return true;
    // Return types are covariant.
    if (is_assignable(overridden_return_type, return_type)) return true;
    return report("return type '" + type_name(return_type) +
                  "' isn't assignable to '" + type_name(overridden_return_type) + "'");
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
    } else if (ret->value()->is_LiteralNull() || value_type.is_never()) {
      node->set_return_type(Type::any());
    } else if (value_type == true_type_ || value_type == false_type_) {
      node->set_return_type(boolean_type_);
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
  Type visit_MixinStub(MixinStub* node) { return visit_Method(node); }
  Type visit_IsInterfaceOrMixinStub(IsInterfaceOrMixinStub* node) { return visit_Method(node); }
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
    check(node->range(), field_type(node->receiver(), field), value_type);
    return value_type;
  }

  Type visit_FieldLoad(FieldLoad* node) {
    check_deprecated(node->range(), node->field());
    return field_type(node->receiver(), node->field());
  }

  /// The type of [field] as seen through [receiver] (usually `this`, which
  /// may be a subclass of the field's holder with concrete type arguments).
  Type field_type(Expression* receiver, Field* field) {
    auto receiver_type = visit(receiver);
    return field->type().substitute(type_environment(receiver_type, field->holder()));
  }

  Type visit_Sequence(Sequence* node) {
    auto result_type = Type::any();
    bool diverges = false;
    for (auto expr : node->expressions()) {
      if (diverges && expr->is_Return() && expr->as_Return()->is_end_of_method_return()) {
        diverging_bodies_.insert(method_);
      }
      result_type = visit(expr);
      if (result_type.is_never()) diverges = true;
    }
    // Anything after a diverging expression is dead.
    return diverges ? Type::never() : result_type;
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

  Type visit_condition(Expression* node) {
    if (node->is_Not()) {
      return visit_Not(node->as_Not(), true);
    }
    auto result = visit(node);
    if (result.is_none()) {
      report_error(node->range(), "Condition can't be 'none'");
    } else if (!result.is_never() && !is_a_bool(result) && !result.is_nullable()) {
      report_warning(node->range(), "Condition always evaluates to true");
    }
    return result;
  }

  Type visit_If(If* node) {
    visit_condition(node->condition());
    auto yes_type = visit(node->yes());
    auto no_type = visit(node->no());
    return merge_types(yes_type, no_type);
  }

  Type visit_Not(Not* node) {
    return visit_Not(node, false);
  }

  Type visit_Not(Not* node, bool warn_if_always_false) {
    auto value_type = visit(node->value());
    if (value_type.is_none()) {
      report_error(node->value()->range(), "Argument to 'not' can't be 'none'");
    } else if (warn_if_always_false && !value_type.is_never() && !is_a_bool(value_type) && !value_type.is_nullable()) {
      report_warning(node->range(), "Condition always evaluates to false");
    }
    return boolean_type_;
  }

  Type visit_While(While* node) {
    visit_condition(node->condition());
    bool old_loop_has_break = loop_has_break_;
    loop_has_break_ = false;
    auto result_type = visit(node->body());
    visit(node->update());
    bool has_break = loop_has_break_;
    loop_has_break_ = old_loop_has_break;
    auto condition = node->condition();
    if (condition->is_LiteralBoolean() && condition->as_LiteralBoolean()->value() && !has_break) {
      return Type::never();
    }
    // The body may not run at all.
    if (result_type.is_never()) return Type::none();
    return result_type;
  }

  Type visit_LoopBranch(LoopBranch* node) {
    if (node->is_break()) loop_has_break_ = true;
    return Type::never();
  }

  Type visit_Code(Code* node) {
    auto body_type = visit(node->body());
    // TODO(florian); lambdas should have a "Lambda" type.
    if (!node->is_block()) return Type::any();
    if (body_type == true_type_ || body_type == false_type_) body_type = boolean_type_;
    // A block that never completes normally can still yield a value with
    // `continue.label value`, which isn't tracked. It fits any return type.
    // One that completes with a 'none' expression yields null.
    if (body_type.is_never()) body_type = Type::any();
    if (body_type.is_none()) body_type = null_type_;
    auto parameters = node->parameters();
    auto parameter_types = ListBuilder<Type>::allocate(parameters.length());
    for (int i = 0; i < parameters.length(); i++) {
      parameter_types[i] = parameters[i]->type();
    }
    return Type::block(parameter_types, body_type);
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
    // Constructors, factories and statics of generic classes have no receiver
    // to take type arguments from, and there is no inference: the holder's
    // type parameters are erased to `any`.
    auto environment = environment_of(method->holder(), List<Type>());
    auto parameters = method->parameters();
    int parameter_offset = node->is_CallConstructor() ? 1 : 0;
    if (arguments.length() + parameter_offset != parameters.length()) {
      ASSERT(method->is_setter());  // We already reported an error for this.
    } else {
      for (int i = 0; i < arguments.length(); i++) {
        // TODO(florian): provide more context in the error message.
        auto parameter = parameters[i + parameter_offset];
        auto parameter_type = parameter->type().substitute(environment);
        if (parameter->has_default_value()) parameter_type = parameter_type.to_nullable();
        check_parameter(arguments[i]->range(), parameter, parameter_type, argument_types[i]);
      }
    }
    return method->return_type().substitute(environment);
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

    // Type parameters have no bounds, so nothing is known about their members.
    if (receiver_type.is_any() || receiver_type.is_type_parameter()) {
      for (auto argument : arguments) visit(argument);
      return Type::any();
    }

    if (receiver_type.is_none()) {
      report_error(node->range(), "Can't invoke method on 'none' type");
      return Type::any();
    }
    if (receiver_type.is_never()) {
      // Dead code.
      for (auto argument : arguments) visit(argument);
      return Type::never();
    }
    if (!node->selector().is_valid()) {
      ASSERT(diagnostics()->encountered_error());
      return Type::any();
    }

    bool is_equals_call = (node->selector() == Token::symbol(Token::EQ) &&
                           node->shape() == CallShape(1).with_implicit_this());

    ASSERT(receiver_type.is_class());
    auto klass = receiver_type.klass();
    Selector<CallShape> selector(node->selector(), node->shape());
    auto queryable = queryables_->at(klass);
    auto method = queryable.lookup(selector);
    if (method == null) {
      report_no_such_instance_method(klass, selector, node->range(), diagnostics());
      for (auto argument : arguments) visit(argument);
      return Type::any();
    }

    check_deprecated(node->range(), method);

    auto argument_types = ListBuilder<Type>::allocate(arguments.length());
    for (int i = 0; i < arguments.length(); i++) {
      argument_types[i] = visit(arguments[i]);
    }

    // Members of generic classes are declared in terms of the holder's type
    // parameters; instantiate them with the receiver's type arguments.
    auto environment = type_environment(receiver_type, method->holder());

    auto parameters = method->parameters();
    int argument_offset = 1;  // For the receiver, which is given as first argument.
    CallBuilder::match_arguments_with_parameters(node->shape(),
                                                 method->resolution_shape(),
                                                 [&](int argument_pos, int parameter_pos) {
      if (argument_pos == 0) return;  // The `this` parameter.
      auto argument = arguments[argument_pos - argument_offset];
      auto argument_type = argument_types[argument_pos - argument_offset];
      auto parameter_type = parameters[parameter_pos]->type().substitute(environment);
      if (parameters[parameter_pos]->has_default_value()) parameter_type = parameter_type.to_nullable();

      // The interpreter shortcuts the `null` equality, and the argument type thus
      //   can effectively be nullable.
      if (is_equals_call) parameter_type = parameter_type.to_nullable();

      // TODO(florian): provide more context in the error message.
      check_parameter(argument->range(), parameters[parameter_pos], parameter_type, argument_type);
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
    if (method->return_type().is_never()) {
      // The static target doesn't return, but an override might. Trap
      // after the call (see `NeverTrapInserter`).
      never_calls_->insert(node);
      return Type::never();
    }
    return method->return_type().substitute(environment);
  }

  Type visit_CallBlock(CallBlock* node) {
    auto target = node->target();
    auto block_type = target->is_ReferenceLocal()
        ? target->as_ReferenceLocal()->target()->type()
        : Type::any();
    if (!block_type.is_block()) return visit_Call(node);
    visit(target);
    auto arguments = node->arguments();
    auto argument_types = ListBuilder<Type>::allocate(arguments.length());
    for (int i = 0; i < arguments.length(); i++) {
      argument_types[i] = visit(arguments[i]);
    }
    int expected = block_type.block_parameter_count();
    if (arguments.length() != expected) {
      report_error(node->range(),
                   "Block of type '%s' expects %d argument%s, but got %d",
                   type_name(block_type).c_str(),
                   expected,
                   expected == 1 ? "" : "s",
                   arguments.length());
    } else {
      for (int i = 0; i < arguments.length(); i++) {
        check(arguments[i]->range(), block_type.block_parameter_type(i), argument_types[i]);
      }
    }
    return block_type.block_return_type();
  }

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
      case Builtin::EXIT:
        return Type::never();

      case Builtin::INVOKE_LAMBDA:
        return Type::any();

      case Builtin::YIELD:
      case Builtin::RESET:
      case Builtin::DEEP_SLEEP:
        // The result of runtime-control builtins should not be used.
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
      case Typecheck::BLOCK_ARGUMENT_AS_CHECK:
      case Typecheck::LOCAL_AS_CHECK:
      case Typecheck::GLOBAL_AS_CHECK:
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
    // The implicit `return null` at the end of a method is a runtime as-check
    // for class types. Type parameters are erased, so it stays a plain return.
    bool is_erased_fallthrough = node->is_end_of_method_return() &&
        method_->return_type().is_type_parameter();
    // Returns from `-> never` methods are reported by the resolver
    // (explicit) and the definite-assignment checker (fallthrough).
    bool is_never_method = method_->return_type().is_never();
    if (node->depth() == -1 && !is_erased_fallthrough && !is_never_method) {
      check(node->range(), method_->return_type(), value_type);
    }
    return Type::never();
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
    } else if (right_type.is_never()) {
      local->set_type(Type::any());
    } else if (right_type.is_none()) {
      report_error(node->right()->range(), "Variable can't be initialized with 'none'");
      local->set_type(Type::any());
    } else if (right_type == true_type_ || right_type == false_type_) {
      local->set_type(boolean_type_);
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
    auto receiver_type = global->return_type();
    // The receiver type can be invalid when the assignment lives inside the
    // global's own initializer (the type hasn't been computed yet) or when
    // type inference for the global failed (e.g. a cyclic type dependency).
    if (!receiver_type.is_valid()) return right_type;
    if (receiver_type.is_any() && right_type.is_none()) {
      // TODO(florian): check that 'none' types aren't used.
      // report_error(node->right()->range(), "Can't use value of type 'none'");
    } else {
      check(node->range(), receiver_type, right_type);
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
    return node->value() ? true_type_ : false_type_;
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
  Lsp* lsp_;
  Diagnostics* diagnostics_;

  // Since globals can be visited out of order (recursively), we need to
  // keep track which globals are already fully done.
  Set<ir::Global*> handled_globals_;
  CycleDetector<ir::Global*> globals_cycle_detector_;
  UnorderedSet<ir::Global*> reported_cyclic_globals_;

  // The current method.
  Method* method_;

  // Whether the innermost loop has a `break`.
  bool loop_has_break_ = false;

  // Virtual calls to `-> never` methods.
  UnorderedSet<CallVirtual*>* never_calls_;

  // Methods whose body doesn't reach the implicit `return null` at its end.
  UnorderedSet<Method*> diverging_bodies_;

  Type boolean_type_;
  Type true_type_;
  Type false_type_;
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
    bool is_deprecated = false;
    auto deprecation_message = Symbol::invalid();
    // Modules have already reported deprecation warnings.
    // They don't exist at this stage anymore, so import warnings were
    // reported during resolution.
    if (node->is_Method()) {
      auto method = node->as_Method();
      is_deprecated = method->is_deprecated();
      deprecation_message = method->get_deprecation_message();
      name = method->name();
      holder = method->holder();
      bool holder_is_deprecated = false;
      auto holder_deprecation_message = Symbol::invalid();
      if (holder != null) {
        holder_is_deprecated = holder->is_deprecated();
        holder_deprecation_message = holder->get_deprecation_message();
        holder_name = holder->name();
      }
      if (method->is_constructor() || method->is_factory()) {
        if (holder_is_deprecated) {
          ASSERT(name.is_valid());
          report_warning(range,
                         "Class '%s' is deprecated%s",
                         holder_name.c_str(),
                         holder_deprecation_message.c_str());
        } else if (is_deprecated) {
          if (name == Symbols::constructor) {
            report_warning(range,
                           "Deprecated constructor of '%s'%s",
                           holder_name.c_str(),
                           deprecation_message.c_str());
          } else {
            report_warning(range,
                           "Deprecated constructor '%s.%s'%s",
                           holder_name.c_str(),
                           name.c_str(),
                           deprecation_message.c_str());
          }
        }
        return;
      }
    } else {
      ASSERT(node->is_Field());
      auto field = node->as_Field();
      is_deprecated = field->is_deprecated();
      deprecation_message = field->get_deprecation_message();
      name = field->name();
      holder = field->holder();
      if (holder != null) {
        holder_name = holder->name();
      }
    }
    if (is_deprecated) {
      if (holder_name.is_valid()) {
        report_warning(range,
                       "Deprecated '%s.%s'%s",
                       holder_name.c_str(),
                       name.c_str(),
                       deprecation_message.c_str());
      } else {
        report_warning(range,
                       "Deprecated '%s'%s",
                       name.c_str(),
                       deprecation_message.c_str());
      }
    }
  }

  void check(Source::Range range, Type receiver_type, Type value_type) {
    ASSERT(receiver_type.is_valid());
    ASSERT(value_type.is_valid());
    if (receiver_type.is_any()) return;
    if (value_type.is_any()) return;
    if (receiver_type.is_none()) return;
    if (value_type.is_never()) return;
    if (value_type.is_none()) {
      report_error(range, "Can't use value that is typed 'none'");
      return;
    }
    if (receiver_type.is_never()) {
      report_error(range, "Type mismatch. Expected 'never'. Got '%s'", type_name(value_type).c_str());
      return;
    }
    if (receiver_type.is_nullable() && value_type == null_type_) return;
    if (receiver_type == value_type) return;  // This also covers `Null_` == `null`.

    if (receiver_type.is_block() || value_type.is_block()) {
      if (is_block_assignable(receiver_type, value_type)) return;
      report_error(range,
                   "Type mismatch. Expected '%s'. Got '%s'",
                   type_name(receiver_type).c_str(),
                   type_name(value_type).c_str());
      return;
    }

    if (receiver_type.is_type_parameter() || value_type.is_type_parameter()) {
      // Type parameters are opaque: only `any` and the parameter itself are compatible.
      if (!receiver_type.is_nullable() && value_type == null_type_) {
        report_error(range,
                     "Type mismatch: can't assign 'null' to non-nullable '%s'",
                     type_name(receiver_type, false).c_str());
      } else {
        report_error(range,
                     "Type mismatch. Expected '%s'. Got '%s'",
                     type_name(receiver_type, false).c_str(),
                     type_name(value_type, false).c_str());
      }
      return;
    }

    auto receiver_class = receiver_type.klass();
    auto value_class = value_type.klass();
    auto receiver_name = receiver_class->name();
    auto value_name = value_class->name();
    if (!receiver_type.is_nullable() && value_type == null_type_) {
      if (receiver_name.is_valid()) {
        report_error(range, "Type mismatch: can't assign 'null' to non-nullable '%s'", type_name(receiver_type, false).c_str());
      } else {
        // The receiver-type has no name.
        ASSERT(method_->is_factory() && receiver_class == method_->holder());
        ASSERT(diagnostics()->encountered_error());
        // We just assume that this must be the return-check.
        report_error(range, "Can't return `null` from factory");
      }
      return;
    }
    if (receiver_type == true_type_ && value_type == false_type_) {
      report_error(range, "Can't cast 'false' to 'True'");
      return;
    }
    if (receiver_type == false_type_ && value_type == true_type_) {
      report_error(range, "Can't cast 'true' to 'False'");
      return;
    }
    if (value_type == boolean_type_ && is_a_bool(receiver_type)) {
      // We allow implicit downcasts of booleans.
      return;
    }
    ASSERT(receiver_type.is_class() && value_type.is_class());
    if (is_subtype_of(value_class, receiver_class)) {
      if (arguments_assignable(receiver_type, value_type)) return;
      report_error(range,
                   "Type mismatch. Expected '%s'. Got '%s'",
                   type_name(receiver_type, false).c_str(),
                   type_name(value_type, false).c_str());
      return;
    }
    if (receiver_name.is_valid() && value_name.is_valid()) {
      // TODO(florian); fix internal names (such as "_SmallInteger").
      report_error(range,
                   "Type mismatch. Expected '%s'. Got '%s'",
                   type_name(receiver_type, false).c_str(),
                   type_name(value_type, false).c_str());
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

  static bool is_subtype_of(Class* value_class, Class* receiver_class) {
    for (Class* current = value_class; current != null; current = current->super()) {
      if (current == receiver_class) return true;
      for (auto inter : current->interfaces()) {
        // The interfaces list contains a flattened list of all interfaces this class implements.
        if (inter == receiver_class) return true;
      }
      for (auto mixin : current->mixins()) {
        // The mixin list contains a flattened list of all mixins that are between this
        // class and the super.
        if (mixin == receiver_class) return true;
      }
    }
    return false;
  }

  typedef std::function<Type (TypeParameter*)> Environment;

  static List<Type> substitute_all(List<Type> types, const Environment& environment) {
    if (types.is_empty()) return types;
    auto result = ListBuilder<Type>::allocate(types.length());
    for (int i = 0; i < types.length(); i++) {
      result[i] = types[i].substitute(environment);
    }
    return result;
  }

  /// Maps the type parameters of [klass] to [arguments].
  /// Raw types (empty [arguments]) map every parameter to `any`.
  static Environment environment_of(Class* klass, List<Type> arguments) {
    return [=](TypeParameter* parameter) -> Type {
      if (parameter->holder() != klass || arguments.is_empty()) return Type::any();
      return arguments[parameter->index()];
    };
  }

  /// Computes the type arguments of `klass<arguments>` as seen from [target],
  /// a transitive supertype of [klass], by following the declared supertypes
  /// and substituting along the way.
  /// Returns false if [target] isn't reachable.
  static bool arguments_for(Class* klass, List<Type> arguments, Class* target, List<Type>* result) {
    if (klass == target) {
      *result = arguments;
      return true;
    }
    auto environment = environment_of(klass, arguments);
    if (klass->super() != null &&
        arguments_for(klass->super(), substitute_all(klass->super_arguments(), environment), target, result)) {
      return true;
    }
    for (auto type : klass->declared_interfaces()) {
      if (arguments_for(type.klass(), substitute_all(type.arguments(), environment), target, result)) return true;
    }
    for (auto type : klass->declared_mixins()) {
      if (arguments_for(type.klass(), substitute_all(type.arguments(), environment), target, result)) return true;
    }
    return false;
  }

  /// The environment for members declared in [holder] when accessed through
  /// a receiver of type [receiver_type].
  static Environment type_environment(Type receiver_type, Class* holder) {
    List<Type> arguments;
    if (holder != null && receiver_type.is_class()) {
      arguments_for(receiver_type.klass(), receiver_type.arguments(), holder, &arguments);
    }
    return environment_of(holder, arguments);
  }

  /// Whether the type arguments of [value_type] fit [receiver_type]. Both must
  /// be class types where the value's class is a subtype of the receiver's.
  /// Type arguments are covariant, and raw types match everything.
  bool arguments_assignable(Type receiver_type, Type value_type) {
    auto receiver_arguments = receiver_type.arguments();
    if (receiver_arguments.is_empty()) return true;
    List<Type> value_arguments;
    if (!arguments_for(value_type.klass(), value_type.arguments(), receiver_type.klass(), &value_arguments)) {
      // Can't happen when the classes are related; be lenient.
      return true;
    }
    if (value_arguments.is_empty()) return true;
    if (value_arguments.length() != receiver_arguments.length()) return true;
    for (int i = 0; i < receiver_arguments.length(); i++) {
      if (!is_assignable(receiver_arguments[i], value_arguments[i])) return false;
    }
    return true;
  }

  /// Whether a value of [value_type] can be used where [receiver_type] is
  /// expected, following the same rules as [check], but without reporting
  /// any diagnostics.
  bool is_assignable(Type receiver_type, Type value_type) {
    ASSERT(receiver_type.is_valid());
    ASSERT(value_type.is_valid());
    if (receiver_type.is_any() || value_type.is_any()) return true;
    if (value_type.is_never()) return true;
    if (receiver_type.is_never()) return false;
    if (receiver_type.is_none() || value_type.is_none()) return false;
    if (receiver_type == value_type) return true;  // This also covers `Null_` == `null`.
    if (receiver_type.is_block() || value_type.is_block()) {
      return is_block_assignable(receiver_type, value_type);
    }
    if (value_type == null_type_) return receiver_type.is_nullable();
    if (receiver_type.is_type_parameter() || value_type.is_type_parameter()) return false;
    if (value_type == boolean_type_ && is_a_bool(receiver_type)) return true;
    if (!is_subtype_of(value_type.klass(), receiver_type.klass())) return false;
    return arguments_assignable(receiver_type, value_type);
  }

  /// Whether a block of type [value_type] can be passed where a block of
  /// type [receiver_type] is expected.
  bool is_block_assignable(Type receiver_type, Type value_type) {
    if (!receiver_type.is_block() || !value_type.is_block()) return false;
    int receiver_count = receiver_type.block_parameter_count();
    int value_count = value_type.block_parameter_count();
    // A block may declare fewer parameters than it is called with. The
    // remaining arguments are dropped.
    if (value_count > receiver_count) return false;
    for (int i = 0; i < value_count; i++) {
      // The block receives what the caller passes: parameters are contravariant.
      if (!is_assignable(value_type.block_parameter_type(i), receiver_type.block_parameter_type(i))) {
        return false;
      }
    }
    auto receiver_return = receiver_type.block_return_type();
    // The caller ignores the value.
    if (receiver_return.is_none()) return true;
    return is_assignable(receiver_return, value_type.block_return_type());
  }

  /// Checks an argument against a parameter, taking `// __TYPE-MIGRATION__`
  /// annotations into account.
  ///
  /// The [parameter_type] must be the parameter's type, potentially already
  /// adjusted (made nullable) by the caller.
  void check_parameter(Source::Range range,
                       ir::Parameter* parameter,
                       Type parameter_type,
                       Type value_type) {
    auto migration_types = parameter->migration_types();
    if (migration_types.is_empty()) {
      check(range, parameter_type, value_type);
      return;
    }
    ASSERT(parameter->type().is_any());
    if (value_type.is_any() || value_type.is_never()) return;
    if (value_type.is_none()) {
      report_error(range, "Can't use value that is typed 'none'");
      return;
    }
    // Parameters with default values accept 'null' to request the default.
    if (value_type == null_type_ && parameter->has_default_value()) return;
    for (auto migration_type : migration_types) {
      if (!is_assignable(migration_type.type(), value_type)) continue;
      if (!migration_type.is_deprecated()) return;
      report_warning(range,
                     "Deprecated type '%s' for parameter '%s'%s",
                     type_name(migration_type.type()).c_str(),
                     parameter->name().c_str(),
                     migration_type.deprecation_message().c_str());
      return;
    }
    std::string expected;
    for (int i = 0; i < migration_types.length(); i++) {
      if (i != 0) expected += (i == migration_types.length() - 1) ? " or " : ", ";
      expected += "'";
      expected += type_name(migration_types[i].type());
      expected += "'";
    }
    auto got = value_type == null_type_ ? std::string("null") : type_name(value_type);
    report_error(range,
                 "Type mismatch. Expected %s. Got '%s'",
                 expected.c_str(),
                 got.c_str());
  }

  /// The source-like name of [type], including type arguments.
  /// Existing diagnostics don't print the top-level `?`, so it's optional.
  std::string type_name(Type type, bool include_nullable = true) {
    if (type.is_any()) return "any";
    if (type.is_none()) return "none";
    if (type.is_never()) return "never";
    if (type == null_type_) return "null";
    if (type.is_block()) {
      std::string result("[block");
      for (int i = 0; i < type.block_parameter_count(); i++) {
        result += " " + type_name(type.block_parameter_type(i));
      }
      return result + " -> " + type_name(type.block_return_type()) + "]";
    }
    std::string result;
    if (type.is_type_parameter()) {
      result = type.parameter()->name().c_str();
    } else {
      auto klass_name = type.klass()->name();
      result = klass_name.is_valid() ? klass_name.c_str() : "<unknown>";
      if (type.has_arguments()) {
        result += "<";
        for (int i = 0; i < type.arguments().length(); i++) {
          if (i != 0) result += ", ";
          result += type_name(type.arguments()[i]);
        }
        result += ">";
      }
    }
    if (include_nullable && type.is_nullable()) result += "?";
    return result;
  }

  Type merge_types(Type type1, Type type2) {
    if (type1.is_never()) return type2;
    if (type2.is_never()) return type1;
    if (type1 == type2) return type1;
    return Type::any();
  }

  bool is_a_bool(Type type) {
    return type == boolean_type_ || type == true_type_ || type == false_type_;
  }
};

/// Appends a call to `unreachable` to virtual calls of `-> never` methods,
/// so that an override that returns normally after all doesn't continue
/// in code that assumes the call diverged.
class NeverTrapInserter : public ReplacingVisitor {
 public:
  NeverTrapInserter(Method* unreachable, UnorderedSet<CallVirtual*>* never_calls)
      : unreachable_(unreachable), never_calls_(never_calls) {}

  Node* visit_CallVirtual(CallVirtual* node) {
    auto result = ReplacingVisitor::visit_CallVirtual(node);
    if (!never_calls_->contains(node)) return result;
    auto range = node->range();
    auto trap = zone_new<CallStatic>(zone_new<ReferenceMethod>(unreachable_, range),
                                CallShape(0),
                                List<Expression*>(),
                                range);
    return zone_new<Sequence>(ListBuilder<Expression*>::build(result->as_Expression(), trap), range);
  }

 private:
  Method* unreachable_;
  UnorderedSet<CallVirtual*>* never_calls_;
};

void check_types_and_deprecations(ir::Program* program,
                                  Lsp* lsp,
                                  ToitdocRegistry* toitdocs,
                                  Diagnostics* diagnostics) {
  bool include_abstracts;
  auto queryables = build_queryables_from_resolution_shapes(program, include_abstracts=true);
  UnorderedSet<CallVirtual*> never_calls;
  TypeChecker checker(program->literal_types(), program->classes(), &queryables, lsp, &never_calls, diagnostics);
  program->accept(&checker);
  if (!never_calls.empty()) {
    NeverTrapInserter inserter(program->unreachable(), &never_calls);
    program->accept(&inserter);
  }
}

} // namespace toit::compiler
} // namespace toit
