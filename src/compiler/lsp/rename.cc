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

#include "rename.h"
#include "../ast.h"
#include "../ir.h"
#include "../token.h"
#include "../sources.h"
#include "../package.h"
#include "../resolver_scope.h"
#include "../toitdoc.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

// ---------------------------------------------------------------------------
// VirtualCallFilter — determines whether a CallVirtual should be included
// in rename results.  See find_and_emit_all_references for usage.
// ---------------------------------------------------------------------------

class VirtualCallFilter {
 public:
  static VirtualCallFilter build(ir::Node* target,
                                 ir::Program* program,
                                 SourceManager* source_manager);

  bool should_include(ir::CallVirtual* node) const;

  void set_setter(ir::FieldStub* setter) { setter_ = setter; }
  bool is_active() const { return method_ != null; }
  ir::Method* method() const { return method_; }
  const UnorderedSet<ir::Class*>& participating_classes() const {
    return participating_classes_;
  }

 private:
  VirtualCallFilter()
      : method_(null)
      , setter_(null)
      , is_ambiguous_(false)
      , target_source_path_(null)
      , source_manager_(null) {}

  void compute_participating_classes(ir::Program* program);
  void detect_ambiguity(ir::Program* program);

  ir::Method* method_;
  ir::FieldStub* setter_;
  UnorderedSet<ir::Class*> participating_classes_;
  bool is_ambiguous_;
  std::string target_package_id_;
  const char* target_source_path_;
  SourceManager* source_manager_;
};

// ---------------------------------------------------------------------------
// FindReferencesVisitor — traverses IR trees to find references to a target.
// ---------------------------------------------------------------------------

class FindReferencesVisitor : public ir::TraversingVisitor {
 public:
  FindReferencesVisitor(ir::Node* target,
                        Source::Range definition_range,
                        int target_name_len,
                        SourceManager* source_manager,
                        UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                        LspProtocol* protocol,
                        const VirtualCallFilter& virtual_call_filter);

  void visit_Reference(ir::Reference* node) override;
  void visit_CallStatic(ir::CallStatic* node) override;
  void visit_CallVirtual(ir::CallVirtual* node) override;
  void visit_Typecheck(ir::Typecheck* node) override;

  void emit_range(const Source::Range& range);

 private:
  void emit_named_argument_reference(ir::Call* node, Symbol param_name);

  ir::Node* target_;
  ir::Class* target_class_;
  Source::Range definition_range_;
  int target_name_len_;
  SourceManager* source_manager_;
  UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map_;
  LspProtocol* protocol_;
  const VirtualCallFilter& virtual_call_filter_;
};

// ---------------------------------------------------------------------------
// FindReferencesHandler method implementations
// ---------------------------------------------------------------------------

void FindReferencesHandler::call_class(ast::Dot* node,
                                       ir::Class* klass,
                                       ir::Node* resolved1,
                                       ir::Node* resolved2,
                                       List<ir::Node*> candidates,
                                       IterableScope* scope) {
  // When the LSP cursor is on the name part of a Class.member expression
  // (e.g., "bar" in "Foo.bar"), the resolver sometimes takes the LspSelection
  // fallback path and doesn't resolve the static member. Look up the named
  // constructor/factory/static method in the class's statics scope.
  if (resolved1 == null && resolved2 == null && candidates.is_empty() &&
      klass != null && klass->statics() != null) {
    auto selector = node->name()->data();
    for (auto* method : klass->statics()->nodes()) {
      if (method->name() == selector) {
        resolved1 = method;
        break;
      }
    }
  }
  call_static(node, resolved1, resolved2, candidates, scope, null);
}

void FindReferencesHandler::call_static(ast::Node* node,
                                        ir::Node* resolved1,
                                        ir::Node* resolved2,
                                        List<ir::Node*> candidates,
                                        IterableScope* scope,
                                        ir::Method* surrounding) {
  // Don't overwrite target if already set (e.g., by class_interface_or_mixin
  // when the cursor is on the class part of a static call like Foo.bar).
  if (target_ != null) return;
  ir::Node* target = null;
  if (resolved2 != null) {
    target = resolved2;
  } else if (resolved1 != null) {
    target = resolved1;
  } else if (candidates.length() == 1) {
    target = candidates[0];
  }
  if (target != null) {
    target = unwrap_reference(target);
    // When the resolved target is an unnamed constructor or factory called
    // by class name (e.g., `MyObj`), the user intends to rename the class,
    // not the constructor. Resolve to the holder class instead.
    // Named constructors (e.g., `constructor.deserialize`) should NOT be
    // redirected — the user wants to rename the constructor's own name.
    if (target->is_Method()) {
      auto* method = target->as_Method();
      if ((method->is_constructor() || method->is_factory()) && method->holder() != null) {
        auto holder_name = method->holder()->name();
        if (method->name() == holder_name || method->name() == Symbols::constructor) {
          target = method->holder();
        }
      }
    }
    target_ = target;
    // For dot-access calls (Foo.bar, prefix.bar), the Dot's selection_range
    // may include the "." prefix. Use the name identifier's range instead
    // so that prepareRename returns just the name portion.
    if (node->is_Dot()) {
      cursor_range_ = node->as_Dot()->name()->selection_range();
    } else {
      cursor_range_ = node->selection_range();
    }
  }
}

// ---------------------------------------------------------------------------
// VirtualCallFilter
// ---------------------------------------------------------------------------

/// Returns the package ID of the source file containing the given IR node.
/// Falls back to ERROR_PACKAGE_ID if the source cannot be determined.
static std::string package_id_for_range(const Source::Range& range,
                                        SourceManager* source_manager) {
  if (!range.is_valid()) return Package::ERROR_PACKAGE_ID;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return Package::ERROR_PACKAGE_ID;
  return source->package_id();
}

/// Returns the absolute path of the source file containing the given IR range.
/// Returns null if the source cannot be determined.
static const char* source_path_for_range(const Source::Range& range,
                                         SourceManager* source_manager) {
  if (!range.is_valid()) return null;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return null;
  return source->absolute_path();
}

/// Returns whether a class defines an instance method with the given name
/// and a shape that accepts the given call shape.
static bool class_has_matching_method(ir::Class* klass,
                                      Symbol name,
                                      const CallShape& shape) {
  for (auto method : klass->methods()) {
    if (method->name() == name &&
        method->resolution_shape().accepts(shape)) {
      return true;
    }
  }
  return false;
}

VirtualCallFilter VirtualCallFilter::build(ir::Node* target,
                                           ir::Program* program,
                                           SourceManager* source_manager) {
  VirtualCallFilter filter;
  filter.source_manager_ = source_manager;

  // Only active for instance methods with a holder class.
  if (target == null || !target->is_Method()) return filter;
  auto* method = target->as_Method();
  if (method->holder() == null) return filter;
  if (!method->is_instance()) return filter;

  // Operators cannot be meaningfully renamed.
  if (is_operator_name(method->name())) return filter;

  // SDK methods cannot be renamed — their source files are not
  // user-editable. Don't match virtual call sites for them.
  if (is_sdk_target(target, source_manager)) return filter;

  filter.method_ = method;

  // Determine the target method's source location metadata.
  auto holder_range = method->holder()->range();
  filter.target_package_id_ = package_id_for_range(holder_range, source_manager);
  filter.target_source_path_ = source_path_for_range(holder_range, source_manager);

  filter.compute_participating_classes(program);
  filter.detect_ambiguity(program);

  return filter;
}

void VirtualCallFilter::compute_participating_classes(ir::Program* program) {
  auto* holder = method_->holder();
  Symbol name = method_->name();
  // Build the call shape from the method's resolution shape so we can
  // test compatibility with other methods' resolution shapes via `accepts`.
  auto method_shape = method_->resolution_shape().to_plain_shape().to_equivalent_call_shape();

  // Phase 1: Walk up from the holder through supers.
  // Add each ancestor that defines a method with the same name and
  // compatible shape.
  for (auto* klass = holder; klass != null; klass = klass->super()) {
    if (class_has_matching_method(klass, name, method_shape)) {
      participating_classes_.insert(klass);
    }
  }

  // Phase 2: Add connected interfaces and mixins.
  // Walk outward from the participating classes found in Phase 1 and add
  // any interface or mixin that declares the matching method.
  // We also walk up through interface/mixin inheritance (super-interfaces)
  // to find parent interfaces that declare the same method, and then
  // walk back down to find sibling branches — this ensures multi-path
  // hierarchies are fully covered.
  //
  // Example: if I1 is extended by both I2 and I3, class A implements I2,
  // class B implements I3, and all define foo(), Phase 1 finds A.
  // Walking outward from A finds I2. Walking up from I2 finds I1 (which
  // also declares foo). Walking down from I1 finds I3, and Phase 3 will
  // then find B (which implements I3).
  //
  // We iterate until no new interfaces/mixins are added.
  {
    bool changed = true;
    while (changed) {
      changed = false;
      UnorderedSet<ir::Class*> to_add;
      // Collect interfaces/mixins referenced by current participants.
      for (auto* participant : participating_classes_.underlying_set()) {
        auto check_connector = [&](ir::Class* connector) {
          if (participating_classes_.contains(connector)) return;
          if (!class_has_matching_method(connector, name, method_shape)) return;
          to_add.insert(connector);
        };
        for (auto* iface : participant->interfaces()) check_connector(iface);
        for (auto* mixin : participant->mixins()) check_connector(mixin);
        // Walk up through interface/mixin super-classes.
        if (participant->is_interface() || participant->is_mixin()) {
          if (participant->has_super()) check_connector(participant->super());
        }
      }
      // Also check if any non-participating interface/mixin is connected
      // to a participating one through its implementors/sub-interfaces.
      for (auto* klass : program->classes()) {
        if (participating_classes_.contains(klass)) continue;
        if (to_add.contains(klass)) continue;
        if (!klass->is_interface() && !klass->is_mixin()) continue;
        if (!class_has_matching_method(klass, name, method_shape)) continue;
        // Check if any participating class implements/mixes in this class.
        for (auto* participant : participating_classes_.underlying_set()) {
          auto connectors = klass->is_interface()
              ? participant->interfaces()
              : participant->mixins();
          for (auto* connector : connectors) {
            if (connector == klass) {
              to_add.insert(klass);
              break;
            }
          }
          if (to_add.contains(klass)) break;
        }
      }
      for (auto* klass : to_add.underlying_set()) {
        participating_classes_.insert(klass);
        changed = true;
      }
    }
  }

  // Phase 3: Walk all classes and add descendants of any participating class.
  // A descendant inherits the method definition even if it doesn't override
  // it, so virtual calls on descendants should also match.
  //
  // We iterate until no new classes are added (fixed-point), because
  // adding a descendant may cause its own descendants to become reachable.
  bool changed = true;
  while (changed) {
    changed = false;
    for (auto* klass : program->classes()) {
      if (participating_classes_.contains(klass)) continue;
      // Check if any of klass's supers or interfaces/mixins are participating.
      if (klass->has_super() && participating_classes_.contains(klass->super())) {
        participating_classes_.insert(klass);
        changed = true;
        continue;
      }
      for (auto iface : klass->interfaces()) {
        if (participating_classes_.contains(iface)) {
          participating_classes_.insert(klass);
          changed = true;
          break;
        }
      }
      for (auto mixin : klass->mixins()) {
        if (participating_classes_.contains(mixin)) {
          participating_classes_.insert(klass);
          changed = true;
          break;
        }
      }
    }
  }
}

void VirtualCallFilter::detect_ambiguity(ir::Program* program) {
  Symbol name = method_->name();
  auto method_shape = method_->resolution_shape().to_plain_shape()
                          .to_equivalent_call_shape();

  for (auto* klass : program->classes()) {
    // Skip classes that are part of our dispatch hierarchy.
    if (participating_classes_.contains(klass)) continue;

    if (class_has_matching_method(klass, name, method_shape)) {
      is_ambiguous_ = true;
      return;
    }
  }

  is_ambiguous_ = false;
}

bool VirtualCallFilter::should_include(ir::CallVirtual* node) const {
  if (method_ == null) return false;

  if (node->selector() != method_->name()) return false;

  // Check if the call shape matches the primary method or the setter.
  // For field targets the filter is built from the getter, and the setter
  // is registered separately via set_setter().
  bool shape_ok = method_->resolution_shape().accepts(node->shape());
  if (!shape_ok && setter_ != null) {
    shape_ok = setter_->resolution_shape().accepts(node->shape());
  }
  if (!shape_ok) return false;

  // Name and shape match. If the method is unambiguous across the entire
  // program, every matching virtual call must dispatch to our hierarchy.
  if (!is_ambiguous_) return true;

  // Ambiguous case: apply package-based proximity filtering.
  // Determine the call site's source location.
  auto* call_source = source_manager_->source_for_position(node->range().from());
  if (call_source == null) return false;

  // Same source file: highest confidence — the call is almost certainly
  // referencing the local hierarchy.
  if (target_source_path_ != null &&
      strcmp(call_source->absolute_path(), target_source_path_) == 0) {
    return true;
  }

  // Same package: the call site is in the same library/package as the
  // target method's holder class, so it likely refers to the same hierarchy.
  if (call_source->package_id() == target_package_id_) return true;

  // Different package with an ambiguous name: skip to avoid false positives.
  return false;
}

// ---------------------------------------------------------------------------
// FindReferencesVisitor
// ---------------------------------------------------------------------------

FindReferencesVisitor::FindReferencesVisitor(ir::Node* target,
                                             Source::Range definition_range,
                                             int target_name_len,
                                             SourceManager* source_manager,
                                             UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                                             LspProtocol* protocol,
                                             const VirtualCallFilter& virtual_call_filter)
    : target_(target)
    , target_class_(target != null && target->is_Class() ? target->as_Class() : null)
    , definition_range_(definition_range)
    , target_name_len_(target_name_len)
    , source_manager_(source_manager)
    , ir_to_ast_map_(ir_to_ast_map)
    , protocol_(protocol)
    , virtual_call_filter_(virtual_call_filter) {}

void FindReferencesVisitor::emit_range(const Source::Range& range) {
  if (!range.is_valid()) return;
  // Skip duplicate emissions for the definition site. The compiler sometimes
  // generates ReferenceLocal nodes at the parameter definition position
  // (e.g., for typed parameter checks), which would cause a double emission
  // if not filtered out.
  if (definition_range_.is_valid() &&
      range.from() == definition_range_.from() &&
      range.to() == definition_range_.to()) {
    return;
  }
  auto from = source_manager_->compute_location(range.from());
  auto to = source_manager_->compute_location(range.to());

  int start_col = utf16_offset_in_line(from);
  int end_col = utf16_offset_in_line(to);

  // The source range may include prefix syntax that is not part of the
  // renamable identifier — e.g., "[" for block parameters, "--" for named
  // parameters, "." for dot-access, or "constructor." for named constructors.
  // Adjust the start column so the emitted range covers exactly the name.
  if (target_name_len_ > 0 &&
      from.line_number == to.line_number &&
      (end_col - start_col) > target_name_len_) {
    start_col = end_col - target_name_len_;
  }

  protocol_->find_references()->emit(from.source->absolute_path(),
                                     from.line_number - 1, start_col,
                                     to.line_number - 1, end_col);
}

void FindReferencesVisitor::visit_Reference(ir::Reference* node) {
  bool matches = (node->target() == target_);

  // When renaming a class, match references to the class's unnamed
  // constructors and factories. In the IR, constructor call sites use
  // ReferenceMethod pointing to the constructor, but the source text
  // at the call site is the class name, which needs to be renamed.
  if (!matches && target_class_ != null && node->is_ReferenceMethod()) {
    auto* method = node->as_ReferenceMethod()->target();
    if (method->holder() == target_class_ &&
        (method->is_constructor() || method->is_factory())) {
      auto holder_name = target_class_->name();
      if (method->name() == holder_name || method->name() == Symbols::constructor) {
        matches = true;
      }
    }
  }

  if (matches) {
    auto* ast_node = ir_to_ast_map_.lookup(node);
    if (ast_node != null) emit_range(ast_node->selection_range());
    else emit_range(node->range());
  }
  TraversingVisitor::visit_Reference(node);
}

void FindReferencesVisitor::visit_CallVirtual(ir::CallVirtual* node) {
  if (virtual_call_filter_.should_include(node)) {
    // For getter calls, CallVirtual::range() covers the selector name in
    // the source (e.g., "bar" in "foo.bar"), which is the range to rename.
    //
    // For setter calls, CallVirtual::range() instead covers the assignment
    // operator ("=" in "foo.bar = value"), which must not be renamed.
    // The resolver stores a mapping from setter CallVirtual nodes to the
    // AST name node that carries the field name's source range.
    auto* ast_name = ir_to_ast_map_.lookup(node);
    if (ast_name != null) {
      emit_range(ast_name->selection_range());
    } else {
      emit_range(node->range());
    }
  }
  TraversingVisitor::visit_CallVirtual(node);
}

void FindReferencesVisitor::visit_CallStatic(ir::CallStatic* node) {
  auto* method = node->target()->target();
  // When renaming a named parameter, call sites using --param_name must
  // also be updated.  Check if this call targets the method that owns
  // the rename-target parameter.
  if (target_ != null && target_->is_Parameter()) {
    auto* target_param = target_->as_Parameter();
    for (auto* p : method->parameters()) {
      if (p == target_param) {
        emit_named_argument_reference(node, target_param->name());
        break;
      }
    }
  }
  TraversingVisitor::visit_CallStatic(node);
}

void FindReferencesVisitor::emit_named_argument_reference(
    ir::Call* node, Symbol param_name) {
  // Look up the AST call expression stored during resolution.
  auto* ast_node = ir_to_ast_map_.lookup(node);
  if (ast_node == null || !ast_node->is_Call()) return;

  for (auto* arg : ast_node->as_Call()->arguments()) {
    if (!arg->is_NamedArgument()) continue;
    auto* named = arg->as_NamedArgument();
    if (named->name()->data() == param_name) {
      emit_range(named->name()->selection_range());
      break;  // Each named argument appears at most once per call.
    }
  }
}

void FindReferencesVisitor::visit_Typecheck(ir::Typecheck* node) {
  if (target_class_ != null &&
      node->type().is_class() &&
      node->type().klass() == target_class_) {
    // For IS_CHECK, AS_CHECK, and LOCAL_AS_CHECK, the resolver stores the
    // AST type node in ir_to_ast_map, giving us the exact source range
    // of the class name (e.g., "MyClass" in `x is MyClass` or `y/MyClass`).
    if (node->kind() == ir::Typecheck::IS_CHECK ||
        node->kind() == ir::Typecheck::AS_CHECK ||
        node->kind() == ir::Typecheck::LOCAL_AS_CHECK) {
      auto* ast_type = ir_to_ast_map_.lookup(node);
      if (ast_type != null) {
        emit_range(ast_type->selection_range());
      }
    }
    // For PARAMETER_AS_CHECK, RETURN_AS_CHECK, and FIELD_* checks, the
    // class name range is extracted separately in emit_all_references
    // using direct AST lookups on parameters, return types, and fields.
  }
  TraversingVisitor::visit_Typecheck(node);
}
// ---------------------------------------------------------------------------
// find_and_emit_all_references
// ---------------------------------------------------------------------------

void find_and_emit_all_references(
    ir::Node* target,
    ir::Program* program,
    SourceManager* source_manager,
    UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast,
    LspProtocol* protocol,
    ToitdocRegistry* toitdocs,
    const std::vector<Resolver::ShowExportReference>& show_export_references) {
  // When the target is a FieldStub (synthetic getter/setter), redirect to the
  // underlying Field. The user intends to rename the field, which requires
  // renaming all getter calls, setter calls, the field definition, and any
  // field-storing parameters.
  if (target->is_FieldStub()) {
    target = target->as_FieldStub()->field();
  }

  // Refuse to rename SDK symbols — their source files are not user-editable.
  if (is_sdk_target(target, source_manager)) exit(0);

  // Determine the target's name and its length for range trimming.
  const char* name = target_name(target);
  int name_len = (name != null) ? static_cast<int>(strlen(name)) : 0;

  // When the target is a field, bridge to the getter and setter FieldStubs
  // for virtual call matching. Field access like `obj.my-field` compiles to
  // a CallVirtual dispatching to the getter/setter, so VirtualCallFilter
  // must target these stubs.
  ir::FieldStub* field_getter = null;
  ir::FieldStub* field_setter = null;
  if (target->is_Field()) {
    auto* field = target->as_Field();
    if (field->holder() != null) {
      for (auto* method : field->holder()->methods()) {
        if (method->is_FieldStub()) {
          auto* stub = method->as_FieldStub();
          if (stub->field() == field) {
            if (stub->is_getter()) field_getter = stub;
            else field_setter = stub;
          }
        }
      }
    }
  }

  // Build the virtual call filter. For fields, use the getter FieldStub
  // so that `obj.field` call sites are matched.
  auto filter_target = field_getter != null
      ? static_cast<ir::Node*>(field_getter) : target;
  auto virtual_call_filter = VirtualCallFilter::build(
      filter_target, program, source_manager);

  // For field targets, also register the setter so that assignment sites
  // (e.g., `obj.field = value`) are matched by the filter.
  if (field_setter != null) {
    virtual_call_filter.set_setter(field_setter);
  }

  // Create the visitor for expression-level reference finding.
  // The definition range is passed so the visitor can skip compiler-generated
  // references that coincide with the definition site.
  Source::Range definition_range = target_range(target);

  // For named constructors and factories, ir::Method::range() covers only the
  // "constructor" keyword (set from ast::Method::selection_range() during
  // resolution). The actual name (e.g., "my-named-ctor" in
  // "constructor.my-named-ctor") lives in the ast::Dot node's name()
  // Identifier. Use its range instead.
  if (target->is_Method()) {
    auto* method = target->as_Method();
    if ((method->is_constructor() || method->is_factory()) &&
        method->holder() != null) {
      auto* ast_node = ir_to_ast.lookup(target);
      if (ast_node != null && ast_node->is_Method()) {
        auto* name_or_dot = ast_node->as_Method()->name_or_dot();
        if (name_or_dot != null && name_or_dot->is_Dot()) {
          definition_range = name_or_dot->as_Dot()->name()->selection_range();
        }
      }
    }
  }

  FindReferencesVisitor visitor(
      target, definition_range, name_len, source_manager, ir_to_ast,
      protocol, virtual_call_filter);

  // Emit the definition's own location.
  if (definition_range.is_valid()) {
    auto from = source_manager->compute_location(definition_range.from());
    auto to = source_manager->compute_location(definition_range.to());

    int start_col = utf16_offset_in_line(from);
    int end_col = utf16_offset_in_line(to);

    // Trim prefix syntax from the definition range, same as for reference
    // ranges — e.g., "[block-param]" → "block-param".
    if (name_len > 0 &&
        from.line_number == to.line_number &&
        (end_col - start_col) > name_len) {
      start_col = end_col - name_len;
    }

    protocol->find_references()->emit(
        from.source->absolute_path(),
        from.line_number - 1, start_col,
        to.line_number - 1, end_col);
  }

  // --- Override/implementation definitions ---
  // When renaming a virtual method (or field), all definitions sharing the
  // same name and shape in the participating class hierarchy must be renamed
  // together to avoid breaking the program.
  if (virtual_call_filter.is_active()) {
    auto* filter_method = virtual_call_filter.method();
    auto filter_shape = filter_method->resolution_shape().to_plain_shape()
                            .to_equivalent_call_shape();
    for (auto* klass : virtual_call_filter.participating_classes().underlying_set()) {
      for (auto* method : klass->methods()) {
        if (method == target || method == field_getter || method == field_setter) continue;
        bool shape_matches = method->resolution_shape().accepts(filter_shape);
        if (!shape_matches && field_setter != null) {
          auto setter_shape = field_setter->resolution_shape().to_plain_shape()
                                  .to_equivalent_call_shape();
          shape_matches = method->resolution_shape().accepts(setter_shape);
        }
        if (method->name() == filter_method->name() && shape_matches) {
          // For FieldStub overrides, emit the field's own range (the field
          // definition name), not the synthetic getter/setter range.
          if (method->is_FieldStub()) {
            visitor.emit_range(method->as_FieldStub()->field()->range());
          } else {
            visitor.emit_range(method->range());
          }
        }
      }
    }
  }

  // --- Class-specific reference scanning ---
  // When renaming a class, we must find all places the class name appears:
  // extends/implements/with clauses, type annotations on parameters/return
  // types/fields, constructor calls (handled by the visitor), and is/as
  // checks (handled by the visitor).
  if (target->is_Class()) {
    auto* target_class = target->as_Class();

    // Hierarchy references: extends, implements, with clauses.
    for (auto* klass : program->classes()) {
      auto* ast_node = ir_to_ast.lookup(klass);
      if (ast_node == null || !ast_node->is_Class()) continue;
      auto* ast_class = ast_node->as_Class();

      if (klass->has_super() && klass->super() == target_class) {
        if (ast_class->super() != null) {
          visitor.emit_range(ast_class->super()->selection_range());
        }
      }

      auto ir_interfaces = klass->interfaces();
      auto ast_interfaces = ast_class->interfaces();
      for (int i = 0; i < ir_interfaces.length() && i < ast_interfaces.length(); i++) {
        if (ir_interfaces[i] == target_class) {
          visitor.emit_range(ast_interfaces[i]->selection_range());
        }
      }

      auto ir_mixins = klass->mixins();
      auto ast_mixins = ast_class->mixins();
      for (int i = 0; i < ir_mixins.length() && i < ast_mixins.length(); i++) {
        if (ir_mixins[i] == target_class) {
          visitor.emit_range(ast_mixins[i]->selection_range());
        }
      }
    }

    // Type annotations: scan parameter types, return types, and field types
    // across every method and class in the program.
    auto scan_method_types = [&](ir::Method* method) {
      for (auto* param : method->parameters()) {
        if (param->type().is_class() && param->type().klass() == target_class) {
          auto* ast_param = ir_to_ast.lookup(param);
          if (ast_param != null && ast_param->is_Parameter()) {
            auto* ast_type = ast_param->as_Parameter()->type();
            if (ast_type != null) visitor.emit_range(ast_type->selection_range());
          }
        }
      }
      if (method->return_type().is_class() &&
          method->return_type().klass() == target_class) {
        auto* ast_method = ir_to_ast.lookup(method);
        if (ast_method != null && ast_method->is_Method()) {
          auto* ast_ret = ast_method->as_Method()->return_type();
          if (ast_ret != null) visitor.emit_range(ast_ret->selection_range());
        }
      }
    };

    for (auto* klass : program->classes()) {
      for (auto* method : klass->methods()) scan_method_types(method);
      for (auto* ctor : klass->unnamed_constructors()) scan_method_types(ctor);
      for (auto* factory : klass->factories()) scan_method_types(factory);
      // Statics (named constructors, static methods, static fields).
      if (klass->statics() != null) {
        for (auto* method : klass->statics()->nodes()) {
          scan_method_types(method);
        }
      }

      for (auto* field : klass->fields()) {
        if (field->type().is_class() && field->type().klass() == target_class) {
          auto* ast_field = ir_to_ast.lookup(field);
          if (ast_field != null && ast_field->is_Field()) {
            auto* ast_type = ast_field->as_Field()->type();
            if (ast_type != null) visitor.emit_range(ast_type->selection_range());
          }
        }
      }
    }
    // Global functions and global variables.
    for (auto* method : program->methods()) scan_method_types(method);
    for (auto* global : program->globals()) scan_method_types(global);
  }

  // --- Field-specific reference scanning ---
  if (target->is_Field()) {
    auto* target_field = target->as_Field();
    if (target_field->holder() != null) {
      // Find field-storing parameters in constructors and factories.
      // A field-storing parameter (e.g., `--my-field`) shares its name with
      // the field and must be renamed when the field is renamed.
      auto check_method_for_field_storing = [&](ir::Method* method) {
        for (auto* param : method->parameters()) {
          if (param->name() == target_field->name()) {
            auto* ast_param = ir_to_ast.lookup(param);
            if (ast_param != null && ast_param->is_Parameter() &&
                ast_param->as_Parameter()->is_field_storing()) {
              visitor.emit_range(ast_param->selection_range());
            }
          }
        }
      };
      for (auto* ctor : target_field->holder()->unnamed_constructors()) {
        check_method_for_field_storing(ctor);
      }
      for (auto* factory : target_field->holder()->factories()) {
        check_method_for_field_storing(factory);
      }
      // Named constructors are in statics.
      if (target_field->holder()->statics() != null) {
        for (auto* method : target_field->holder()->statics()->nodes()) {
          if (method->is_constructor() || method->is_factory()) {
            check_method_for_field_storing(method);
          }
        }
      }
    }
  }

  // --- Show/export clause references ---
  // When a symbol appears in an import's `show` clause or an `export`
  // directive, the clause text must be updated when the symbol is renamed.
  for (const auto& ref : show_export_references) {
    if (unwrap_reference(ref.target) == target) {
      visitor.emit_range(ref.range);
    }
  }

  // --- Toitdoc reference scanning ---
  // When a toitdoc comment references the target via `$symbol`, that
  // reference must be updated when the target is renamed.
  toitdocs->for_each([&](void* key, Toitdoc<ir::Node*> ir_toitdoc) {
    if (!ir_toitdoc.is_valid()) return;
    auto ir_refs = ir_toitdoc.refs();

    // Check if any ref in this toitdoc points to the target.
    bool has_matching_ref = false;
    for (int i = 0; i < ir_refs.length(); i++) {
      auto* ref_target = ir_refs[i];
      if (ref_target == null) continue;
      // FieldStub → Field redirect (matching the FieldStub unwrapping above).
      if (ref_target->is_FieldStub()) ref_target = ref_target->as_FieldStub()->field();
      if (ref_target == target) {
        has_matching_ref = true;
        break;
      }
    }
    if (!has_matching_ref) return;

    // Look up the AST node to get source ranges for the toitdoc refs.
    auto* ir_node = static_cast<ir::Node*>(key);
    auto probe = ir_to_ast.find(ir_node);
    if (probe == ir_to_ast.end()) return;
    auto* ast_node = probe->second;

    // Get the AST toitdoc from the declaration.
    Toitdoc<ast::Node*> ast_toitdoc = Toitdoc<ast::Node*>::invalid();
    if (ast_node->is_Class()) {
      ast_toitdoc = ast_node->as_Class()->toitdoc();
    } else if (ast_node->is_Method()) {
      ast_toitdoc = ast_node->as_Method()->toitdoc();
    } else if (ast_node->is_Field()) {
      ast_toitdoc = ast_node->as_Field()->toitdoc();
    }
    if (!ast_toitdoc.is_valid()) return;

    auto ast_refs = ast_toitdoc.refs();
    ASSERT(ast_refs.length() == ir_refs.length());

    for (int i = 0; i < ir_refs.length(); i++) {
      auto* ref_target = ir_refs[i];
      if (ref_target == null) continue;
      if (ref_target->is_FieldStub()) ref_target = ref_target->as_FieldStub()->field();
      if (ref_target != target) continue;

      auto* ast_ref_node = ast_refs[i];
      if (!ast_ref_node->is_ToitdocReference()) continue;
      auto* toitdoc_ref = ast_ref_node->as_ToitdocReference();

      auto* ref_target_expr = toitdoc_ref->target();
      if (ref_target_expr == null) continue;

      // For Dot expressions (e.g., `$Class.method`), emit only the part
      // that corresponds to the rename target.
      if (ref_target_expr->is_Dot()) {
        auto* dot = ref_target_expr->as_Dot();
        // The resolver resolves `$Class.method` to the method, not the class.
        // So a matching ref means we're renaming the method → emit the name part.
        visitor.emit_range(dot->name()->selection_range());
      } else {
        visitor.emit_range(ref_target_expr->selection_range());
      }
    }
  });

  // --- Expression-level references ---
  // The visitor traverses all IR expression trees to find:
  // - Static references (ReferenceMethod, ReferenceLocal, ReferenceGlobal)
  // - Constructor calls for class targets (ReferenceMethod → holder class)
  // - Virtual call sites (CallVirtual matching VirtualCallFilter)
  // - IS/AS/local type checks for class targets (Typecheck nodes)
  visitor.visit(program);
  exit(0);
}
} // namespace toit::compiler
} // namespace toit
