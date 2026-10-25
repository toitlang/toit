// Copyright (C) 2026 Toit contributors.
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

#include "lowering.h"

#include "ir.h"
#include "resolution.h"
#include "resolver_scope.h"

namespace toit {
namespace compiler {

namespace {

class Lowering : public resolution::Visitor {
 public:
  ir::Program* lower_program(resolution::ProgramView program) {
    // Allocate declaration identities before following any references. Method
    // bodies, class members, and global initializers may refer to one another.
    for (auto klass : program->classes()) {
      auto result = zone_new<ir::Class>(klass->name(),
          static_cast<ir::Class::Kind>(klass->kind()), klass->is_abstract(),
          klass->range(), klass->outline_range());
      nodes_[klass] = result;
      if (klass->is_runtime_class()) result->mark_runtime_class();
      if (klass->is_deprecated()) result->set_deprecation(klass->get_deprecation_message());
      if (klass->is_interface() || klass->is_mixin()) {
        result->set_typecheck_selector(klass->typecheck_selector());
      }
    }
    for (auto klass : program->classes()) {
      for (auto field : klass->fields()) {
        auto result = zone_new<ir::Field>(field->name(), lower(field->holder()),
            field->is_final(), field->range(), field->outline_range());
        nodes_[field] = result;
        result->set_type(lower_type(field->type()));
        if (field->is_deprecated()) result->set_deprecation(field->get_deprecation_message());
      }
    }
    for (auto klass : program->classes()) {
      for (auto method : klass->methods()) declare_method(method);
    }
    for (auto method : program->methods()) declare_method(method);
    for (auto global : program->globals()) declare_method(global);

    for (auto klass : program->classes()) {
      auto result = lower(klass);
      result->set_super(lower(klass->super()));
      result->set_interfaces(lower_list(klass->interfaces()));
      result->set_mixins(lower_list(klass->mixins()));
      result->set_unnamed_constructors(lower_list(klass->unnamed_constructors()));
      result->set_factories(lower_list(klass->factories()));
      result->set_methods(lower_list(klass->methods()));
      result->set_fields(lower_list(klass->fields()));
      std::vector<ir::Method*> statics;
      if (klass->statics() != null) {
        for (auto method : klass->statics()->nodes()) statics.push_back(lower(method));
      }
      result->set_statics(statics);
      // Resolution scopes and Toitdoc scopes belong exclusively to the frontend.
      for (auto method : klass->methods()) fill_method(method);
    }
    for (auto method : program->methods()) fill_method(method);
    for (auto global : program->globals()) fill_method(global);

    ListBuilder<ir::Type> literal_types;
    for (auto type : program->literal_types()) literal_types.add(lower_type(type));
    return zone_new<ir::Program>(lower_list(program->classes()),
        lower_list(program->methods()), lower_list(program->globals()),
        lower_list(program->tree_roots()), lower_list(program->entry_points()),
        literal_types.build(), lower(program->lookup_failure()),
        lower(program->as_check_failure()), lower(program->lambda_box()));
  }

 private:
  UnorderedMap<resolution::NodeView, ir::Node*> nodes_;
  ir::Node* result_ = null;

  ir::Node* lower_node(resolution::NodeView node) {
    if (node == null) return null;
    auto found = nodes_.find(node);
    if (found != nodes_.end()) return found->second;
    node->accept(this);
    auto result = result_;
    ASSERT(result != null);
    nodes_[node] = result;
    return result;
  }

#define LOWER(name) \
  ir::name* lower(resolution::name##View node) { \
    return static_cast<ir::name*>(lower_node(node)); \
  }
  RESOLUTION_NODES(LOWER)
#undef LOWER

  template<typename T>
  auto lower_list(List<resolution::View<T>> input) -> List<decltype(lower(resolution::View<T>()))> {
    typedef decltype(lower(resolution::View<T>())) Result;
    auto result = ListBuilder<Result>::allocate(input.length());
    for (int i = 0; i < input.length(); i++) result[i] = lower(input[i]);
    return result;
  }

  ir::Type lower_type(resolution::Type type) {
    if (!type.is_valid()) return ir::Type::invalid();
    if (type.is_none()) return ir::Type::none();
    if (type.is_any()) return ir::Type::any();
    auto result = ir::Type(lower(type.klass()));
    return type.is_nullable() ? result.to_nullable() : result;
  }

  void declare_method(resolution::MethodView method) {
    if (nodes_.find(method) != nodes_.end()) return;
    auto holder = lower(method->holder());
    auto name = method->name();
    auto range = method->range();
    auto outline = method->outline_range();
    auto shape = method->resolution_shape();
    ir::Method* result;
    if (method->is_Global()) {
      auto global = method->as_Global();
      auto lowered = zone_new<ir::Global>(name, holder, global->is_final(), range, outline);
      if (!global->is_effectively_final()) lowered->register_mutation();
      if (global->has_explicit_type()) lowered->set_explicit_return_type(lower_type(global->return_type()));
      result = lowered;
    } else if (method->is_Constructor()) {
      if (method->is_synthetic()) {
        result = zone_new<ir::Constructor>(name, holder, range, outline);
      } else {
        result = zone_new<ir::Constructor>(name, holder, shape, range, outline);
      }
    } else if (method->is_FieldStub()) {
      auto stub = method->as_FieldStub();
      auto lowered = zone_new<ir::FieldStub>(lower(stub->field()), holder,
          stub->is_getter(), range, outline);
      if (stub->is_throwing()) lowered->mark_throwing();
      if (stub->is_checking_setter()) lowered->set_checked_type(lower_type(stub->checked_type()));
      result = lowered;
    } else if (method->is_MonitorMethod()) {
      result = zone_new<ir::MonitorMethod>(name, holder, shape, range, outline);
    } else if (method->is_MethodInstance()) {
      result = zone_new<ir::MethodInstance>(static_cast<ir::Method::MethodKind>(method->kind()),
          name, holder, shape, method->is_abstract(), range, outline);
    } else {
      ASSERT(method->is_MethodStatic());
      result = zone_new<ir::MethodStatic>(name, holder, shape,
          static_cast<ir::Method::MethodKind>(method->kind()), range, outline);
    }
    nodes_[method] = result;
    result->replace_return_type(lower_type(method->return_type()));
    if (method->does_not_return()) result->mark_does_not_return();
    if (method->is_runtime_method()) result->mark_runtime_method();
    if (method->is_deprecated()) result->set_deprecation(method->get_deprecation_message());
  }

  void fill_method(resolution::MethodView method) {
    auto result = lower(method);
    result->set_parameters(lower_list(method->parameters()));
    result->set_body(lower(method->body()));
  }

  void copy_local_properties(resolution::LocalView local, ir::Local* result) {
    if (local->type().is_valid()) result->set_type(lower_type(local->type()));
    for (int i = 0; i < local->mutation_count(); i++) result->register_mutation();
    if (local->is_captured()) result->mark_captured();
    if (local->is_effectively_final_loop_variable()) result->mark_effectively_final_loop_variable();
    if (!local->has_explicit_type() && local->has_guaranteed_type()) {
      result->mark_guaranteed_inferred_type();
    }
    result_ = result;
  }

  void visit_Local(resolution::LocalView node) override {
    auto type = node->has_explicit_type() ? lower_type(node->type()) : ir::Type::invalid();
    auto result = zone_new<ir::Local>(node->name(), node->is_final(), node->is_block(), type, node->range());
    copy_local_properties(node, result);
  }

  void visit_Parameter(resolution::ParameterView node) override {
    auto type = node->has_explicit_type() ? lower_type(node->type()) : ir::Type::invalid();
    auto result = zone_new<ir::Parameter>(node->name(), type, node->is_block(),
        node->index(), node->original_index(), node->has_default_value(),
        node->default_value_range(), node->range());
    ListBuilder<ir::Parameter::MigrationType> types;
    for (auto migration : node->migration_types()) {
      types.add(ir::Parameter::MigrationType(lower_type(migration.type()),
          migration.is_deprecated(), migration.deprecation_message()));
    }
    result->set_migration_types(types.build());
    copy_local_properties(node, result);
  }

  void visit_CapturedLocal(resolution::CapturedLocalView node) override {
    // Mutation/type state is forwarded to the original local, not copied twice.
    result_ = zone_new<ir::CapturedLocal>(lower(node->local()), node->index(), node->range());
  }

  void visit_Block(resolution::BlockView node) override {
    auto result = zone_new<ir::Block>(node->name(), node->range());
    copy_local_properties(node, result);
  }

  void visit_Code(resolution::CodeView node) override {
    auto result = zone_new<ir::Code>(node->name(), lower_list(node->parameters()),
        lower(node->body()), node->is_block(), node->range());
    result->set_captured_count(node->captured_count());
    result_ = result;
  }

  void visit_Lambda(resolution::LambdaView node) override {
    Map<ir::Local*, int> captured;
    node->captured_depths().for_each([&](resolution::LocalView local, int depth) {
      captured[lower(local)] = depth;
    });
    auto result = zone_new<ir::Lambda>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), captured, node->range());
    result_ = result;
  }

  void visit_CallConstructor(resolution::CallConstructorView node) override {
    auto result = zone_new<ir::CallConstructor>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), node->range());
    result_ = result;
  }

  void visit_CallVirtual(resolution::CallVirtualView node) override {
    auto result = zone_new<ir::CallVirtual>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), node->range());
    switch (node->comparison_kind()) {
      case Token::EQ: result->set_opcode(INVOKE_EQ); break;
      case Token::LT: result->set_opcode(INVOKE_LT); break;
      case Token::LTE: result->set_opcode(INVOKE_LTE); break;
      case Token::GT: result->set_opcode(INVOKE_GT); break;
      case Token::GTE: result->set_opcode(INVOKE_GTE); break;
      case Token::ILLEGAL: break;  // Ordinary virtual dispatch.
      default: UNREACHABLE();
    }
    result_ = result;
  }

  void visit_Return(resolution::ReturnView node) override {
    if (node->is_end_of_method_return()) {
      result_ = zone_new<ir::Return>(lower(node->value()), true, node->range());
    } else {
      result_ = zone_new<ir::Return>(lower(node->value()), node->depth(), node->range());
    }
  }

  void visit_FieldLoad(resolution::FieldLoadView node) override {
    auto result = zone_new<ir::FieldLoad>(lower(node->receiver()), lower(node->field()), node->range());
    result_ = result;
  }

  void visit_FieldStore(resolution::FieldStoreView node) override {
    auto result = zone_new<ir::FieldStore>(lower(node->receiver()), lower(node->field()),
        lower(node->value()), node->range());
    result_ = result;
  }

  void visit_Error(resolution::ErrorView node) override {
    result_ = zone_new<ir::Error>(node->range(), lower_list(node->nested()));
  }

  void visit_Nop(resolution::NopView node) override {
    result_ = zone_new<ir::Nop>(node->range());
  }

  void visit_Sequence(resolution::SequenceView node) override {
    result_ = zone_new<ir::Sequence>(lower_list(node->expressions()), node->range());
  }

  void visit_Builtin(resolution::BuiltinView node) override {
    result_ = zone_new<ir::Builtin>(static_cast<ir::Builtin::BuiltinKind>(node->kind()));
  }

  void visit_TryFinally(resolution::TryFinallyView node) override {
    result_ = zone_new<ir::TryFinally>(lower(node->body()), lower_list(node->handler_parameters()), lower(node->handler()), node->range());
  }

  void visit_If(resolution::IfView node) override {
    result_ = zone_new<ir::If>(lower(node->condition()), lower(node->yes()), lower(node->no()), node->range());
  }

  void visit_Not(resolution::NotView node) override {
    result_ = zone_new<ir::Not>(lower(node->value()), node->range());
  }

  void visit_While(resolution::WhileView node) override {
    result_ = zone_new<ir::While>(lower(node->condition()), lower(node->body()), lower(node->update()), lower(node->loop_variable()), node->range());
  }

  void visit_LoopBranch(resolution::LoopBranchView node) override {
    result_ = zone_new<ir::LoopBranch>(node->is_break(), node->block_depth(), node->range());
  }

  void visit_ReferenceClass(resolution::ReferenceClassView node) override {
    result_ = zone_new<ir::ReferenceClass>(lower(node->target()), node->range());
  }

  void visit_ReferenceMethod(resolution::ReferenceMethodView node) override {
    result_ = zone_new<ir::ReferenceMethod>(lower(node->target()), node->range());
  }

  void visit_ReferenceGlobal(resolution::ReferenceGlobalView node) override {
    result_ = zone_new<ir::ReferenceGlobal>(lower(node->target()), node->is_lazy(), node->range());
  }

  void visit_ReferenceLocal(resolution::ReferenceLocalView node) override {
    result_ = zone_new<ir::ReferenceLocal>(lower(node->target()), node->block_depth(), node->range());
  }

  void visit_ReferenceBlock(resolution::ReferenceBlockView node) override {
    result_ = zone_new<ir::ReferenceBlock>(lower(node->target()), node->block_depth(), node->range());
  }

  void visit_Dot(resolution::DotView node) override {
    result_ = zone_new<ir::Dot>(lower(node->receiver()), node->selector());
  }

  void visit_LspSelectionDot(resolution::LspSelectionDotView node) override {
    result_ = zone_new<ir::LspSelectionDot>(lower(node->receiver()), node->selector(), node->name());
  }

  void visit_Super(resolution::SuperView node) override {
    result_ = zone_new<ir::Super>(lower(node->expression()), node->is_explicit(), node->is_at_end(), node->range());
  }

  void visit_Typecheck(resolution::TypecheckView node) override {
    result_ = zone_new<ir::Typecheck>(static_cast<ir::Typecheck::Kind>(node->kind()), lower(node->expression()), lower_type(node->type()), node->type_name(), node->range());
  }

  void visit_LogicalBinary(resolution::LogicalBinaryView node) override {
    result_ = zone_new<ir::LogicalBinary>(lower(node->left()), lower(node->right()), static_cast<ir::LogicalBinary::Operator>(node->op()), node->range());
  }

  void visit_AssignmentLocal(resolution::AssignmentLocalView node) override {
    result_ = zone_new<ir::AssignmentLocal>(lower(node->local()), node->block_depth(), lower(node->right()), node->range());
  }

  void visit_AssignmentGlobal(resolution::AssignmentGlobalView node) override {
    result_ = zone_new<ir::AssignmentGlobal>(lower(node->global()), lower(node->right()), node->range());
  }

  void visit_AssignmentDefine(resolution::AssignmentDefineView node) override {
    result_ = zone_new<ir::AssignmentDefine>(lower(node->local()), lower(node->right()), node->range());
  }

  void visit_LiteralNull(resolution::LiteralNullView node) override {
    result_ = zone_new<ir::LiteralNull>(node->range());
  }

  void visit_LiteralUndefined(resolution::LiteralUndefinedView node) override {
    result_ = zone_new<ir::LiteralUndefined>(node->range());
  }

  void visit_LiteralInteger(resolution::LiteralIntegerView node) override {
    result_ = zone_new<ir::LiteralInteger>(node->value(), node->range());
  }

  void visit_LiteralFloat(resolution::LiteralFloatView node) override {
    result_ = zone_new<ir::LiteralFloat>(node->value(), node->range());
  }

  void visit_LiteralString(resolution::LiteralStringView node) override {
    result_ = zone_new<ir::LiteralString>(node->value(), node->length(), node->range());
  }

  void visit_LiteralByteArray(resolution::LiteralByteArrayView node) override {
    result_ = zone_new<ir::LiteralByteArray>(node->data(), node->range());
  }

  void visit_LiteralBoolean(resolution::LiteralBooleanView node) override {
    result_ = zone_new<ir::LiteralBoolean>(node->value(), node->range());
  }

  void visit_PrimitiveInvocation(resolution::PrimitiveInvocationView node) override {
    result_ = zone_new<ir::PrimitiveInvocation>(node->module(), node->primitive(), node->module_index(), node->primitive_index(), node->range());
  }

  void visit_CallStatic(resolution::CallStaticView node) override {
    auto result = zone_new<ir::CallStatic>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), node->range());
    result_ = result;
  }

  void visit_CallBlock(resolution::CallBlockView node) override {
    auto result = zone_new<ir::CallBlock>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), node->range());
    result_ = result;
  }

  void visit_CallBuiltin(resolution::CallBuiltinView node) override {
    auto result = zone_new<ir::CallBuiltin>(lower(node->target()), node->shape(),
        lower_list(node->arguments()), node->range());
    result_ = result;
  }

  // Declarations must have been allocated before expression lowering. Backend
  // stubs are introduced later; abstract node categories are never instantiated.
#define UNEXPECTED(name) \
  void visit_##name(resolution::name##View node) override { UNREACHABLE(); }
  UNEXPECTED(Program)
  UNEXPECTED(Class)
  UNEXPECTED(Field)
  UNEXPECTED(Method)
  UNEXPECTED(MethodInstance)
  UNEXPECTED(MonitorMethod)
  UNEXPECTED(MethodStatic)
  UNEXPECTED(Constructor)
  UNEXPECTED(Global)
  UNEXPECTED(FieldStub)
  UNEXPECTED(Expression)
  UNEXPECTED(Reference)
  UNEXPECTED(Call)
  UNEXPECTED(Assignment)
  UNEXPECTED(Literal)
#undef UNEXPECTED
};

} // namespace anonymous

ir::Program* lower_to_ir(resolution::ProgramView program) {
  Lowering lowering;
  return lowering.lower_program(program);
}

} // namespace toit::compiler
} // namespace toit
