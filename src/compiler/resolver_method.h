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

#include <functional>

#include "ast.h"
#include "ir.h"
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
  MethodResolver(ir::Method* method,
                 ir::Class* holder,
                 Scope* scope,
                 UnorderedMap<ir::Node*, ast::Node*>* ir_to_ast_map,
                 Module* entry_module,
                 Module* core_module,
                 LspSelectionHandler* lsp_selection_handler,
                 SourceManager* source_manager,
                 Diagnostics* diagnostics)
      : _method(method)
      , _holder(holder)
      , _ir_to_ast_map(ir_to_ast_map)
      , _entry_module(entry_module)
      , _core_module(core_module)
      , _lsp_selection_handler(lsp_selection_handler)
      , _source_manager(source_manager)
      , _diagnostics(diagnostics)
      , _scope(scope)
      , _resolution_mode(STATIC)
      , _super_forcing_expression(null)
      , _current_lambda(null)
      , _loop_status(NO_LOOP)
      , _loop_block_depth(0) { }

  void resolve_fill();

  /// Resolves the given field, and generates diagnostic messages.
  void resolve_field(ir::Field* ir_field);

  static Symbol this_identifier() { return Symbols::this_; }

 private:
  ir::Type resolve_type(ast::Expression* node, bool is_return_type);
  void resolve_fill_field_stub();
  void resolve_fill_constructor();
  void resolve_fill_global();
  void resolve_fill_method();

  int _find_super_invocation(List<ast::Expression*> expressions);
  ir::Expression* _accumulate_concatenation(ir::Expression* lhs, ir::Expression* rhs, Source::Range range);

 private:
  typedef const std::function<ir::Local* (ir::Expression*)> CreateTemp;
  typedef const std::function<ir::Expression* (ir::Expression*)> StoreOldValue;

  ir::Method* _method;
  ir::Class* _holder;
  UnorderedMap<ir::Node*, ast::Node*>* _ir_to_ast_map;
  Module* _entry_module;
  Module* _core_module;
  LspSelectionHandler* _lsp_selection_handler;
  SourceManager* _source_manager;
  Diagnostics* _diagnostics;
  std::vector<ir::Node*> _stack;
  Scope* _scope;
  ResolutionMode _resolution_mode;
  // The expression that forced to switch the constructor to instance mode.
  ast::Expression* _super_forcing_expression;
  ast::Node* _current_lambda;
  LoopStatus _loop_status;
  int _loop_block_depth;
  bool _has_primitive_invocation = false;
  std::vector<std::pair<Symbol, ast::Node*>> _break_continue_label_stack;

  SourceManager* source_manager() const { return _source_manager; }
  Diagnostics* diagnostics() const { return _diagnostics; }
  Scope* scope() const { return _scope; }

  void push(ir::Node* value) {
    ASSERT(value != null);
    _stack.push_back(value);
  }

  ir::Node* pop() {
    ASSERT(!_stack.empty());
    ir::Node* result = _stack.back();
    _stack.pop_back();
    return result;
  }

  ir::Expression* resolve_expression(ast::Node* node, const char* error_when_block, bool allow_assignment = false);
  ir::Expression* resolve_statement(ast::Node* node, const char* error_when_block);
  // Resolves an expression that was already reported as error.
  // Doesn't restrict the expression to avoid dependent errors.
  ir::Expression* resolve_error(ast::Node* node);

  Scope::LookupResult lookup(Symbol name) const { return _scope->lookup(name); }
  Scope::LookupResult lookup(ast::Identifier* id) const { return lookup(id->data()); }

  void report_abstract_class_instantiation_error(const ast::Node* position_node,
                                                 ir::Class* ir_class);
  void report_error(ir::Node* position_node, const char* format, ...);
  void report_error(const ast::Node* position_node, const char* format, ...);
  void report_error(Source::Range range, const char* format, ...);
  void report_error(const char* format, ...);
  void report_note(ir::Node* position_node, const char* format, ...);
  void report_note(const ast::Node* position_node, const char* format, ...);
  void report_note(Source::Range range, const char* format, ...);

  void _add_parameters_to_scope(LocalScope* scope, List<ir::Parameter*> parameters);
  void _resolve_fill_parameters_return_type(Set<ir::Parameter*>* field_storing_parameters,
                                            std::vector<ir::Expression*>* parameter_expressions);
  void _resolve_fill_return_type();
  void _resolve_parameters(List<ast::Parameter*> ast_parameters,
                           bool has_implicit_this,
                           // The rest are output parameters.
                           List<ir::Parameter*>* ir_parameters,
                           Set<ir::Parameter*>* field_storing_parameters,
                           std::vector<ir::Expression*>* parameter_expressions,
                           int id_offset = 0);

  bool _parameter_has_explicit_type(ir::Parameter* ir_parameter) const {
    if (!ir_parameter->type().is_any()) return true;
    auto ast_parameter = _ir_to_ast_map->at(ir_parameter)->as_Parameter();
    return ast_parameter->type() != null;
  }

  ir::Expression* _resolve_constructor_super_target(ast::Node* target_node, CallShape shape);

  struct Candidates {
    Symbol name;
    int block_depth;
    List<ir::Node*> nodes;
    // If the name resolved to a single class.
    // The nodes contain the unnamed constructor/factories in this case.
    // Erroneous programs may contain more than one class, in which case this
    //   field is not set.
    ir::Class* klass;
    bool encountered_error;
  };
  Candidates _compute_target_candidates(ast::Node* target_node, Scope* scope);
  // Computes the constructor super candidates for the current [_method].
  List<ir::Node*> _compute_constructor_super_candidates(ast::Node* target_node);
  ir::Node* _resolve_call_target(ast::Node* target_node,
                                 CallShape shape,
                                 Scope* scope = null);

  ir::Expression* _this_ref(Source::Range range,
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
  bool is_sdk_protected_identifier(Symbol symbol);

  void check_sdk_protection(Symbol name,
                            const Source::Range& caller_range,
                            const Source::Range& target_range);


  void _handle_lsp_call_dot(ast::Dot* ast_dot, ir::Expression* ir_receiver);
  void _handle_lsp_call_identifier(ast::Node* ast_target, ir::Node* ir_target1, ir::Node* ir_target2);

  void _visit_potential_call_identifier(ast::Node* ast_target,
                                        CallBuilder& call_builder,
                                        ast::LspSelection* named_lsp_selection,
                                        ast::Node* target_name_node,
                                        Symbol target_name);
  void _visit_potential_call_dot(ast::Dot* ast_dot,
                                 CallBuilder& call_builder,
                                 ast::LspSelection* named_lsp_selection);
  void _visit_potential_call_index(ast::Index* ast_index,
                                   CallBuilder& call_builder);
  void _visit_potential_call_index_slice(ast::IndexSlice* ast_index_slice,
                                         CallBuilder& call_builder);
  void _visit_potential_call_super(ast::Node* ast_target,
                                   CallBuilder& call_builder,
                                   bool is_constructor_super_call);
  void _visit_potential_call(ast::Node* ast_target,
                             List<ast::Expression*> ast_arguments = List<ast::Expression*>());

  ir::Expression* _instantiate_runtime(Symbol id,
                                       List<ir::Expression*> arguments,
                                       Source::Range range);

  ir::ReferenceMethod* _resolve_runtime_call(Symbol id, CallShape shape);
  ir::Expression* _call_runtime(Symbol id,
                                List<ir::Expression*> arguments,
                                Source::Range range);

  ir::Expression* _create_throw(ir::Expression* exception,
                                Source::Range range);
  ir::Expression* _create_array(List<ir::Expression*> entries,
                                Source::Range range);

  List<ir::Expression*> list_of(ir::Expression* single) {
    return ListBuilder<ir::Expression*>::build(single);
  }
  List<ir::Expression*> list_of(ir::Expression* first, ir::Expression* second) {
    return ListBuilder<ir::Expression*>::build(first, second);
  }
  List<ir::Expression*> list_of(ir::Expression* first, ir::Expression* second, ir::Expression* third) {
    return ListBuilder<ir::Expression*>::build(first, second, third);
  }

  ir::Code* _create_code(ast::Node* node,
                         List<ast::Parameter*> parameters,
                         ast::Sequence* body,
                         bool has_implicit_block_argument,
                         bool has_implicit_it_parameter,
                         Symbol label);
  ir::Code* _create_block(ast::Block* node,
                          bool has_implicit_it_parameter,
                          Symbol label);
  ir::Expression* _create_lambda(ast::Lambda* node,
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
  ir::AssignmentLocal* _typed_assign_local(ir::Local* local,
                                           int block_depth,
                                           ir::Expression* value,
                                           Source::Range range);
  ir::Expression* _as_or_is (ast::Binary* node);
  ir::Expression* _definition_rhs(ast::Expression* node, Symbol name);
  ir::Expression* _bad_define(ast::Binary* node);
  ir::Expression* _define(ast::Expression* node, ir::Expression* ir_right = null);
  ir::Expression* _assign(ast::Binary* node, bool is_postfix = false);
  ir::Expression* _assign_dot(ast::Binary* node,
                              CreateTemp& create_temp,
                              StoreOldValue& store_old);
  ir::Expression* _assign_index(ast::Binary* node,
                                CreateTemp& create_temp,
                                StoreOldValue& store_old);
  ir::Expression* _assign_instance_member(ast::Binary* node,
                                          Symbol selector,
                                          StoreOldValue& store_old);
  /// Returns whether the operation succeeded.
  ///
  /// Fills [ir_setter_node] and, if compound, the [ir_getter_node].
  /// The [block_depth] node is filled, if the setter/getter is a local.
  bool _assign_identifier_resolve_left(ast::Binary* node,
                                       ir::Node** ir_setter_node,
                                       ir::Node** ir_getter_node,
                                       int* block_depth);
  ir::Expression* _assign_identifier(ast::Binary* node,
                                     StoreOldValue& store_old);
  ir::Expression* _potentially_store_field(ast::Node* node,
                                           Symbol field_name,
                                           bool lookup_class_scope,
                                           ast::Expression* value,
                                           StoreOldValue& store_old);
  ir::Expression* _potentially_load_field(Symbol field_name,
                                          bool lookup_class_scope,
                                          Source::Range range);
  ir::Expression* _binary_operator(ast::Binary* node,
                                   ir::Expression* ir_left = null,
                                   ir::Expression* ir_right = null);
  ir::Expression* _binary_comparison_operator(ast::Binary* node,
                                              ir::Local* temporary = null);
  ir::Expression* _logical_operator(ast::Binary* node);

  void visit_Binary(ast::Binary* node);
  void visit_Unary(ast::Unary* node);
  void visit_Parenthesis(ast::Parenthesis* node);
};

} // namespace toit::compiler
} // namespace toit
