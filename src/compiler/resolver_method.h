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

#pragma once

#include "resolution_call_builder.h"
#include <vector>
#include <functional>

#include "ast.h"
#include "resolution.h"
#include "diagnostic.h"
#include "map.h"
#include "resolver_scope.h"
#include "symbol.h"

namespace toit {
namespace compiler {

class LspSelectionHandler;

class MethodResolver : public ast::Visitor {
 private:
  enum LoopStatus {
    NO_LOOP,  // Currently not in a loop.
    IN_LOOP,  // In a loop. (Break/continue is active).
    IN_BLOCKED_LOOP,  // In a loop, but also in a block.
    IN_LAMBDA_LOOP,   // In a loop, but also in a lambda (break/continue is not allowed).
  };

  enum ResolutionMode {
    STATIC,                     // Compiling static code.
    CONSTRUCTOR_STATIC,         // Compiling the static part of the constructor.
    CONSTRUCTOR_INSTANCE,       // Compiling the dynamic/instance part of the constructor.
    CONSTRUCTOR_LIMBO_STATIC,   // Compiling the body of a constructor that is still static.
    CONSTRUCTOR_LIMBO_INSTANCE, // Compiling the body of a constructor that has implicitly switched to dynamic.
    CONSTRUCTOR_SUPER,          // Compiling the super call in the constructor.
    FIELD,                      // Compiling the initializer of fields.
    INSTANCE,                   // Compiling instance code.
  };

 public:
  MethodResolver(resolution::Method* method,
                 resolution::Class* holder,
                 Scope* scope,
                 UnorderedMap<resolution::Node*, ast::Node*>* ir_to_ast_map,
                 Module* entry_module,
                 Module* core_module,
                 Lsp* lsp,
                 SourceManager* source_manager,
                 Diagnostics* diagnostics)
      : method_(method)
      , holder_(holder)
      , ir_to_ast_map_(ir_to_ast_map)
      , entry_module_(entry_module)
      , core_module_(core_module)
      , lsp_(lsp)
      , source_manager_(source_manager)
      , diagnostics_(diagnostics)
      , scope_(scope)
      , resolution_mode_(STATIC)
      , super_forcing_expression_(null)
      , block_has_direct_field_access_(true)
      , current_lambda_(null)
      , loop_status_(NO_LOOP)
      , loop_block_depth_(0) {
    auto core_scope = core_module->scope();
    auto entry = core_scope->lookup(Symbols::bool_).entry;
    if (!entry.is_class()) FATAL("MISSING BOOL TYPE");
    bool_type_ = resolution::Type(entry.klass());
    entry = core_scope->lookup(Symbols::True).entry;
    if (!entry.is_class()) FATAL("MISSING TRUE TYPE");
    true_type_ = resolution::Type(entry.klass());
    entry = core_scope->lookup(Symbols::False).entry;
    if (!entry.is_class()) FATAL("MISSING FALSE TYPE");
    false_type_ = resolution::Type(entry.klass());
  }

  void resolve_fill();

  /// Resolves the given field, and generates diagnostic messages.
  void resolve_field(resolution::Field* ir_field);

  static Symbol this_identifier() { return Symbols::this_; }

  std::vector<resolution::AssignmentGlobal*>& global_assignments() { return global_assignments_; }

 private:
  resolution::Type resolve_type(ast::Expression* node, bool is_return_type);
  void resolve_fill_field_stub();
  void resolve_fill_constructor();
  void resolve_fill_global();
  void resolve_fill_method();

  int _find_super_invocation(List<ast::Expression*> expressions);
  resolution::Expression* _accumulate_concatenation(resolution::Expression* lhs, resolution::Expression* rhs, Source::Range range);

 private:
  typedef const std::function<resolution::Local* (resolution::Expression*)> CreateTemp;
  typedef const std::function<resolution::Expression* (resolution::Expression*)> StoreOldValue;

  resolution::Method* method_;
  resolution::Class* holder_;
  UnorderedMap<resolution::Node*, ast::Node*>* ir_to_ast_map_;
  Module* entry_module_;
  Module* core_module_;
  Lsp* lsp_;
  SourceManager* source_manager_;
  Diagnostics* diagnostics_;
  std::vector<resolution::Node*> stack_;
  Scope* scope_;
  ResolutionMode resolution_mode_;
  // The expression that forced to switch the constructor to instance mode.
  ast::Expression* super_forcing_expression_;
  /// Assuming we are in the static part of a constructor, whether
  /// the current block is allowed to access a field directly.
  ///
  /// Specifically, we do allow:
  ///     class A:
  ///       field-x/int
  ///       field-y/int
  ///       constructor:
  ///         field-y = 499
  ///         [1].do:
  ///           field-x = field-y + it
  ///
  /// However, we don't allow:
  ///     constructor:
  ///        b := :
  ///          field-x = 499
  ///          field-y = 499
  ///        field-x = 42
  ///        field-y = 42
  ///        super
  ///        b.call
  bool block_has_direct_field_access_;
  ast::Node* current_lambda_;
  LoopStatus loop_status_;
  int loop_block_depth_;
  bool has_primitive_invocation_ = false;
  std::vector<std::pair<Symbol, ast::Node*>> break_continue_label_stack_;

  std::vector<resolution::AssignmentGlobal*> global_assignments_;

  resolution::Type bool_type_ = resolution::Type::invalid();
  resolution::Type true_type_ = resolution::Type::invalid();
  resolution::Type false_type_ = resolution::Type::invalid();

  SourceManager* source_manager() const { return source_manager_; }
  Diagnostics* diagnostics() const { return diagnostics_; }
  Scope* scope() const { return scope_; }

  void push(resolution::Node* value) {
    ASSERT(value != null);
    stack_.push_back(value);
  }

  resolution::Node* pop() {
    ASSERT(!stack_.empty());
    resolution::Node* result = stack_.back();
    stack_.pop_back();
    return result;
  }

  resolution::Expression* resolve_expression(ast::Node* node, const char* error_when_block, bool allow_assignment = false);
  resolution::Expression* resolve_statement(ast::Node* node, const char* error_when_block);
  // Resolves an expression that was already reported as error.
  // Doesn't restrict the expression to avoid dependent errors.
  resolution::Expression* resolve_error(ast::Node* node);

  Scope::LookupResult lookup(Symbol name) const { return scope_->lookup(name); }
  Scope::LookupResult lookup(ast::Identifier* id) const { return lookup(id->data()); }

  void report_abstract_class_instantiation_error(const ast::Node* position_node,
                                                 resolution::Class* ir_class);
  void report_error(resolution::Node* position_node, const char* format, ...);
  void report_error(const ast::Node* position_node, const char* format, ...);
  void report_error(Source::Range range, const char* format, ...);
  void report_error(const char* format, ...);
  void report_note(resolution::Node* position_node, const char* format, ...);
  void report_note(const ast::Node* position_node, const char* format, ...);
  void report_note(Source::Range range, const char* format, ...);

  void _add_parameters_to_scope(LocalScope* scope, List<resolution::Parameter*> parameters);
  void _resolve_fill_parameters_return_type(Set<resolution::Parameter*>* field_storing_parameters,
                                            std::vector<resolution::Expression*>* parameter_expressions,
                                            bool is_constructor);
  void _resolve_fill_return_type();
  void _resolve_parameters(List<ast::Parameter*> ast_parameters,
                           bool has_implicit_this,
                           // The rest are output parameters.
                           List<resolution::Parameter*>* ir_parameters,
                           Set<resolution::Parameter*>* field_storing_parameters,
                           std::vector<resolution::Expression*>* parameter_expressions,
                           bool is_constructor,
                           int id_offset = 0);

  bool _parameter_has_explicit_type(resolution::Parameter* ir_parameter) const {
    if (!ir_parameter->type().is_any()) return true;
    auto ast_parameter = ir_to_ast_map_->at(ir_parameter)->as_Parameter();
    return ast_parameter->type() != null;
  }

  resolution::Expression* _resolve_constructor_super_target(ast::Node* target_node, CallShape shape);

  struct Candidates {
    Symbol name;
    int block_depth;
    List<resolution::Node*> nodes;
    // If the name resolved to a single class.
    // The nodes contain the unnamed constructor/factories in this case.
    // Erroneous programs may contain more than one class, in which case this
    //   field is not set.
    resolution::Class* klass;
    bool encountered_error;
  };
  Candidates _compute_target_candidates(ast::Node* target_node, Scope* scope);
  // Computes the constructor super candidates for the current [method_].
  List<resolution::Node*> _compute_constructor_super_candidates(ast::Node* target_node);
  resolution::Node* _resolve_call_target(ast::Node* target_node,
                                 CallShape shape,
                                 Scope* scope = null);

  resolution::Expression* _this_ref(Source::Range range,
                            bool ignore_resolution_mode = false);
  bool is_literal_this(ast::Node* node) {
    return node->is_Identifier() && node->as_Identifier()->data() == Symbols::this_;
  }
  bool is_literal_super(ast::Node* node) {
    return node->is_Identifier() && node->as_Identifier()->data() == Symbols::super;
  }
  bool is_reserved_identifier(ast::Node* node) {
    return node->is_Identifier() && is_reserved_identifier(node->as_Identifier()->data());
  }
  bool is_reserved_identifier(Symbol symbol) {
    return Symbols::is_reserved(symbol);
  }
  bool is_future_reserved_identifier(Symbol symbol) {
    return Symbols::is_future_reserved(symbol);
  }
  bool is_sdk_protected_identifier(Symbol symbol);

  void check_sdk_protection(Symbol name,
                            const Source::Range& caller_range,
                            const Source::Range& target_range);


  void _handle_lsp_call_dot(ast::Dot* ast_dot, resolution::Expression* ir_receiver);
  void _handle_lsp_call_identifier(ast::Node* ast_target, resolution::Node* ir_target1, resolution::Node* ir_target2);

  void _visit_potential_call_identifier(ast::Node* ast_target,
                                        ResolutionCallBuilder& call_builder,
                                        ast::LspSelection* named_lsp_selection,
                                        ast::Node* target_name_node,
                                        Symbol target_name);
  void _visit_potential_call_dot(ast::Dot* ast_dot,
                                 ResolutionCallBuilder& call_builder,
                                 ast::LspSelection* named_lsp_selection);
  void _visit_potential_call_index(ast::Node* ast_target,
                                   ResolutionCallBuilder& call_builder);
  void _visit_potential_call_index_slice(ast::Node* ast_target,
                                         ResolutionCallBuilder& call_builder);
  void _visit_potential_call_super(ast::Node* ast_target,
                                   ResolutionCallBuilder& call_builder,
                                   bool is_constructor_super_call,
                                   ast::LspSelection* named_lsp_selection);
  void _visit_potential_call(ast::Expression* potential_call,
                             ast::Node* ast_target,
                             List<ast::Expression*> ast_arguments = List<ast::Expression*>());

  resolution::Expression* _instantiate_runtime(Symbol id,
                                       List<resolution::Expression*> arguments,
                                       Source::Range range);

  resolution::ReferenceMethod* _resolve_runtime_call(Symbol id, CallShape shape);
  resolution::Expression* _call_runtime(Symbol id,
                                List<resolution::Expression*> arguments,
                                Source::Range range);

  resolution::Expression* _create_throw(resolution::Expression* exception,
                                Source::Range range);
  resolution::Expression* _create_array(List<resolution::Expression*> entries,
                                Source::Range range);

  List<resolution::Expression*> list_of(resolution::Expression* single) {
    return ListBuilder<resolution::Expression*>::build(single);
  }
  List<resolution::Expression*> list_of(resolution::Expression* first, resolution::Expression* second) {
    return ListBuilder<resolution::Expression*>::build(first, second);
  }
  List<resolution::Expression*> list_of(resolution::Expression* first, resolution::Expression* second, resolution::Expression* third) {
    return ListBuilder<resolution::Expression*>::build(first, second, third);
  }

  resolution::Code* _create_code(ast::Node* node,
                         List<ast::Parameter*> parameters,
                         ast::Sequence* body,
                         bool has_implicit_block_argument,
                         bool has_implicit_it_parameter,
                         Symbol label);
  resolution::Code* _create_block(ast::Block* node,
                          bool has_implicit_it_parameter,
                          bool may_mutate_final,
                          Symbol label);
  resolution::Expression* _create_lambda(ast::Lambda* node,
                                 Symbol label);
  void _visit_block(ast::Block* node);
  void visit_Block(ast::Block* node);
  void visit_Lambda(ast::Lambda* node);
  void visit_Sequence(ast::Sequence* node);
  void visit_DeclarationLocal(ast::DeclarationLocal* node);
  void visit_TryFinally(ast::TryFinally* node);
  void visit_If(ast::If* node);
  void visit_loop(ast::Node* node,
                  bool is_while,
                  ast::Expression* ast_initializer,
                  ast::Expression* ast_condition,
                  ast::Expression* ast_update,
                  ast::Expression* ast_body);
  void visit_While(ast::While* node);
  void visit_For(ast::For* node);
  void visit_BreakContinue(ast::BreakContinue* node);
  void visit_Error(ast::Error* node);
  void visit_Call(ast::Call* node);
  void visit_Dot(ast::Dot* node);
  void visit_Index(ast::Index* node);
  void visit_IndexSlice(ast::IndexSlice* node);
  void visit_labeled_break_continue(ast::BreakContinue* node);
  void visit_Return(ast::Return* node);
  void visit_Identifier(ast::Identifier* node);
  void visit_LspSelection(ast::LspSelection* node);
  void visit_LiteralNull(ast::LiteralNull* node);
  void visit_LiteralUndefined(ast::LiteralUndefined* node);
  void visit_literal_this(ast::Identifier* node);
  void visit_LiteralInteger(ast::LiteralInteger* node);
  void visit_LiteralString(ast::LiteralString* node) { visit_LiteralString(node, -1, true); }
  void visit_LiteralString(ast::LiteralString* node, int min_indentation, bool should_skip_leading);
  void visit_LiteralStringInterpolation(ast::LiteralStringInterpolation* node);
  void visit_LiteralBoolean(ast::LiteralBoolean* node);
  void visit_LiteralFloat(ast::LiteralFloat* node);
  void visit_LiteralCharacter(ast::LiteralCharacter* node);
  void visit_LiteralList(ast::LiteralList* node);
  void visit_LiteralByteArray(ast::LiteralByteArray* node);
  void visit_LiteralSet(ast::LiteralSet* node);
  void visit_LiteralMap(ast::LiteralMap* node);
  void visit_call_main(ast::Call* node);
  void visit_call_primitive(ast::Call* node);
  resolution::AssignmentLocal* _typed_assign_local(resolution::Local* local,
                                           int block_depth,
                                           resolution::Expression* value,
                                           Source::Range range);
  resolution::Expression* _as_or_is (ast::Binary* node);
  resolution::Expression* _definition_rhs(ast::Expression* node, Symbol name);
  resolution::Expression* _bad_define(ast::Binary* node);
  resolution::Expression* _define(ast::Expression* node, resolution::Expression* ir_right = null);
  resolution::Expression* _assign(ast::Binary* node, bool is_postfix = false);
  resolution::Expression* _assign_dot(ast::Binary* node,
                              CreateTemp& create_temp,
                              StoreOldValue& store_old);
  resolution::Expression* _assign_index(ast::Binary* node,
                                CreateTemp& create_temp,
                                StoreOldValue& store_old);
  resolution::Expression* _assign_instance_member(ast::Binary* node,
                                          Symbol selector,
                                          StoreOldValue& store_old);
  /// Returns whether the operation succeeded.
  ///
  /// Fills [ir_setter_node] and, if compound, the [ir_getter_node].
  /// The [block_depth] node is filled, if the setter/getter is a local.
  bool _assign_identifier_resolve_left(ast::Binary* node,
                                       resolution::Node** ir_setter_node,
                                       resolution::Node** ir_getter_node,
                                       int* block_depth);
  resolution::Expression* _assign_identifier(ast::Binary* node,
                                     StoreOldValue& store_old);
  resolution::Expression* _potentially_store_field(ast::Node* node,
                                           Symbol field_name,
                                           bool lookup_class_scope,
                                           ast::Expression* value,
                                           StoreOldValue& store_old);
  resolution::Expression* _potentially_load_field(Symbol field_name,
                                          bool lookup_class_scope,
                                          Source::Range range);
  resolution::Expression* _binary_operator(ast::Binary* node,
                                   resolution::Expression* ir_left = null,
                                   resolution::Expression* ir_right = null);
  resolution::Expression* _binary_comparison_operator(ast::Binary* node,
                                              resolution::Local* temporary = null);
  resolution::Expression* _logical_operator(ast::Binary* node);

  void visit_Binary(ast::Binary* node);
  void visit_Unary(ast::Unary* node);
  void visit_Parenthesis(ast::Parenthesis* node);
};

} // namespace toit::compiler
} // namespace toit
