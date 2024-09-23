// Copyright (C) 2023 Toitware ApS.
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

#include <deque>
#include "ir.h"
#include "map.h"
#include "mixin.h"
#include "set.h"
#include "shape.h"
#include "resolver_scope.h"

namespace toit {
namespace compiler {

/// A visitor that special cases the actual super call.
///
/// The 'Super' node has an expression field, but that field might not
/// contain the actual static call to the super constructor. Instead,
/// it might have hoisted argument fields, ...
///
/// This visitor adds an additional `visit_static_super_call` which is
/// called with `null` (if `Super` has no expression), or with the
/// `CallStatic` of the actual call to the super constructor.
///
/// This visitor is still a replacing visitor, so all methods must
/// return an expression that replaces the node that was given to the
/// visit_X method.
class SuperCallVisitor : protected ir::ReplacingVisitor {
 public:
  explicit SuperCallVisitor(ir::Class* holder) : holder_(holder) {}

 protected:
  ir::Node* visit_Super(ir::Super* node) override {
    if (node->expression() == null) {
      auto replacement = visit_static_super_call(null, node->range());
      if (replacement != null) {
        node->replace_expression(replacement->as_Expression());
      }
      return node;
    }
    // A super expressions must be at the top-level of the constructor. As such,
    // they can't be nested.
    // Also, there can only be one.
    // These are checked in resolver-method.
    ASSERT(!in_super_);
    ASSERT(!has_seen_super_);
    in_super_ = true;
    auto result = ir::ReplacingVisitor::visit_Super(node);
    in_super_ = false;
    has_seen_super_ = true;
    return result;
  }

  ir::Node* visit_CallStatic(ir::CallStatic* node) override {
    if (!in_super_ || node->is_CallConstructor()) {
      return ir::ReplacingVisitor::visit_CallStatic(node);
    }
    // The call-static might be an argument to the constructor.
    // Make sure it is actually the call to the constructor.
    // Note that other calls to constructors that intend to instantiate a new
    // object would use `CallConstructor` (which we already checked).
    auto method = node->target()->target();
    if (method->is_constructor() && method->holder() == holder_->super()) {
      return visit_static_super_call(node, node->range());
    }
    return ir::ReplacingVisitor::visit_CallStatic(node);
  }

  /// May be null if there wasn't any explicit call.
  virtual ir::Node* visit_static_super_call(ir::CallStatic* node, const Source::Range& range) = 0;

 private:
  ir::Class* const holder_;
  bool in_super_ = false;
  // This boolean only tracks whether we have seen the `Super` node; not the actual static call.
  bool has_seen_super_ = false;
};

/// Changes mixin constructors so they take a block and then call the
/// block instead of calling their super.
/// During the construction all field accesses are replaced with
/// local variable accesses.
/// The block receives the values of these fields, so that the caller can
/// initialize the actual fields correctly.
/// Example:
/// Given:
///        mixin M1:
///          field1 := 499
///
///          constructor:
///            print 1
///            super
///            print 2
///
/// Will be changed to:
///        mixin M1:
///          field1  // Not relevant anymore.
///          constructor <implicit-this> [super-next]:
///            local-field1 := 499
///            print 1
///            super-next.call implicit-this local-field1
///            print 2
class MixinConstructorVisitor : protected SuperCallVisitor {
 public:
  MixinConstructorVisitor(ir::Class* holder, List<ir::Field*> fields)
      : SuperCallVisitor(holder)
      , fields_(fields) {}

  bool has_seen_static_super() const { return has_seen_static_super_; }

  // Make `visit` public.
  ir::Node* insert_mixin_block_calls(ir::Method* node) {
    return SuperCallVisitor::visit(node);
  }

 protected:
  /// Updates the constructor.
  /// Adds an additional block argument to the parameter list.
  /// Creates local variables that will be used instead of the fields.
  ir::Node* visit_Method(ir::Method* node) override {
    ASSERT(node->is_constructor());
    ASSERT(node->parameters().length() == 1 && node->parameters()[0]->index() == 0);

    // Add an additional parameter to the constructor.
    // The given block will be called instead of the original static super call.
    bool is_block, default_value;
    int block_index;
    this_ = node->parameters()[0];
    next_super_ = _new ir::Parameter(Symbol::synthetic("<next-super>"),
                                     ir::Type::any(),
                                     is_block=true,
                                     block_index=1,
                                     default_value=false,
                                     Source::Range::invalid(),
                                     node->range());
    auto new_parameters = ListBuilder<ir::Parameter*>::allocate(2);
    new_parameters[0] = this_;
    new_parameters[1] = next_super_;
    node->replace_parameters(new_parameters);
    PlainShape shape(CallShape(2, 1));  // Two arguments, of which one is a block.
    node->set_plain_shape(shape);

    if (!fields_.is_empty()) {
      // For each field create a local variable that we can then pass to the additional
      // block.
      ListBuilder<ir::Expression*> new_body;
      for (auto field : fields_) {
        auto range = field->range();
        bool is_final, is_block;
        auto local = _new ir::Local(field->name(),
                                    is_final=false,
                                    is_block=false,
                                    field->type(),
                                    range);
        field_to_local_[field] = local;
        // TODO(florian): can we avoid the `null` assignment?
        auto definition = _new ir::AssignmentDefine(local, _new ir::LiteralNull(range), range);
        new_body.add(definition);
      }
      new_body.add(node->body());
      node->replace_body(_new ir::Sequence(new_body.build(), node->range()));
    }
    return SuperCallVisitor::visit_Method(node);
  }

  /// Keeps track of how deep we are for field accesses.
  /// We need this when we replace field accesses with accesses to the local variable.
  ir::Node* visit_Code(ir::Code* node) override {
    if (node->is_block()) block_depth_++;
    auto result = SuperCallVisitor::visit_Code(node);
    if (node->is_block()) block_depth_--;
    return result;
  }

  /// Replaces the static super call with a call to the block.
  ir::Node* visit_static_super_call(ir::CallStatic* node, const Source::Range& range) override {
    ASSERT(node == null || node->arguments().length() == 1);
    auto block_ref = _new ir::ReferenceLocal(next_super_, block_depth_, range);
    int arity = fields_.length() + 1;
    auto arguments = ListBuilder<ir::Expression*>::allocate(arity);
    // The first argument is 'this'.
    arguments[0] = _new ir::ReferenceLocal(this_, block_depth_, range);
    for (int i = 0; i < fields_.length(); i++) {
      arguments[i + 1] = _new ir::ReferenceLocal(field_to_local_.at(fields_[i]), block_depth_, range);
    }
    bool is_setter;
    auto shape = CallShape(arity, 0, List<Symbol>(), 0, is_setter=false).with_implicit_this();
    auto block_call = _new ir::CallBlock(block_ref, shape, arguments, range);
    has_seen_static_super_ = true;
    return SuperCallVisitor::visit(block_call);
  }

  /// Field accesses are replaced with local variable accesses.
  ir::Node* visit_FieldLoad(ir::FieldLoad* node) override {
    ASSERT(field_to_local_.contains_key(node->field()));
    ASSERT(!has_seen_static_super_);
    return _new ir::ReferenceLocal(field_to_local_.at(node->field()), block_depth_, node->range());
  }

  /// Field accesses are replaced with local variable accesses.
  ir::Node* visit_FieldStore(ir::FieldStore* node) override {
    ASSERT(field_to_local_.contains_key(node->field()));
    ASSERT(!has_seen_static_super_);
    auto result = _new ir::AssignmentLocal(field_to_local_.at(node->field()),
                                           block_depth_,
                                           node->value(),
                                           node->range());
    return SuperCallVisitor::visit(result);
  }

 private:
  int block_depth_ = 0;
  ir::Parameter* this_ = null;
  ir::Parameter* next_super_ = null;
  List<ir::Field*> fields_;
  Map<ir::Field*, ir::Local*> field_to_local_;
  bool has_seen_static_super_ = false;
};

/// Changes the mixin constructor so it takes a block as argument.
/// The block takes as many arguments as the mixin has fields.
/// Instead of doing a super call, it calls the block with the values for
/// the fields.
static void modify_mixin_constructor(ir::Class* mixin) {
  ASSERT(mixin->unnamed_constructors().length() == 1);  // A single default constructor.
  ASSERT(mixin->unnamed_constructors()[0]->parameters().length() == 1);  // The object but no other parameter.
  auto constructor = mixin->unnamed_constructors()[0];
  MixinConstructorVisitor visitor(mixin, mixin->fields());
  visitor.insert_mixin_block_calls(constructor);
  ASSERT(visitor.has_seen_static_super());
}

static List<ir::Parameter*> duplicate_parameters(List<ir::Parameter*> parameters) {
  auto result = ListBuilder<ir::Parameter*>::allocate(parameters.length());
  for (int i = 0; i < parameters.length(); i++) {
    auto parameter = parameters[i];
    result[i] = _new ir::Parameter(parameter->name(),
                                   parameter->type(),
                                   parameter->is_block(),
                                   parameter->index(),
                                   parameter->has_default_value(),
                                   parameter->default_value_range(),
                                   parameter->range());
  }
  return result;
}

// Applies the mixins by adding stub methods.
// Also adds fields.
// Returns a map from mixin-field to new-field (where 'new-field' is
// the newly added field in the given class).
static Map<ir::Field*, ir::Field*> apply_mixins(ir::Class* klass) {
  UnorderedMap<Symbol, UnorderedSet<PlainShape>> existing_methods;
  for (auto method : klass->methods()) {
    existing_methods[method->name()].insert(method->plain_shape());
  }

  Map<ir::Field*, ir::Field*> field_map;  // From mixin-field to class-field.
  for (auto mixin : klass->mixins()) {
    for (auto field : mixin->fields()) {
      auto new_field = _new ir::Field(field->name(),
                                      klass,
                                      field->is_final(),
                                      field->range(),
                                      field->outline_range());
      new_field->set_type(field->type());
      field_map[field] = new_field;
    }
  }

  std::vector<ir::MethodInstance*> new_stubs;

  // We only copy a method if it doesn't exist yet. The mixin list
  // is ordered such that the first mixin shadows methods of later
  // mixins (and super).
  // At this stage, all methods are based on plain-shapes and accept a
  // single selector. That means that we don't need to worry about
  // overlapping methods.
  for (auto mixin : klass->mixins()) {
    for (auto method : mixin->methods()) {
      // Don't create forwarder stubs to mixin stubs.
      // The flattened list of mixins will make sure we get all the methods we need.
      if (method->is_MixinStub()) continue;

      Symbol method_name = method->name();
      PlainShape shape = method->plain_shape();
      Source::Range range = method->range();
      int arity = shape.arity();

      auto probe = existing_methods.find(method_name);
      if (probe != existing_methods.end() && probe->second.contains(shape)) {
        // Already exists.
        continue;
      }
      auto original_parameters = method->parameters();
      ASSERT(original_parameters.length() == arity);
      auto stub_parameters = duplicate_parameters(original_parameters);
      ir::MethodInstance* stub;
      ir::Expression* body;

      if (method->is_FieldStub() &&
          (method->as_FieldStub()->is_getter() ||
          // If this is the setter for a final field we just forward the call.
          // That's easier than recreating the 'throw' again.
           !method->as_FieldStub()->field()->is_final())) {
        // Mostly a copy of what's happening in `resolver_method`.
        auto range = method->range();
        auto field_stub = method->as_FieldStub();
        auto probe = field_map.find(field_stub->field());
        ASSERT(probe != field_map.end());
        auto new_field = probe->second;
        ir::FieldStub* new_field_stub = _new ir::FieldStub(new_field,
                                                           klass,
                                                           field_stub->is_getter(),
                                                           range,
                                                           method->outline_range());
        new_field_stub->set_plain_shape(shape);
        auto this_ref = _new ir::ReferenceLocal(stub_parameters[0], 0, range);
        if (field_stub->is_getter()) {
          ASSERT(stub_parameters.length() == 1);
          auto load = _new ir::FieldLoad(this_ref, new_field, range);
          auto ret = _new ir::Return(load, false, range);
          body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(ret), range);
        } else {
          ASSERT(stub_parameters.length() == 2);
          auto store = _new ir::FieldStore(this_ref,
                                           new_field,
                                           _new ir::ReferenceLocal(stub_parameters[1], 0, range),
                                           range);
          auto ret = _new ir::Return(store, false, range);
          if (!new_field->type().is_class()) {
            body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(ret), range);
          } else {
            auto type = new_field->type();
            new_field_stub->set_checked_type(type);
            auto check = _new ir::Typecheck(ir::Typecheck::PARAMETER_AS_CHECK,
                                            _new ir::ReferenceLocal(stub_parameters[1], 0, range),
                                            type,
                                            type.klass()->name(),
                                            range);
            body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(check, ret), range);
          }
        }
        stub = new_field_stub;
      } else if (method->is_IsInterfaceOrMixinStub()) {
        // We copy over the method (used to determine if a class is an interface or mixin).
        // The body will not be compiled, so it's not important what we put in there.
        auto is_stub = method->as_IsInterfaceOrMixinStub();
        stub = _new ir::IsInterfaceOrMixinStub(method_name,
                                               klass,
                                               shape,
                                               is_stub->interface_or_mixin(),
                                               method->range(),
                                               method->outline_range());

        body = _new ir::Return(_new ir::LiteralBoolean(true, range), false, range);
      } else {
        auto forward_arguments = ListBuilder<ir::Expression*>::allocate(arity);
        for (int i = 0; i < arity; i++) {
          auto stub_parameter = stub_parameters[i];
          forward_arguments[i] = _new ir::ReferenceLocal(stub_parameter, 0, range);
        }

        auto forward_call = _new ir::CallStatic(_new ir::ReferenceMethod(method, range),
                                                shape.to_equivalent_call_shape(),
                                                forward_arguments,
                                                range);
        forward_call->mark_tail_call();

        stub = _new ir::MixinStub(method_name, klass, shape, method->range(), method->outline_range());
        body = _new ir::Return(forward_call, false, range);
      }
      stub->set_parameters(stub_parameters);
      stub->set_body(body);
      stub->set_return_type(method->return_type());
      if (method->does_not_return()) stub->mark_does_not_return();
      new_stubs.push_back(stub);
      existing_methods[method_name].insert(shape);
    }
  }

  if (!field_map.empty()) {
    ListBuilder<ir::Field*> field_builder;
    field_builder.add(klass->fields());
    field_map.for_each([&](ir::Field* key, ir::Field* new_field) {
      field_builder.add(new_field);
    });
    klass->replace_fields(field_builder.build());
  }
  if (!new_stubs.empty()) {
    ListBuilder<ir::MethodInstance*> method_builder;
    method_builder.add(klass->methods());
    for (auto stub : new_stubs) method_builder.add(stub);
    klass->replace_methods(method_builder.build());
  }
  return field_map;
}

/// This visitor modifies the class that mixes in other mixins.
/// It replaces its static super call with calls to mixins. It provides a block
/// to the mixin which is called when the next super class's constructer should be
/// invoked.
class ConstructorVisitor : protected SuperCallVisitor {
 public:
  ConstructorVisitor(ir::Class* holder, Map<ir::Field*, ir::Field*> field_map)
      : SuperCallVisitor(holder)
      , mixins_(holder->mixins())
      , field_map_(field_map) {}

  // Make `visit` public.
  ir::Node* visit(ir::Node* node) override {
    return SuperCallVisitor::visit(node);
  }

 protected:
  /// Insert the calls to the super mixins.
  /// We wrap each call to the next super into a block which is passed
  /// to the next constructor.
  /// This means that the call to the actual super is in the most nested block.
  ir::Node* visit_static_super_call(ir::CallStatic* original_super_expression,
                                    const Source::Range& range) override {
    bool is_block, has_default_value, is_final;
    // In Toit code we end up with something like:
    //     class A extends B with M1 M2 M3 M4:
    //       constructor:
    //         arg0 := ...  // Arguments to the super constructor
    //         arg1 := ...  // must be evaluated before the mixin calls.
    //         ...
    //         M4.constructor this: | this4 field_values... |
    //           this.M4-field-1 = field_value1
    //           this.M4-field-2 = field_value2
    //           ...
    //           M3.constructor this4: | this3 field_values... |
    //             ...
    //             M2.constructor this3: | this2 field_values... |
    //               ...
    //               M1.constructor this2: | this1 field_values... |
    //                 ...
    //                 B.constructor this1 arg0 arg1 ...
    ASSERT(outer_this_param_ != null);
    ASSERT(original_super_expression == null || original_super_expression->arguments().length() >= 1);
    ir::Expression* outermost_this_ref = original_super_expression == null
        ? _new ir::ReferenceLocal(outer_this_param_, 0, range)
        : original_super_expression->as_Call()->arguments()[0];

    // Keep track of how many block calls we do to reach the original expression.
    // At the end we will adjust the original super expression so that expressions
    // with side effects are hoisted, and that references to locals have their
    // block-depth adjusted.
    int original_args_block_depth = 0;

    // Create the 'this' parameter for each block.
    // We do this in advance, since each mixin gets the 'this' passed in,
    // and thus wants to use the one from a block that hasn't been created yet.
    // We will use this list to also update the original super expression at a
    // later point.
    std::vector<ir::Parameter*> this_params(mixins_.length());

    ir::Expression* super_expression = original_super_expression;
    for (int i = 0; i < mixins_.length(); i++) {
      int parameter_index;
      auto this_param = _new ir::Parameter(Symbols::this_,
                                          ir::Type::any(),
                                          is_block=false,
                                          // Parameter index 0 is reserved for the implicit block parameter.
                                          parameter_index=1,
                                          has_default_value=false,
                                          Source::Range::invalid(),
                                          range);
      this_params[i] = this_param;
    }

    // Note that the 'super_expression' can be null if the super class
    // of the current class is Object.
    for (int i = mixins_.length() - 1; i >= 0; i--) {
      auto mixin = mixins_[i];
      // Create a new block that takes as parameter 'this' and the values of each field.
      auto fields = mixin->fields();
      auto parameters = ListBuilder<ir::Parameter*>::allocate(fields.length() + 1);
      int body_length = fields.length();            // One for each store, and
      if (super_expression != null) body_length++;  // one for the next super.
      auto body = ListBuilder<ir::Expression*>::allocate(body_length);
      // Blocks reserve the first (0) parameter, and the 'this' parameter (above) took
      // the second (1) one.
      int parameter_index = 2;
      auto this_param = this_params[i];
      parameters[0] = this_param;
      for (int j = 0; j < fields.length(); j++) {
        auto field = fields[j];
        auto range = field->range();
        auto class_field = field_map_.at(field);
        auto parameter = _new ir::Parameter(field->name(),
                                            ir::Type::any(),
                                            is_block=false,
                                            parameter_index++,
                                            has_default_value=false,
                                            Source::Range::invalid(),
                                            range);
        parameters[j + 1] = parameter;
        // The body has a field-store for each parameter.
        body[j] = _new ir::FieldStore(_new ir::ReferenceLocal(this_param, 0, range),
                                      class_field,
                                      _new ir::ReferenceLocal(parameter, 0, range),
                                      range);
      }

      // Add the expression that was built up so far.
      if (super_expression) body[body.length() - 1] = super_expression;

      // Take these expressions and pass them to the next mixin constructor (wrapped
      // in a code/block object).
      auto body_sequence = _new ir::Sequence(body, range);
      auto name = Symbol::synthetic("<mixin-super>");
      auto block_code = _new ir::Code(name,
                                      parameters,
                                      body_sequence,
                                      is_block=true,
                                      range);
      // The original call was just wrapped into a block.
      original_args_block_depth++;

      // Blocks must be inside locals so that they can be referenced with `ReferenceBlock`.
      auto block = _new ir::Block(name, range);
      auto block_assig = _new ir::AssignmentDefine(block, block_code, range);
      ASSERT(mixin->unnamed_constructors().length() == 1);
      auto constructor = mixin->unnamed_constructors()[0];
      auto constructor_ref = _new ir::ReferenceMethod(constructor, range);
      auto arguments = ListBuilder<ir::Expression*>::allocate(2);
      auto outer_this = i == 0
          ? outermost_this_ref
          : _new ir::ReferenceLocal(this_params[i - 1], 0, range);
      arguments[0] = outer_this;
      arguments[1] = _new ir::ReferenceBlock(block, 0, range);
      auto call = _new ir::CallStatic(constructor_ref,
                                      constructor->plain_shape().to_equivalent_call_shape(),
                                      arguments,
                                      range);
      auto expressions = ListBuilder<ir::Expression*>::build(block_assig, call);
      super_expression = _new ir::Sequence(expressions, range);
    }

    // Adjust the arguments of the original call.
    if (original_super_expression != null) {
      ListBuilder<ir::Expression*> hoisted_args;
      auto arguments = original_super_expression->arguments();
      for (int i = 0; i < arguments.length(); i++) {
        auto arg = original_super_expression->arguments()[i];
        if (i == 0) {
          // Replace the 'this' with the one that is given as argument to the block.
          arguments[0] = _new ir::ReferenceLocal(this_params.back(), 0, arg->range());
          continue;
        }
        if (arg->is_Literal()) continue;
        if (arg->is_ReferenceLocal()) {
          auto ref = arg->as_ReferenceLocal();
          // Super calls must be at the "top-level" of the constructor, and
          // their arguments are thus at block-level 0, too.
          ASSERT(ref->block_depth() == 0);
          if (arg->is_ReferenceBlock()) {
            auto block_ref = ref->as_ReferenceBlock();
            arguments[i] = _new ir::ReferenceBlock(block_ref->target(),
                                                   original_args_block_depth,
                                                   arg->range());
          } else {
            arguments[i] = _new ir::ReferenceLocal(ref->target(),
                                                   original_args_block_depth,
                                                   ref->range());
          }
          continue;
        }
        // Hoist the argument.
        auto hoisted = _new ir::Local(Symbol::synthetic("<hoisted-super-arg>"),
                                      is_final=true,
                                      is_block=arg->is_block(),
                                      ir::Type::any(),
                                      arg->range());
        auto hoisted_def = _new ir::AssignmentDefine(hoisted, arg, arg->range());
        hoisted_args.add(hoisted_def);
        arguments[i] = _new ir::ReferenceLocal(hoisted, original_args_block_depth, arg->range());
      }
      if (!hoisted_args.is_empty()) {
        hoisted_args.add(super_expression);
        super_expression = _new ir::Sequence(hoisted_args.build(), range);
      }
    }
    return super_expression;
  }

  ir::Node* visit_Method(ir::Method* node) override {
    ASSERT(node->parameters().length() >= 1);
    outer_this_param_ = node->parameters()[0];
    return SuperCallVisitor::visit_Method(node);
  }

 private:
  List<ir::Class*> mixins_;
  Map<ir::Field*, ir::Field*> field_map_;
  ir::Parameter* outer_this_param_;
};

/// Changes super calls so that they call mixin constructors as well.
void adjust_super_calls(ir::Class* klass, Map<ir::Field*, ir::Field*> field_map) {
  ConstructorVisitor visitor(klass, field_map);
  for (auto constructor : klass->unnamed_constructors()) {
    visitor.visit(constructor);
  }
  for (auto node : klass->statics()->nodes()) {
    if (node->is_Method()) {
      auto method = node->as_Method();
      if (method->is_constructor()) {
        visitor.visit(method);
      }
    }
  };
}

void apply_mixins(ir::Program* program) {
  for (auto klass : program->classes()) {
    if (!klass->is_mixin()) continue;
    modify_mixin_constructor(klass);
  }
  for (auto klass : program->classes()) {
    if (klass->is_mixin() || klass->mixins().is_empty()) continue;
    auto field_map = apply_mixins(klass);
    adjust_super_calls(klass, field_map);
  }
}

} // namespace toit::compiler
} // namespace toit
