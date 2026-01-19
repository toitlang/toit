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

#include "resolver.h"

#include <algorithm>
#include <stdarg.h>

#include "cycle_detector.h"
#include "deprecation.h"
#include "diagnostic.h"
#include "lsp/lsp.h"
#include "map.h"
#include "token.h"
#include "tree_roots.h"
#include "resolver_method.h"
#include "resolver_scope.h"
#include "resolver_toitdoc.h"
#include "util.h"

#include "../entry_points.h"
#include "../utils.h"


namespace toit {
namespace compiler {

void Resolver::report_error(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(position_node->selection_range(), format, arguments);
  va_end(arguments);
}

void Resolver::report_error(ir::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(ir_to_ast_map_.at(position_node)->selection_range(), format, arguments);
  va_end(arguments);
}

void Resolver::report_note(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_note(position_node->selection_range(), format, arguments);
  va_end(arguments);
}

void Resolver::report_note(ir::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_note(ir_to_ast_map_.at(position_node)->selection_range(), format, arguments);
  va_end(arguments);
}

void Resolver::report_error(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(format, arguments);
  va_end(arguments);
}

void Resolver::report_warning(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_warning(position_node->selection_range(), format, arguments);
  va_end(arguments);
}

void Resolver::report_warning(ir::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_warning(ir_to_ast_map_.at(position_node)->selection_range(), format, arguments);
  va_end(arguments);
}

// Forward declaration.
static ir::Method* resolve_entry_point(Symbol name, int arity, ModuleScope* scope);

ir::Program* Resolver::resolve(const std::vector<ast::Unit*>& units,
                               int entry_index,
                               int core_index) {
  auto modules = build_modules(units, entry_index, core_index);
  build_module_scopes(modules);

  mark_runtime(modules[core_index]);
  mark_non_returning(modules[core_index]);

  setup_inheritance(modules, core_index);

  fill_classes_with_skeletons(modules);

  check_clashing_or_conflicting(modules);

  check_future_reserved_globals(modules);

  // Mixins must be flattened before we report abstract classes
  // and check the interface implementations.
  flatten_mixins(modules);
  report_abstract_classes(modules);
  check_interface_implementations_and_flatten(modules);

  auto entry_module = modules[entry_index];
  auto core_module = modules[core_index];
  // We want to run through the entry_module first.
  for (int i = -1; i < static_cast<int>(modules.size()); i++) {
    if (i == entry_index) continue;
    Module* module = i == -1 ? entry_module : modules[i];
    resolve_fill_module(module, entry_module, core_module);
    if (lsp_ != null && lsp_->should_emit_semantic_tokens()) {
      ASSERT(module == entry_module);
      // Immediately print the tokens.
      // The function should exit, thus aborting the remaining resolutions.
      lsp_->emit_semantic_tokens(module,
                                 entry_module->unit()->absolute_path(),
                                 source_manager_);
      UNREACHABLE();
    }
  }

  if (lsp_ != null && lsp_->needs_summary()) {
    lsp_->emit_summary(modules, core_index, toitdocs_);
  }

  // Run through the modules again, and report deprecation warnings for imports.
  // We can't do this together with the other deprecation warnings, as we are
  // losing import information.
  for (int i = -1; i < static_cast<int>(modules.size()); i++) {
    if (i == entry_index) continue;
    Module* module = i == -1 ? entry_module : modules[i];
    for (auto imported : module->imported_modules()) {
      if (imported.module->is_deprecated()) {
        Symbol deprecation_message = imported.module->get_deprecation_message();
        auto import_node = imported.import;
        if (import_node) {
          auto range = import_node->selection_range().extend(import_node->segments().last()->selection_range());
          diagnostics()->report_warning(range, "Importing deprecated library%s", deprecation_message.c_str());
        }
      }
    }
  }

  add_global_assignment_typechecks();

  ListBuilder<ir::Class*> all_classes;
  ListBuilder<ir::Method*> all_methods;
  ListBuilder<ir::Global*> all_globals;
  // Move factories, constructors and statics to the program level instead of
  // keeping them in the classes.
  for (auto module : modules) {
    all_classes.add(module->classes());
    all_methods.add(module->methods());
    for (auto klass : module->classes()) {
      all_methods.add(klass->unnamed_constructors());
      all_methods.add(klass->factories());
      for (auto node : klass->statics()->nodes()) {
        if (node->is_Global()) {
          all_globals.add(node->as_Global());
        } else {
          all_methods.add(node->as_Method());
        }
      }
    }
    all_globals.add(module->globals());
  }

  auto tree_roots = find_tree_roots(modules[core_index]);
  auto entry_points = find_entry_points(modules[core_index]);
  auto literal_types = find_literal_types(modules[core_index]);

  ir::Method* lookup_failure = null;
  for (auto method : entry_points) {
    if (method->name() == Symbols::lookup_failure) {
      lookup_failure = method;
      break;
    }
  }
  ASSERT(lookup_failure != null);

  auto as_check_failure_entry = modules[core_index]->scope()->lookup(Symbols::as_check_failure_).entry;
  ASSERT(as_check_failure_entry.is_single());
  auto as_check_failure = as_check_failure_entry.single()->as_Method();
  ASSERT(as_check_failure != null);

  auto lambda_box = core_module->scope()->lookup(Symbols::Box_).entry.klass();

  auto program = _new ir::Program(all_classes.build(),
                                  all_methods.build(),
                                  all_globals.build(),
                                  tree_roots,
                                  entry_points,
                                  literal_types,
                                  lookup_failure,
                                  as_check_failure,
                                  lambda_box);

  return program;
}

std::vector<Module*> Resolver::build_modules(const std::vector<ast::Unit*>& units,
                                             int entry_unit_index,
                                             int core_unit_index) {
  UnorderedMap<ast::Unit*, Module*> translated_units;

  std::vector<Module*> modules;
  for (const auto& unit : units) {
    ListBuilder<ir::Class*> classes;
    ListBuilder<ir::Method*> methods;
    ListBuilder<ir::Global*> globals;
    List<ast::Node*> declarations = unit->declarations();
    for (auto declaration : declarations) {
      if (auto method = declaration->as_Method()) {
        Symbol name = Symbol::invalid();
        ir::Method::MethodKind kind;
        // For top-level methods we don't weed out future-reserved identifiers
        // at this stage. We are not allowed to give warnings for identifiers that
        // come from the core libraries, and we don't (easily) know yet whether the
        // current method is part of the core libraries.
        bool allow_future_reserved = true;
        check_method(method, null, &name, &kind, allow_future_reserved);
        ASSERT(kind == ir::Method::GLOBAL_FUN);
        auto shape = ResolutionShape::for_static_method(method);
        ir::Method* ir = _new ir::MethodStatic(name,
                                               null,
                                               shape,
                                               kind,
                                               method->selection_range(),
                                               method->outline_range());
        ir_to_ast_map_[ir] = method;
        methods.add(ir);
      } else if (auto global = declaration->as_Field()) {
        check_field(global, null);
        auto ir = _new ir::Global(global->name()->data(),
                                  global->is_final(),
                                  global->selection_range(),
                                  global->outline_range());
        ir_to_ast_map_[ir] = global;
        globals.add(ir);
      } else if (auto klass = declaration->as_Class()) {
        check_class(klass);
        Symbol name = klass->name()->data();
        auto position = klass->selection_range();
        ir::Class::Kind kind = ir::Class::CLASS;  // Initialized with value to silence compiler warnings.
        switch (klass->kind()) {
          case ast::Class::CLASS: kind = ir::Class::CLASS; break;
          case ast::Class::INTERFACE: kind = ir::Class::INTERFACE; break;
          case ast::Class::MONITOR: kind = ir::Class::MONITOR; break;
          case ast::Class::MIXIN: kind = ir::Class::MIXIN; break;
        }
        bool is_abstract = kind == ir::Class::INTERFACE || klass->has_abstract_modifier();
        ir::Class* ir = _new ir::Class(name, kind, is_abstract, position, klass->outline_range());
        ir_to_ast_map_[ir] = klass;
        classes.add(ir);
      } else {
        UNREACHABLE();
      }
    }
    Set<Symbol> exported_identifiers;
    bool export_all = false;
    for (auto ast_export : unit->exports()) {
      if (ast_export->export_all()) {
        // We continue iterating, so we can check that all export identifiers
        // are actually found.
        export_all = true;
      }
      for (auto ast_identifier : ast_export->identifiers()) {
        exported_identifiers.insert(ast_identifier->data());
      }
    }
    auto module = _new Module(unit,
                              classes.build(),
                              methods.build(),
                              globals.build(),
                              export_all,
                              exported_identifiers);
    translated_units[unit] = module;
    modules.push_back(module);
  }

  UnorderedSet<Module*> finished_modules;

  Module* core_module = modules[core_unit_index];
  ast::Unit* core_unit = units[core_unit_index];

  // We go from the back to the front, since the units were discovered in a
  // DFS traversal. By going from the back to the front we make it more likely
  // that dependent modules have already been processed.
  for (int i = modules.size() - 1; i >= 0; i--) {
    auto unit = units[i];
    auto module = modules[i];

    ListBuilder<Module::PrefixedModule> imported_modules_builder;

    if (unit != core_unit) {
      // Every module automatically imports the core module.
      imported_modules_builder.add({
        .prefix = null,
        .module = core_module,
        .show_identifiers = List<ast::Identifier*>(),
        .import = null,
        .is_explicitly_imported = false,
      });
    }

    for (auto import : unit->imports()) {
      ast::Identifier* prefix;
      if (import->prefix() != null) {
        prefix = import->prefix();
      } else if (!import->show_identifiers().is_empty() || import->show_all()) {
        prefix = null;
      } else if (import->is_relative()) {
        prefix = null;
      } else {
        prefix = import->segments().last();
      }

      imported_modules_builder.add({
        .prefix = prefix,
        .module = translated_units.at(import->unit()),
        .show_identifiers = import->show_identifiers(),
        .import = import,
        .is_explicitly_imported = true,
      });
    }

    auto imported_modules = imported_modules_builder.build();
    // Sort the prefixed modules so that modules without prefix come first.
    std::stable_sort(imported_modules.begin(), imported_modules.end(),
              [](const Module::PrefixedModule& a, const Module::PrefixedModule& b) {
      if (a.prefix == null) return b.prefix != null;
      return false;
    });

    module->set_imported_modules(imported_modules);
  }
  return modules;
}

// Returns the method that appears earliest in the code.
// Assumes that all methods are in the same file, but is still
// deterministic if they aren't.
static ir::Method* find_earliest(const std::vector<ir::Method*>& methods) {
  Source::Range earliest_range = Source::Range::invalid();
  ir::Method* earliest_method = null;
  for (auto method : methods) {
    if (!earliest_range.is_valid() || method->range().is_before(earliest_range)) {
      earliest_range = method->range();
      earliest_method = method;
    }
  }
  return earliest_method;
}

// Sorts the given vector in place by location.
// Assumes that all methods are in the same file, but is still
// deterministic if they aren't.
static void sort_in_place(std::vector<ir::Method*>& methods) {
  std::sort(methods.begin(), methods.end(),
            [](const ir::Method* a, const ir::Method* b) {
    return a->range().is_before(b->range());
  });
}

/// Checks whether entries are consistent.
///
/// Ensures that:
/// - there aren't multiple conflicting entries of the same name.
///   * method overloads must be distinct.
///   * a name must be only of one type (no `class A` and function `A`).
///
/// Fields must be declared as [FieldStub].
void Resolver::check_clashing_or_conflicting(Symbol name, List<ir::Node*> declarations) {
  if (!name.is_valid()) return;
  if (declarations.length() <= 1) return;
  // Don't report any errors for '_'. We would have a different error anyway.
  if (name == Symbols::_) return;

  int classes_count = 0, methods_count = 0, globals_count = 0;
  for (const auto& declaration : declarations) {
    if (declaration->is_Class()) classes_count++;
    else if (declaration->is_Method()) methods_count++;
    else if (declaration->is_Global()) globals_count++;
  }
  if (classes_count == 0 && globals_count == 0) {
    // Verify no overlap between method signatures and fields (if they exist).
    // We only do this if there aren't any classes or globals, since we would have
    // conflicting declarations otherwise anyway (leading to an error).
    ASSERT(methods_count > 0);
    std::vector<ir::Method*> methods_with_optional_params;
    Map<Selector<ResolutionShape>, std::vector<ir::Method*>> declarations_per_selector;
    for (auto declaration : declarations) {
      ASSERT(declaration->is_Method());
      ir::Method* method = declaration->as_Method();
      // Ignore abstract methods. They are allowed to overlap.
      if (method->is_abstract()) continue;
      // For the purpose of conflict resolution we don't include implicit
      // this arguments.
      auto shape = method->resolution_shape_no_this();
      if (shape.has_optional_parameters()) {
        methods_with_optional_params.push_back(method);
      } else {
        Selector<ResolutionShape> selector(method->name(), shape);
        declarations_per_selector[selector].push_back(method);
      }
    }

    for (auto key : declarations_per_selector.keys()) {
      auto declarations = declarations_per_selector[key];
      if (declarations.size() != 1) {
        // If we have duplicate fields we don't want to report setter and getter
        // conflicts. However, we want to have different error messages, when
        // there is an independent getter/setter that clashes:
        //
        //  f := 1
        //  f
        //    return "getter"
        //  f= x
        //    return "setter"
        bool all_are_setters = true;
        for (auto node : declarations) {
          if (node->is_FieldStub() && !node->as_FieldStub()->is_getter()) continue;
          all_are_setters = false;
          break;
        }
        if (all_are_setters) continue;  // We report the clashes with the getters.

        ir::Method* earliest_method = find_earliest(declarations);
        for (auto declaration : declarations) {
          if (declaration == earliest_method) continue;
          diagnostics()->start_group();
          report_error(declaration, "Redefinition of '%s'", name.c_str());
          report_note(earliest_method, "First definition of '%s'", name.c_str());
          diagnostics()->end_group();
        }
      }
    }

    // Sort by location in the source.
    sort_in_place(methods_with_optional_params);

    for (size_t i = 0; i < methods_with_optional_params.size(); i++) {
      auto method = methods_with_optional_params[i];
      // For the purpose of conflict resolution we don't include implicit
      // this arguments.
      auto shape = method->resolution_shape_no_this();
      std::vector<ir::Method*> overlapping;
      // Unfortunately in O(n^2).
      for (size_t j = i + 1; j < methods_with_optional_params.size(); j++) {
        auto other_method = methods_with_optional_params[j];
        // For the purpose of conflict resolution we don't include implicit
        // this arguments.
        auto other_shape = other_method->resolution_shape_no_this();
        if (shape.overlaps_with(other_shape)) {
          overlapping.push_back(other_method);
        }
      }
      // We assume that most functions don't have optional parameters and we
      // just run through all declarations.
      for (auto other : declarations) {
        auto other_method = other->as_Method();
        auto other_shape = other_method->resolution_shape_no_this();
        if (other_shape.has_optional_parameters()) continue;
        if (shape.overlaps_with(other_shape)) {
          overlapping.push_back(other_method);
        }
      }
      if (!overlapping.empty()) {
        sort_in_place(overlapping);

        auto class_name = Symbol::invalid();
        if (method->holder() != null && method->holder()->name().is_valid()) {
          class_name = method->holder()->name();
        }
        diagnostics()->start_group();
        if (method->is_constructor() || method->is_factory()) {
          if (name != Symbols::constructor) {
            // Assume it's not a named constructor, and not the erroneous
            // `constructor.constructor`.
            report_error(method, "Constructor '%s' with overlapping signature", name.c_str());
          } else if (class_name.is_valid()) {
            report_error(method,
                         "Constructor of class '%s' with overlapping signature",
                         class_name.c_str());
          } else {
            report_error(method, "Constructor of with overlapping signature");
          }
        } else {
          ASSERT(!method->is_FieldStub());  // Field stubs don't have optional args.
          const char* method_or_fun = "Function";
          if (method->holder() != null) method_or_fun = "Method";
          report_error(method, "%s '%s' with overlapping signature", method_or_fun, name.c_str());
        }
        for (const auto& other : overlapping) {
          if (other->is_constructor() || other->is_factory()) {
            if (name != Symbols::constructor) {
              // Assume it's not a named constructor, and not the erroneous
              // `constructor.constructor`.
              report_note(other, "Overlaps with constructor '%s'", name.c_str());
            } else {
              report_note(other, "Overlapping constructor");
            }
          } else if (other->is_FieldStub()) {
            report_note(other, "Overlaps with field '%s'", name.c_str());
          } else if (other->is_initializer()) {
            const char* static_or_global = "global";
            if (other->holder() != null) static_or_global = "static field";
            report_note(other, "Overlaps with %s '%s'", static_or_global, name.c_str());
          } else {
            const char* method_or_fun = "function";
            if (other->holder() != null) method_or_fun = "method";
            report_note(other, "Overlaps with %s '%s'", method_or_fun, name.c_str());
          }
        }
        diagnostics()->end_group();
      }
    }
  } else if (classes_count + globals_count + methods_count != 1) {
    bool is_conflicting = true;
    if ((globals_count == 0 && methods_count == 0) ||
        (classes_count == 0 && methods_count == 0)) {
      is_conflicting = false;
    }
    ir::Node* earliest_node = null;
    Source::Range earliest_range = Source::Range::invalid();
    std::vector<ir::Class*> classes;
    std::vector<ir::Global*> globals;
    std::vector<ir::Method*> methods;
    for (const auto& declaration : declarations) {
      auto ast_node = ir_to_ast_map_.at(declaration);
      if (!earliest_range.is_valid() || ast_node->selection_range().is_before(earliest_range)) {
        earliest_range = ast_node->selection_range();
        earliest_node = declaration;
      }
      if (declaration->is_Class()) classes.push_back(declaration->as_Class());
      else if (declaration->is_Global()) globals.push_back(declaration->as_Global());
      else if (declaration->is_Method()) methods.push_back(declaration->as_Method());
    }
    // Just prints all of them, except the first one.
    if (!classes.empty()) {
      const char* error_string = is_conflicting ? "Redefinition of '%s' as class" : "Redefinition of '%s'";
      for (const auto& klass : classes) {
        if (klass == earliest_node) continue;
        diagnostics()->start_group();
        report_error(klass, error_string, name);
        report_note(earliest_node, "First definition of '%s'", name);
        diagnostics()->end_group();
      }
    }
    if (!globals.empty()) {
      const char* error_string = is_conflicting ? "Redefinition of '%s' as global" : "Redefinition of '%s'";
      for (const auto& global : globals) {
        if (global == earliest_node) continue;
        diagnostics()->start_group();
        report_error(global, error_string, name);
        report_note(earliest_node, "First definition of '%s'", name);
        diagnostics()->end_group();
      }
    }
    if (!methods.empty()) {
      const char* error_string = is_conflicting ? "Redefinition of '%s' as method" : "Redefinition of '%s'";
      for (const auto& method : methods) {
        if (method == earliest_node) continue;
        diagnostics()->start_group();
        report_error(method, error_string, name);
        report_note(earliest_node, "First definition of '%s'", name);
        diagnostics()->end_group();
      }
    }
  }
}

void Resolver::check_clashing_or_conflicting(std::vector<Module*> modules) {
  for (auto module : modules) {
    // Check the top-level entries first.
    auto module_entries = module->scope()->entries();
    for (auto key : module_entries.keys()) {
      auto resolution_entry = module_entries[key];
      if (resolution_entry.kind() != ResolutionEntry::NODES) continue;
      check_clashing_or_conflicting(key, resolution_entry.nodes());
    }

    for (auto klass : module->classes()) {
      auto constructors = klass->unnamed_constructors();
      auto factories = klass->factories();
      auto unnamed_factories_and_constructors =
          ListBuilder<ir::Node*>::allocate(constructors.length() + factories.length());
      int index = 0;
      for (auto constructor : constructors) unnamed_factories_and_constructors[index++] = constructor;
      for (auto factory : factories) unnamed_factories_and_constructors[index++] = factory;
      check_clashing_or_conflicting(Symbols::constructor, unnamed_factories_and_constructors);

      Map<Symbol, std::vector<ir::Node*>> member_declarations;
      for (auto method : klass->methods()) {
        auto name = method->name();
        member_declarations[name].push_back(method);
      }
      // Add statics to the scope of the class.
      // We also add named constructors/factories, even though they can only be accessed
      //   through a class-prefix.
      for (auto node : klass->statics()->nodes()) {
        member_declarations[node->name()].push_back(node);
      }
      for (auto name : member_declarations.keys()) {
        auto& vector = member_declarations[name];
        auto list = ListBuilder<ir::Node*>::build_from_vector(vector);
        check_clashing_or_conflicting(name, list);
      }
    }
  }
}

void Resolver::check_future_reserved_globals(std::vector<Module*> modules) {
  // We have checked already all identifiers except for globals. This is,
  // because we didn't know yet which methods were from the core libraries.
  // This information is present now.
  for (auto module : modules) {
    for (auto method : module->methods()) {
      if (method->is_runtime_method()) continue;
      auto name = method->name();
      if (Symbols::is_future_reserved(name)) {
        auto ast_name = ir_to_ast_map_.at(method)->as_Method()->name_or_dot();
        report_warning(ast_name,
                       "Name '%s' will be reserved in future releases",
                       name.c_str());
      }
    }
  }
}

// Finds the error-reporting node for the given name.
static ast::Node* find_export_node(Module* module, Symbol name) {
  ast::Node* result = null;
  for (auto ast_export : module->unit()->exports()) {
    if (ast_export->export_all()) {
      // Don't return yet. Maybe we find a better export.
      result = ast_export;
    }
    for (auto identifier : ast_export->identifiers()) {
      if (identifier->data() == name) return identifier;
    }
  }
  if (result == null) FATAL("Couldn't find exported identifier");
  return result;
}

// Finds the error-reporting node for the given name.
static ast::Identifier* find_show_node(Module::PrefixedModule& prefixed_module, Symbol name) {
  ast::Identifier* result = null;
  for (auto ast_identifier : prefixed_module.show_identifiers) {
    if (ast_identifier->data() == name) {
      result = ast_identifier;
      break;
    }
  }
  if (result == null) FATAL("Couldn't find show node");
  return result;
}

static void report_unresolved_show(Module::PrefixedModule& prefixed_module,
                                   Symbol name,
                                   UnorderedSet<ast::Identifier*>* already_reported_shows,
                                   Diagnostics* diagnostics) {
  auto ast_identifier = find_show_node(prefixed_module, name);
  if (already_reported_shows->contains(ast_identifier)) return;
  already_reported_shows->insert(ast_identifier);
  diagnostics->report_error(ast_identifier, "Unresolved show '%s'", name.c_str());
}

static void report_cyclic_export(std::vector<Module*> cyclic_modules,
                                 Symbol name,
                                 UnorderedSet<Module*>* already_reported_modules,
                                 Diagnostics* diagnostics) {
  bool already_reported = true;
  for (auto cyclic_module : cyclic_modules) {
    if (!already_reported_modules->contains(cyclic_module)) {
      already_reported = false;
      already_reported_modules->insert(cyclic_module);
    }
  }
  if (already_reported) return;

  Symbol error_lookup_name = name.is_valid() ? name : Symbol::synthetic("<export *>");
  // Since cyclic export dependencies work over different files, report the same error
  // for each file.
  // Otherwise editors would only show the error in one of the files.
  for (auto current_module : cyclic_modules) {
    diagnostics->start_group();
    auto error_node = find_export_node(current_module, error_lookup_name);
    diagnostics->report_error(error_node, "Cyclic export dependency");
    for (auto cyclic : cyclic_modules) {
      if (cyclic == current_module) continue;
      auto error_node = find_export_node(cyclic, name);
      diagnostics->report_note(error_node, "This clause contributes to the 'export' cycle");
    }
    diagnostics->end_group();
  }
}

/// For every module resolve the shown identifiers and add it to the dictionaries.
/// For every export resolve it and check that there aren't any issues.
void Resolver::resolve_shows_and_exports(std::vector<Module*>& modules) {
  bool is_lsp_show = true;
  ast::Identifier* lsp_node = null;
  Symbol lsp_name = Symbol::invalid();
  Module* lsp_module = null;
  ResolutionEntry lsp_resolution_entry;
  ModuleScope* lsp_scope = null;

  // First build up a map for each module, where we map show-imports to their corresponding
  // prefixed-module.
  Map<Module*, Map<Symbol, Module::PrefixedModule>> show_map;
  for (auto module : modules) {
    auto& identifier_map = show_map[module];
    for (auto imported_module : module->imported_modules()) {
      // The imported modules are sorted so that the ones without prefix are in front.
      // We can stop as soon as there is one that has a prefix.
      if (imported_module.prefix != null) break;
      if (imported_module.show_identifiers.is_empty()) continue;
      for (auto ast_identifier : imported_module.show_identifiers) {
        auto name = ast_identifier->data();

        if (ast_identifier->is_LspSelection()) {
          // Remember which "show" identifier was the LSP-selection.
          lsp_node = ast_identifier;
          lsp_name = name;
          lsp_module = module;
          is_lsp_show = true;
        }

        auto identifier_probe = identifier_map.find(name);
        if (identifier_probe != identifier_map.end() &&
            identifier_probe->second.module != imported_module.module) {
          for (auto other_ast_identifier : identifier_probe->second.show_identifiers) {
            if (other_ast_identifier->data() == ast_identifier->data()) {
              auto earlier = ast_identifier->selection_range().is_before(other_ast_identifier->selection_range())
                ? ast_identifier
                : other_ast_identifier;
              auto later = ast_identifier == earlier ? other_ast_identifier : ast_identifier;
              diagnostics()->start_group();
              report_error(later, "Ambiguous 'show' import for '%s'", name.c_str());
              report_note(earlier, "First show of identifier '%s'", name.c_str());
              diagnostics()->end_group();
            }
          }
          continue;
        }
        identifier_map[name] = imported_module;
        // Also check whether this identifier is a prefix or toplevel in this module.
        auto entry = module->scope()->lookup_module(name);
        if (!entry.is_empty()) {
          auto other = ir_to_ast_map_[entry.nodes()[0]];
          diagnostics()->start_group();
          report_error(ast_identifier, "Name clash with toplevel declaration '%s'", name.c_str());
          report_note(other, "Toplevel declaration of '%s'", name.c_str());
          diagnostics()->end_group();
          continue;
        }
        auto prefix_entry = module->scope()->non_prefixed_imported()->lookup_prefix_and_explicit(name);
        // Since we haven't added any explicit entries (i.e. the shows) yet, we can only
        // find prefixes here.
        ASSERT(prefix_entry.is_empty() || prefix_entry.is_prefix());
        if (prefix_entry.is_prefix()) {
          diagnostics()->start_group();
          report_error(ast_identifier, "Name clash with prefix '%s'", name.c_str());
          auto ast_unit = module->unit();
          for (auto import : ast_unit->imports()) {
            if (import->prefix() != null && import->prefix()->data() == name) {
              report_error(import->prefix(), "Definition of prefix '%s'", name.c_str());
            }
          }
          diagnostics()->end_group();
          continue;
        }
      }
    }
    if (lsp_ != null) {
      // Run through the export nodes to find any LSP selection.
      for (auto ast_export : module->unit()->exports()) {
        for (auto ast_identifier : ast_export->identifiers()) {
          if (ast_identifier->is_LspSelection()) {
            lsp_node = ast_identifier;
            lsp_name = ast_identifier->data();
            lsp_module = module;
            is_lsp_show = false;
          }
        }
      }
    }
  }


  UnorderedMap<Module*, UnorderedMap<Symbol, ResolutionEntry>> resolved_exports;

  // The set of modules for which we already reported a cycle in the export chain.
  UnorderedSet<Module*> reported_cyclic_modules;

  // The set of show nodes for which we already reported an issue.
  UnorderedSet<ast::Identifier*> reported_show_nodes;

  CycleDetector<Module*> cycle_detector;

  // When an export-cycle is encountered, this variable is set to the beginning of
  // the cycle, so that callers can avoid printing additional error messages for
  // nodes that are in the cycle.
  Module* export_cycle_start_node = null;

  // Looks for `name` in the module.
  // If `name` comes from an export recursively continues.
  std::function<ResolutionEntry (Module* module, Symbol name)> resolve_identifier;

  // If there is an error during resolution always returns the empty entry.
  resolve_identifier = [&](Module* module, Symbol name) {
    // Start by seeing if the name is in this module.
    auto scope = module->scope();
    auto entry = scope->lookup_module(name);
    // Common case: the identifier was declared in this module.
    if (!entry.is_empty()) return entry;

    bool explicitly_exported = module->exported_identifiers().contains(name);

    // Not transitively exported.
    if (!module->export_all() && !explicitly_exported) return ResolutionEntry();

    // If we have seen this module before, we are in a cycle of exports.
    bool has_cycle = cycle_detector.check_cycle(module, [&](const std::vector<Module*>& cycle) {
      report_cyclic_export(cycle, name, &reported_cyclic_modules, diagnostics());
    });
    if (has_cycle) {
      export_cycle_start_node = module;
      return ResolutionEntry();
    }

    // Check whether we already resolved this export-identifier.
    auto module_probe = resolved_exports.find(module);
    if (module_probe != resolved_exports.end()) {
      auto probe = module_probe->second.find(name);
      if (probe != module_probe->second.end()) {
        // The export was already resolved.
        return probe->second;
      }
    }
    // Initialize the resolved_export as empty.
    // If we find better, we will update it. This way we won't report errors
    //   multiple times for the same nodes.
    resolved_exports[module][name] = ResolutionEntry();

    // Check whether we are trying to export a prefix.
    if (explicitly_exported) {
      // Check whether the `name` is a prefix.
      entry = scope->non_prefixed_imported()->lookup_prefix_and_explicit(name);
      if (entry.is_prefix()) {
        auto error_node = find_export_node(module, name);
        report_error(error_node, "Can't export prefix '%s'", name.c_str());
        return ResolutionEntry();
      }
    }

    if (entry.is_empty()) {
      // See if there is an explicit show in this module which would take precedence.
      auto probe = show_map[module].find(name);
      if (probe != show_map[module].end()) {
        cycle_detector.start(module);
        entry = resolve_identifier(probe->second.module, name);
        cycle_detector.stop(module);
        if (export_cycle_start_node != null) {
          // We are in an export cycle. Don't continue looking for the identifier.
          if (export_cycle_start_node == module) {
            export_cycle_start_node = null;
          }
          return ResolutionEntry();
        }
      }
    }

    if (entry.is_empty()) {
      // Transitively search through all modules.
      // The search is at most one level deep unless the module exports the
      // identifier (in which case we recursively continue).
      auto non_prefixed = module->scope()->non_prefixed_imported();
      cycle_detector.start(module);
      ResolutionEntry resolved_entry;
      bool should_return = false;
      for (auto module_scope : non_prefixed->imported_scopes()) {
        resolved_entry = resolve_identifier(module_scope->module(), name);
        if (!resolved_entry.is_empty() && entry.is_empty()) {
          entry = resolved_entry;
        } else if (!resolved_entry.is_empty() &&
            entry.nodes()[0] != resolved_entry.nodes()[0]) {
          auto error_node = find_export_node(module, name);
          diagnostics()->start_group();
          report_error(error_node, "Ambiguous export of '%s'", name.c_str());
          report_error(entry.nodes()[0], "Definition of '%s'", name.c_str());
          report_error(resolved_entry.nodes()[0], "Definition of '%s'", name.c_str());
          diagnostics()->end_group();
          should_return = true;
          break;
        }
      }
      cycle_detector.stop(module);
      if (export_cycle_start_node != null) {
        // We are in an export cycle. Don't continue looking for the identifier.
        if (export_cycle_start_node == module) {
          export_cycle_start_node = null;
        }
        return ResolutionEntry();
      }
      // From the outside, it's as if the resolution just didn't find anything.
      if (should_return) return ResolutionEntry();
    }

    if (explicitly_exported && entry.is_empty()) {
      auto identifier = find_export_node(module, name);
      report_error(identifier, "Unresolved export '%s'", name.c_str());
      return ResolutionEntry();
    }
    resolved_exports[module][name] = entry;
    return entry;
  };

  for (auto module : show_map.keys()) {
    // If a module has an `export *`, all `show` identifiers count as
    // explicit exports. They also disambiguate which element should be
    // exported if there are multiple modules that provide a toplevel element
    // with that name.
    ASSERT(!module->scope()->exported_identifiers_map_has_been_set());
    Scope::ResolutionEntryMap exported_identifiers_map;
    bool export_all = module->export_all();
    ModuleScope* scope = module->scope();
    auto shows = show_map.at(module);
    for (auto name : shows.keys()) {
      Module::PrefixedModule prefix = shows.at(name);
      if (prefix.module->unit()->is_error_unit()) continue;
      auto resolved_entry = resolve_identifier(prefix.module, name);
      if (resolved_entry.is_empty()) {
        report_unresolved_show(prefix, name, &reported_show_nodes, diagnostics());
      } else {
        scope->non_prefixed_imported()->add(name, resolved_entry);
        if (export_all) exported_identifiers_map[name] = resolved_entry;
      }

      if (module == lsp_module && name == lsp_name) {
        // We can't yet invoke the lsp-handler, as the exports haven't been resolved yet.
        lsp_resolution_entry = resolved_entry;
        lsp_scope = prefix.module->scope();
      }
    }
    module->scope()->set_exported_identifiers_map(exported_identifiers_map);
  }
  for (auto module : modules) {
    Scope::ResolutionEntryMap exported_identifiers_map = module->scope()->exported_identifiers_map();
    for (auto exported : module->exported_identifiers()) {
      auto scope = module->scope();
      auto entry = scope->lookup_module(exported);
      // We are not allowed to export a local identifier.
      // These are exported automatically.
      if (!entry.is_empty()) {
        auto identifier = find_export_node(module, exported);
        report_error(identifier, "Can't export local '%s'", exported.c_str());
        // Even if there was a 'show' with that name, we overwrite the entry in the export map.
        exported_identifiers_map[exported] = ResolutionEntry();
      } else {
        auto probe = exported_identifiers_map.find(exported);
        if (probe == exported_identifiers_map.end()) {
          // No explicit 'show' with that name, so we need to find it in all imports.
          ASSERT(cycle_detector.in_progress_size() == 0);
          auto resolved = resolve_identifier(module, exported);
          exported_identifiers_map[exported] = resolved;
          if (module == lsp_module && exported == lsp_name) {
            // We could invoke the lsp-handler here, but we need to handle the case where
            // the entry isn't resolved anyway.
            lsp_resolution_entry = resolved;
          }
        }
      }
    }
    module->scope()->set_exported_identifiers_map(exported_identifiers_map);
  }

  // Finally check whether we have a cycle in export-alls.
  // These aren't checked earlier if we didn't look for a specific identifier.
  UnorderedMap<Module*, int> export_all_modules_map;
  std::vector<Module*> export_all_modules;
  std::function<void (Module*)> traverse;
  traverse = [&](Module* module) {
    if (!module->export_all()) return;
    if (export_all_modules_map.find(module) != export_all_modules_map.end()) {
      // Cycle.
      auto sub = std::vector<Module*>(export_all_modules.begin() + export_all_modules_map.at(module),
                                      export_all_modules.end());
      report_cyclic_export(sub, Symbol::invalid(), &reported_cyclic_modules, diagnostics());
      return;
    }
    export_all_modules_map[module] = export_all_modules.size();
    export_all_modules.push_back(module);
    auto non_prefixed = module->scope()->non_prefixed_imported();
    for (auto module_scope : non_prefixed->imported_scopes()) {
      traverse(module_scope->module());
    }
    export_all_modules_map.remove(module);
    export_all_modules.pop_back();
  };
  for (auto module : modules) {
    traverse(module);
  }

  if (lsp_node != null) {
    if (is_lsp_show) {
      lsp_->selection_handler()->show(lsp_node, lsp_resolution_entry, lsp_scope);
    } else {
      lsp_->selection_handler()->expord(lsp_node, lsp_resolution_entry, lsp_module->scope());
    }
  }
}

void Resolver::build_module_scopes(std::vector<Module*>& modules) {
  // Start by collecting all top-level declarations of a module and store it
  // in a ModuleScope.
  for (auto module : modules) {
    Map<Symbol, std::vector<ir::Node*>> declarations;

    // Build the local module scope.
    ModuleScope* scope = _new ModuleScope(module, module->export_all());
    bool discard_invalid_symbols = true;  // And ignores them.
    ScopeFiller filler(discard_invalid_symbols);
    filler.add_all(module->classes());
    filler.add_all(module->methods());
    filler.add_all(module->globals());
    filler.fill(scope);

    // TODO(florian): check that entries aren't conflicting. ?
    module->set_scope(scope);
  }

  // Set the imports (as "Prefix") in the Module scope.
  // Every imported module is in a Prefix instance. There is one that has a prefix
  // of "".
  for (auto module : modules) {
    auto module_scope = module->scope();

    auto non_prefixed = _new NonPrefixedImportScope();

    for (auto prefixed_module : module->imported_modules()) {
      auto ast_prefix = prefixed_module.prefix;
      auto show_identifiers = prefixed_module.show_identifiers;

      if (ast_prefix != null) {
        ASSERT(prefixed_module.is_explicitly_imported);
        auto prefix_name = ast_prefix->data();
        // Check whether the prefix clashes with a toplevel identifier.
        auto module_entry = module_scope->lookup_module(prefix_name);
        if (!module_entry.is_empty()) {
          diagnostics()->start_group();
          report_error(ast_prefix, "Prefix clashes with toplevel declaration '%s'", prefix_name.c_str());
          report_error(module_entry.nodes()[0], "Toplevel declaration '%s'", prefix_name.c_str());
          diagnostics()->end_group();
          continue;
        }

        auto entry = non_prefixed->lookup_prefix_and_explicit(prefix_name);
        // So far we can only find imported since we haven't set any explicit
        // identifiers yet.
        ASSERT(entry.is_empty() || entry.is_prefix());
        ImportScope* current = null;
        if (entry.is_empty()) {
          // First time we see this prefix.
          auto new_prefix = _new ImportScope(prefix_name);
          non_prefixed->add(prefix_name, ResolutionEntry(new_prefix));
          current = new_prefix;
        } else {
          current = entry.prefix();
        }
        // If there are no show-identifiers we add the scope. Show-identifiers will be
        // added explicitly later.
        if (show_identifiers.is_empty()) {
          current->add(prefixed_module.module->scope(), prefixed_module.is_explicitly_imported);
        }
      } else {
        // If there are no show-identifiers we add the scope. Show-identifiers will be
        // added explicitly later.
        if (show_identifiers.is_empty()) {
          non_prefixed->add(prefixed_module.module->scope(), prefixed_module.is_explicitly_imported);
        }
      }
    }
    module_scope->set_non_prefixed_imported(non_prefixed);
  }

  resolve_shows_and_exports(modules);
}

void Resolver::mark_runtime(Module* core_module) {
  UnorderedSet<Module*> finished_modules;

  std::function<void (Module*)> mark;
  mark = [&](Module* module) {
    if (finished_modules.contains(module)) return;
    finished_modules.insert(module);

    for (auto klass : module->classes()) {
      klass->mark_runtime_class();
    }
    for (auto method : module->methods()) {
      method->mark_runtime_method();
    }

    for (auto imported : module->imported_modules()) {
      mark(imported.module);
    }
  };

  mark(core_module);
}

void Resolver::mark_non_returning(Module* core_module) {
  // TODO(florian): instead of having an allowlist here, we should mark the methods
  //   in the source somehow.
  std::vector<Symbol> non_returning{
    Symbols::throw_,
    Symbols::rethrow,
    Symbols::lookup_failure_,
    Symbols::as_check_failure_,
    Symbols::unreachable,
    Symbols::uninitialized_global_failure_,
  };
  for (auto name : non_returning) {
    auto entry = core_module->scope()->lookup(name).entry;
    ASSERT(entry.is_single());
    auto method = entry.single()->as_Method();
    ASSERT(method != null);
    method->mark_does_not_return();
  }
}

ir::Class* Resolver::resolve_class_interface_or_mixin(ast::Expression* ast_node,
                                                      Scope* scope,
                                                      ir::Class* holder,
                                                      bool needs_interface,
                                                      bool needs_mixin) {
  ResolutionEntry type_declaration;
  if (ast_node->is_Identifier()) {
    auto type_name = ast_node->as_Identifier()->data();
    type_declaration = scope->lookup_shallow(type_name);
    if (ast_node->is_LspSelection()) {
      ir::Node* ir_resolved = type_declaration.is_single() ? type_declaration.single() : null;
      lsp_->selection_handler()->class_interface_or_mixin(ast_node,
                                                          scope,
                                                          holder,
                                                          ir_resolved,
                                                          needs_interface,
                                                          needs_mixin);
    }
  } else if (ast_node->is_Dot()) {
    auto ast_dot = ast_node->as_Dot();
    type_declaration = scope->lookup_prefixed(ast_dot);
    if (ast_dot->name()->is_LspSelection()) {
      ir::Node* ir_resolved = type_declaration.is_single() ? type_declaration.single() : null;
      auto prefix_lookup_result = scope->lookup(ast_dot->receiver()->as_Identifier()->data());
      // If the LHS is not a prefix, we just provide an empty scope instead.
      SimpleScope empty_scope(null);
      auto prefix_scope = prefix_lookup_result.entry.is_prefix()
          ? static_cast<IterableScope*>(prefix_lookup_result.entry.prefix())
          : static_cast<IterableScope*>(&empty_scope);
      lsp_->selection_handler()->class_interface_or_mixin(ast_dot->name(),
                                                          prefix_scope,
                                                          holder,
                                                          ir_resolved,
                                                          needs_interface,
                                                          needs_mixin);
    } else if (ast_dot->receiver()->is_LspSelection()) {
      auto receiver_as_type_name = ast_dot->receiver()->as_Identifier()->data();
      auto receiver_as_type_declaration = scope->lookup_shallow(receiver_as_type_name);
      ir::Node* ir_resolved = receiver_as_type_declaration.is_single()
          ? receiver_as_type_declaration.single()
          : null;
      lsp_->selection_handler()->class_interface_or_mixin(ast_node,
                                                          scope,
                                                          holder,
                                                          ir_resolved,
                                                          needs_interface,
                                                          needs_mixin);
    }
  } else {
    ASSERT(ast_node->is_Error());
    return null;
  }

  if (type_declaration.is_class()) return type_declaration.klass();
  return null;
}

/// Sets up the inheritance chain of all classes.
///
/// Checks that:
/// - the supers of classes exist.
/// - the class hierarchy isn't cyclic.
/// - there aren't any mismatches (classes extending interfaces, ...)
void Resolver::setup_inheritance(std::vector<Module*> modules, int core_module_index) {
  Module* core_module = modules[core_module_index];
  auto core_scope = core_module->scope();
  ir::Class* top = core_scope->lookup_shallow(Symbols::Object).klass();
  ir::Class* interface_top = core_scope->lookup_shallow(Symbols::Interface_).klass();
  ir::Class* mixin_top = core_scope->lookup_shallow(Symbols::Mixin_).klass();
  ASSERT(top != null);

  ir::Class* monitor = core_scope->lookup_shallow(Symbols::__Monitor__).klass();
  ASSERT(monitor != null);

  for (auto module : modules) {
    Scope* scope = module->scope();

    // -- Check that super classes exist.
    for (auto klass : module->classes()) {
      ast::Class* ast_class = ast_for(klass);

      // When the class doesn't have a super, or there is an error, the default_super is used.
      ir::Class* default_super = null;
      switch (ast_class->kind()) {
        case ast::Class::CLASS:
          default_super = top;
          break;
        case ast::Class::INTERFACE:
          default_super = interface_top;
          break;
        case ast::Class::MONITOR:
          default_super = monitor;
          break;
        case ast::Class::MIXIN:
          default_super = mixin_top;
          break;
      }

      if (!ast_class->has_super() || ast_class->super()->is_Error()) {
        if (klass != top && klass != interface_top && klass != mixin_top) {
          klass->set_super(default_super);
        }
      } else {
        bool detected_error = false;
        auto ast_super = ast_class->super();
        auto ir_super_class = resolve_class_interface_or_mixin(ast_super,
                                                               scope,
                                                               klass,
                                                               klass->is_interface(),
                                                               klass->is_mixin());

        if (ast_class->is_monitor()) {
          report_error(ast_class->super(), "Monitors may not have a super class");
          detected_error = true;
        }
        if (ir_super_class != null) {
          bool super_matches_kind =
              klass->is_interface() == ir_super_class->is_interface() &&
              klass->is_mixin() == ir_super_class->is_mixin();
          if (!super_matches_kind) {
            detected_error = true;
            if (klass->is_interface()) {
              report_error(ast_class->super(), "Super of an interface must be an interface");
            } else if (klass->is_mixin()) {
              report_error(ast_class->super(), "Super of a mixin must be a mixin");
            } else {
              report_error(ast_class->super(), "Super of a class must be a class");
            }
          } else if (ir_super_class == monitor) {
            detected_error = true;
            report_error(ast_class->super(), "Cannot extend builtin Monitor class");
          } else if (!detected_error) {
            klass->set_super(ir_super_class);
          }
        } else {
          detected_error = true;
          const char* class_type = "";
          switch (ast_class->kind()) {
            case ast::Class::CLASS:
            case ast::Class::MONITOR:
              class_type = "class";
              break;
            case ast::Class::INTERFACE:
              class_type = "interface";
              break;
            case ast::Class::MIXIN:
              class_type = "mixin";
              break;
          }
          report_error(ast_class->super(), "Unresolved super %s", class_type);
        }
        if (detected_error) {
          klass->set_super(default_super);
        }
      }

      auto ast_mixins = ast_class->mixins();
      if (klass->is_interface() && !ast_mixins.is_empty()) {
        report_error(ast_mixins[0], "Interfaces may not have mixins");
      }
      ListBuilder<ir::Class*> ir_mixins;
      for (int i = 0; i < ast_mixins.length(); i++) {
        auto ast_mixin = ast_mixins[i];
        auto ir_mixin = resolve_class_interface_or_mixin(ast_mixin, scope, klass, false, true);
        if (ir_mixin == null) {
          report_error(ast_mixin, "Unresolved mixin");
        } else if (!ir_mixin->is_mixin()) {
          report_error(ast_mixin, "Not a mixin");
        } else {
          ir_mixins.add(ir_mixin);
        }
      }
      klass->set_mixins(ir_mixins.build());

      auto ast_interfaces = ast_class->interfaces();
      ListBuilder<ir::Class*> ir_interfaces;
      for (int i = 0; i < ast_interfaces.length(); i++) {
        auto ast_interface = ast_interfaces[i];
        auto ir_interface = resolve_class_interface_or_mixin(ast_interface, scope, klass, true, false);
        if (ir_interface == null) {
          report_error(ast_interface, "Unresolved interface");
        } else if (!ir_interface->is_interface()) {
          report_error(ast_interface, "Not an interface");
        } else {
          ir_interfaces.add(ir_interface);
        }
      }
      klass->set_interfaces(ir_interfaces.build());
    }
  }

  // Now check for cycles.
  UnorderedSet<ir::Class*> checked_classes;
  // Keep track of all classes in cycles.
  // At the end we reset their supers/interfaces, so that we don't trip up the
  // rest of the compiler.
  UnorderedSet<ir::Class*> cycling_classes;
  Set<ir::Class*> sub_classes;

  checked_classes.insert(top);

  std::function<void (ir::Class*)> check_cycles;
  check_cycles = [&](ir::Class* klass) {
    if (klass == null) return;
    if (checked_classes.contains(klass)) return;
    if (sub_classes.contains(klass)) {
      // Cycle detected.
      std::vector<ir::Class*> cycle_nodes;
      bool in_cycle = false;
      for (auto sub_class : sub_classes) {
        if (sub_class == klass) in_cycle = true;
        if (in_cycle) cycle_nodes.push_back(sub_class);
      }
      diagnostics()->start_group();
      const char* chain_kind = null;
      switch (cycle_nodes[0]->kind()) {
        case ir::Class::CLASS:
        case ir::Class::MONITOR:
          chain_kind = "super";
          break;
        case ir::Class::INTERFACE:
          chain_kind = "interface";
          break;
        case ir::Class::MIXIN:
          chain_kind = "mixin";
          break;
      }
      report_error(cycle_nodes[0], "Cycle in %s chain", chain_kind);
      for (size_t i = 0; i < cycle_nodes.size(); i++) {
        auto current = cycle_nodes[i];
        cycling_classes.insert(current);
        auto ast_current = ast_for(current);
        auto next = cycle_nodes[(i + 1) % cycle_nodes.size()];
        auto error_range = Source::Range::invalid();
        if (next == current->super()) {
          error_range = ast_current->super()->selection_range();
        } else {
          List<ir::Class*> ir_nodes;
          List<ast::Expression*> ast_nodes;
          if (next->is_interface()) {
            ir_nodes = current->interfaces();
            ast_nodes = ast_current->interfaces();
          } else {
            ASSERT(next->is_mixin());
            ir_nodes = current->mixins();
            ast_nodes = ast_current->mixins();
          }
          // If interfaces/mixins are not resolved the length of the IR and AST interfaces
          // may differ. In that case, we don't have an easy 1:1 relationship between
          // the resolved interfaces/mixins and the AST nodes.
          // In that case, we take the range of all interfaces/mixins.
          if (ir_nodes.length() < ast_nodes.length()) {
            auto first = ast_nodes[0];
            auto last = ast_nodes.last();
            error_range = first->selection_range().extend(last->selection_range());
          } else {
            ast::Node* ast_position_node = null;
            for (int j = 0; j < ir_nodes.length(); j++) {
              if (ir_nodes[j] == next) {
                ast_position_node = ast_nodes[j];
                break;
              }
            }
            ASSERT(ast_position_node != null);
            error_range = ast_position_node->selection_range();
          }
        }
        diagnostics()->report_error(error_range, "This clause contributes to the cycle");
      }
      diagnostics()->end_group();
      return;
    }
    sub_classes.insert(klass);
    check_cycles(klass->super());
    for (auto ir_interface : klass->interfaces()) {
      check_cycles(ir_interface);
    }
    for (auto ir_mixin : klass->mixins()) {
      check_cycles(ir_mixin);
    }
    sub_classes.erase_last(klass);
    checked_classes.insert(klass);
  };

  for (auto module : modules) {
    for (const auto& klass : module->classes()) {
      check_cycles(klass);
    }
  }
  for (auto klass : cycling_classes.underlying_set()) {
    // When the class doesn't have a super, or there is an error, the default_super is used.
    ir::Class* default_super = null;
    if (klass->super() == monitor) {
      default_super = monitor;
    } else if (klass->is_interface()) {
      default_super = interface_top;
    } else if (klass->is_mixin()) {
      default_super = mixin_top;
    } else {
      default_super = top;
    }
    klass->replace_super(default_super);
    klass->replace_interfaces(List<ir::Class*>());
    klass->replace_mixins(List<ir::Class*>());
  }
}

static bool is_operator_name(Symbol name) {
  return name == Token::symbol(Token::EQ) ||
      name == Token::symbol(Token::LT) ||
      name == Token::symbol(Token::LTE) ||
      name == Token::symbol(Token::GTE) ||
      name == Token::symbol(Token::GT) ||
      name == Token::symbol(Token::ADD) ||
      name == Token::symbol(Token::SUB) ||
      name == Token::symbol(Token::MUL) ||
      name == Token::symbol(Token::DIV) ||
      name == Token::symbol(Token::MOD) ||
      name == Token::symbol(Token::BIT_NOT) ||
      name == Token::symbol(Token::BIT_AND) ||
      name == Token::symbol(Token::BIT_OR) ||
      name == Token::symbol(Token::BIT_XOR) ||
      name == Token::symbol(Token::BIT_SHR) ||
      name == Token::symbol(Token::BIT_USHR) ||
      name == Token::symbol(Token::BIT_SHL) ||
      name == Symbols::index ||
      name == Symbols::index_put ||
      name == Symbols::index_slice;
}

static bool is_valid_operator_shape(Symbol name, const ResolutionShape& shape) {
  if (shape.total_block_count() != 0) return false;

  if (name == Symbols::index_slice) {
    // Only unnamed is the receiver.
    if (shape.max_unnamed_non_block() != 1) return false;

    // Slice operator must have two named parameters: 'from' and 'to'.
    // They can be optional (but we don't need to test that here).
    if (shape.names().length() != 2) return false;
    if (shape.names()[0] != Symbols::from && shape.names()[1] != Symbols::from) return false;
    if (shape.names()[0] != Symbols::to && shape.names()[1] != Symbols::to) return false;
    return true;
  }

  if (shape.has_optional_parameters()) return false;
  if (!shape.names().is_empty()) return false;

  int parameter_count = shape.max_arity();
  if (name == Token::symbol(Token::EQ) ||
      name == Token::symbol(Token::LT) ||
      name == Token::symbol(Token::LTE) ||
      name == Token::symbol(Token::GTE) ||
      name == Token::symbol(Token::GT) ||
      name == Token::symbol(Token::ADD) ||
      name == Token::symbol(Token::MUL) ||
      name == Token::symbol(Token::DIV) ||
      name == Token::symbol(Token::MOD) ||
      name == Token::symbol(Token::BIT_AND) ||
      name == Token::symbol(Token::BIT_OR) ||
      name == Token::symbol(Token::BIT_XOR) ||
      name == Token::symbol(Token::BIT_SHR) ||
      name == Token::symbol(Token::BIT_USHR) ||
      name == Token::symbol(Token::BIT_SHL)) {
    return parameter_count == 2;
  }
  if (name == Token::symbol(Token::SUB)) {
    return parameter_count == 1 || parameter_count == 2;
  }
  if (name == Token::symbol(Token::BIT_NOT)) {
    return parameter_count == 1;
  }
  if (name == Symbols::index) {
    return parameter_count > 1;
  }
  if (name == Symbols::index_put) {
    return parameter_count > 2;
  }
  UNREACHABLE();
  return false;
}


class HasExplicitReturnVisitor : public ast::TraversingVisitor {
 public:
  void visit_Return(ast::Return* node) {
    result_ = true;
    // No need to traverse the rest of the expression.
  }

  void visit_Call(ast::Call* node) {
    if (node->is_call_primitive()) result_ = true;
    if (!result_) {
      TraversingVisitor::visit_Call(node);
    }
  }

  void visit_Sequence(ast::Sequence* node) {
    auto expressions = node->expressions();
    // Go through the sequence in reverse order, since returns are generally last.
    for (int i = expressions.length() - 1; i >= 0; i--) {
      expressions[i]->accept(this);
      // No need to continue, once we found a return.
      if (result_) return;
    }
  }

  bool result() { return result_; }

 private:
   bool result_ = false;
};

void Resolver::check_method(ast::Method* method, ir::Class* holder,
                            Symbol* name, ir::Method::MethodKind* kind,
                            bool allow_future_reserved) {
  bool is_toplevel = holder == null;
  bool class_is_interface = is_toplevel ? false : holder->is_interface();
  auto class_name = is_toplevel ? Symbol::invalid() : holder->name();
  auto name_or_dot = method->name_or_dot();
  bool is_operator = false;

  bool is_named_constructor_or_factory = name_or_dot->is_Dot();
  ast::Identifier* ast_name_node;
  if (is_named_constructor_or_factory) {
    ast_name_node = name_or_dot->as_Dot()->name();
    ASSERT(!is_operator_name(*name));
  } else {
    ast_name_node = name_or_dot->as_Identifier();
  }
  *name = ast_name_node->data();
  is_operator = is_operator_name(*name);

  if (!is_named_constructor_or_factory && *name == Symbols::constructor) {
    if (method->is_setter()) {
      report_error(ast_name_node,
                   "Constructors can't be followed by '='");
    }
    // Allowed.
  } else if (Symbols::is_reserved(*name)) {
    report_error(ast_name_node,
                 "Can't use '%s' as name for a %s",
                 name->c_str(),
                 is_named_constructor_or_factory ? "constructor" : "method");
  }
  if (Symbols::is_future_reserved(*name)) {
    // Some core methods are allowed to have the reserved identifier for now.
    if (!is_toplevel || !allow_future_reserved) {
      diagnostics()->report_warning(ast_name_node,
                                    "Name '%s' will be reserved in future releases",
                                    name->c_str());
    }
  }
  auto method_is_abstract = method->is_abstract();
  auto is_static = method->is_static();
  if (is_toplevel) {
    if (is_static) {
      report_error(name_or_dot, "Toplevel functions can't have the 'static' modifier");
    }
    // For the rest of the checking we treat toplevel functions as if they were static.
    is_static = true;
  }

  if (!class_is_interface && !method_is_abstract && method->body() == null) {
    report_error(name_or_dot, "Missing body");
  }
  if (is_operator) {
    if (is_static) {
      report_error(name_or_dot, "Operators may not be static");
    } else if (*name == Symbols::index || *name == Symbols::index_put) {
      int min_param_count = *name == Symbols::index ? 2 : 3;  // Including 'this'.
      auto shape = ResolutionShape::for_instance_method(method);
      if (shape.has_optional_parameters() ||
          !shape.names().is_empty() ||
          shape.max_arity() < min_param_count) {
        report_error(name_or_dot,
                     "Invalid method shape for '%s'",
                     name->c_str());
      }
    } else {
      auto shape = ResolutionShape::for_instance_method(method);
      if (!is_valid_operator_shape(*name, shape)) {
        report_error(name_or_dot,
                     "Invalid method shape for '%s'",
                     name->c_str());
      }
    }
  }

  if (is_named_constructor_or_factory ||
      (name->is_valid() && *name == class_name) ||
      (name->is_valid() && *name == Symbols::constructor)) {
    if (*name == class_name) {
      diagnostics()->report_warning(name_or_dot->selection_range(),
                                    "Class-name constructors are deprecated");
    }
    bool is_valid = true;
    if (is_toplevel) {
      is_valid = false;
    } else if (is_named_constructor_or_factory) {
      auto receiver_name = name_or_dot->as_Dot()->receiver()->as_Identifier()->data();
      if (receiver_name == class_name) {
        diagnostics()->report_warning(name_or_dot->selection_range(),
                                      "Class-name constructors are deprecated");
      }
      is_valid = receiver_name == Symbols::constructor || receiver_name == class_name;
    }
    if (!is_valid) {
      report_error(name_or_dot, "Invalid name");
      *kind = ir::Method::GLOBAL_FUN;
    } else {
      if (is_static) {
        report_error(name_or_dot, "Constructors can't be static");
      }
      if (method_is_abstract) {
        report_error(name_or_dot, "Constructors can't be abstract");
      }

      HasExplicitReturnVisitor visitor;
      visitor.visit(method);
      bool has_explicit_return = visitor.result();

      if (!has_explicit_return) {
        if (class_is_interface) {
          report_error(name_or_dot, "Interfaces can't have constructors");
        } else if (holder->is_mixin()) {
          if (method->arity() != 0) {
            report_error(name_or_dot, "Mixins can only have default constructors");
          }
        }
      }
      if (has_explicit_return) {
        *kind = ir::Method::FACTORY;
      } else {
        *kind = ir::Method::CONSTRUCTOR;
      }
    }
  } else if (is_static) {
    if (method_is_abstract) {
      report_error(name_or_dot, "Static functions can't be abstract");
    }
    *kind = ir::Method::GLOBAL_FUN;

  // TODO: we shouldn't make synchronization dependent on the first character.
  //       Or if we do, it should be documented.
  } else if (ast_for(holder)->is_monitor() && !name->is_private_identifier()) {
    if (method_is_abstract) {
      report_error(name_or_dot, "Monitor functions can't be abstract");
    }
    *kind = ir::Method::INSTANCE;
  } else {
    if (class_is_interface && method_is_abstract) {
      report_error(name_or_dot, "Interface members can't be declared abstract");
    } else if (!holder->is_abstract() && method_is_abstract) {
      const char* kind_name = holder->is_mixin() ? "mixin" : "class";
      report_error(name_or_dot, "Members can't be abstract in non-abstract %s", kind_name);
    }
    if (class_is_interface && method->body() != null) {
      report_error(name_or_dot, "Interface members can't have bodies");
    } else if (method_is_abstract && method->body() != null) {
      report_error(name_or_dot, "Abstract members can't have bodies");
    }
    *kind = ir::Method::INSTANCE;
  }
}

void Resolver::check_field(ast::Field* field, ir::Class* holder) {
  auto name = field->name()->data();
  if (Symbols::is_reserved(name)) {
    report_error(field->name(), "Can't use '%s' as name for a field", name.c_str());
  }
  if (Symbols::is_future_reserved(name)) {
    diagnostics()->report_warning(field->name(),
                                  "Name '%s' will be reserved in future releases",
                                  name.c_str());
  }
  if (field->is_abstract()) {
    report_error(field, "Fields can't be abstract");
  }
  if (!field->is_static() && holder != null && holder->is_interface()) {
    report_error(field, "Interfaces can't have fields");
  }
  if (holder == null && field->is_static()) {
    report_error(field, "Globals can't have 'static' modifier");
  }
}

void Resolver::check_class(ast::Class* klass) {
  auto name = klass->name()->data();
  if (Symbols::is_reserved(name)) {
    report_error(klass->name(), "Can't use '%s' as name for a %s",
                 name.c_str(),
                 klass->is_interface() ? "interface" : "class");
  }
  if (Symbols::is_future_reserved(name)) {
    diagnostics()->report_warning(klass->name(),
                                  "Name '%s' will be reserved in future releases",
                                  name.c_str());
  }
}

/// Fills in skeleton information of classes.
///
/// Fills in all members.
void Resolver::fill_classes_with_skeletons(std::vector<Module*> modules) {
  for (auto module : modules) {
    // Fill in all members.
    for (auto ir_class : module->classes()) {
      auto ast_class = ast_for(ir_class);
      Symbol class_name = ast_class->name()->data();
      ListBuilder<ir::Method*> constructors;
      ListBuilder<ir::Method*> factories;
      ListBuilder<ir::MethodInstance*> methods;
      ListBuilder<ir::Field*> fields;

      bool class_is_interface = ast_class->is_interface();
      bool class_has_constructors = false;
      bool class_has_factories = false;

      ScopeFiller statics_scope_filler;

      if (ir_class->is_task_class()) {
        // Add the implicit stack field.
        auto stack_field = _new ir::Field(Symbols::stack_,
                                          ir_class,
                                          false,
                                          ir_class->range(),
                                          ir_class->range());
        fields.add(stack_field);
        // TODO(florian): find field type for `stack_` field.
        ir_to_ast_map_[stack_field] =
            _new ast::Field(_new ast::Identifier(Symbols::stack_),
                            null,    // No type.
                            _new ast::LiteralNull(),
                            false,   // Not static.
                            false,   // Not abstract.
                            false,   // Not final.
                            Source::Range::invalid());
      }
      for (auto member : ast_class->members()) {
        auto name_or_dot = member->name_or_dot();

        if (member->is_Method()) {
          Symbol member_name = Symbol::invalid();
          ir::Method::MethodKind kind;
          auto method = member->as_Method();
          auto method_is_abstract = method->is_abstract();

          bool allow_future_reserved;
          check_method(method, ir_class, &member_name, &kind, allow_future_reserved = false);

          auto position = method->selection_range();
          auto outline_range = method->outline_range();
          ir::Method* ir_method = null;
          switch (kind) {
            case ir::Method::CONSTRUCTOR: {
              auto shape = ResolutionShape::for_instance_method(method);
              ir_method = _new ir::Constructor(member_name, ir_class, shape, position, outline_range);
              class_has_constructors = true;
              if (method->name_or_dot()->is_Identifier()) {
                ASSERT(member_name == class_name || member_name == Symbols::constructor);
                constructors.add(ir_method);
              } else {
                statics_scope_filler.add(member_name, ir_method);
              }
              break;
            }
            case ir::Method::FACTORY: {
              auto shape = ResolutionShape::for_static_method(method);
              ir_method = _new ir::MethodStatic(member_name, ir_class, shape, kind, position, outline_range);
              class_has_factories = true;
              if (method->name_or_dot()->is_Identifier()) {
                ASSERT(member_name == class_name || member_name == Symbols::constructor);
                factories.add(ir_method);
              } else {
                statics_scope_filler.add(member_name, ir_method);
              }
              break;
            }
            case ir::Method::GLOBAL_FUN: {
              auto shape = ResolutionShape::for_static_method(method);
              ir_method = _new ir::MethodStatic(member_name, ir_class, shape, kind, position, outline_range);
              statics_scope_filler.add(member_name, ir_method);
              break;
            }
            case ir::Method::INSTANCE: {
              // TODO: we shouldn't make synchronization dependent on the first character.
              //       Or if we do, it should be documented.
              if (ast_class->is_monitor() && !member_name.is_private_identifier()) {
                auto shape = ResolutionShape::for_instance_method(method);
                ir_method = _new ir::MonitorMethod(member_name, ir_class, shape, position, outline_range);
                methods.add(ir_method->as_MethodInstance());
              } else {
                auto shape = ResolutionShape::for_instance_method(method);
                ir_method = _new ir::MethodInstance(member_name, ir_class, shape, method_is_abstract, position, outline_range);
                methods.add(ir_method->as_MethodInstance());
              }
              break;
            }
            case ir::Method::GLOBAL_INITIALIZER:
            case ir::Method::FIELD_INITIALIZER:
              UNREACHABLE();
          }
          ir_to_ast_map_[ir_method] = member;
        } else {
          ASSERT(name_or_dot->is_Identifier());
          Symbol member_name = name_or_dot->as_Identifier()->data();
          auto ast_field = member->as_Field();
          auto position = ast_field->selection_range();
          auto outline_range = ast_field->outline_range();
          check_field(ast_field, ir_class);
          if (ast_field->is_static()) {
            auto ir_global = _new ir::Global(member_name,
                                             ir_class,
                                             ast_field->is_final(),
                                             position,
                                             ast_field->outline_range());
            ir_to_ast_map_[ir_global] = member;
            statics_scope_filler.add(ir_global->name(), ir_global);
          } else {
            auto ir_field = _new ir::Field(member_name,
                                           ir_class,
                                           ast_field->is_final(),
                                           ast_field->selection_range(),
                                           ast_field->outline_range());
            ir_to_ast_map_[ir_field] = member;
            fields.add(ir_field);
            auto ir_getter = _new ir::FieldStub(ir_field, ir_class, true, position, outline_range);
            auto ir_setter = _new ir::FieldStub(ir_field, ir_class, false, position, outline_range);
            methods.add(ir_getter);
            methods.add(ir_setter);
            ir_to_ast_map_[ir_getter] = member;
            ir_to_ast_map_[ir_setter] = member;
          }
        }
      }

      if (!class_has_constructors && class_has_factories) {
        if (!ir_class->is_runtime_class() && !ir_class->is_interface()) {
          // The internal `Array` class only has factories, which is why we exclude
          // runtime classes.
          const char* kind_name = ir_class->is_mixin() ? "mixin" : "class";
          report_error(ir_class, "A %s with factories must have a constructor", kind_name);
        }
      } else if (!class_is_interface && !class_has_constructors) {
        // Create default-constructor place-holder (which takes `this` as argument).
        auto position = ast_class->selection_range();
        auto outline_range = ast_class->outline_range();
        ir::Constructor* constructor =
            _new ir::Constructor(Symbols::constructor, ir_class, position, outline_range);
        constructors.add(constructor);
      }

      ir_class->set_unnamed_constructors(constructors.build());
      ir_class->set_factories(factories.build());
      ir_class->set_methods(methods.build());
      ir_class->set_fields(fields.build());

      auto scope = _new StaticsScope();
      statics_scope_filler.fill(scope);
      ir_class->set_statics(scope);
    }
  }
}

/// Fills the given [abstract_methods] map with the abstract methods of klass. At the same
/// time fills in the abstract methods of super classes.
///
/// Abstract methods are initially set to the abstract method, and are then replaced with
///   the implementation methods (if they exist).
/// We need an ordered map, which is why we can't remove the entries.
///
/// Reuses existing entries in the [abstract_methods] map.
///
/// This approach is not complete, as it uses selectors for map keys. Methods with
///   optional arguments might not be a complete match but still shadow abstract methods.
/// Callers of this method thus need to do a more expensive check when it looks like
///   an abstract method isn't implemented.
static void fill_abstract_methods_map(ir::Class* ir_class,
                                      UnorderedMap<ir::Class*, Map<Selector<ResolutionShape>, ir::Method*>>* abstract_methods,
                                      Diagnostics* diagnostics) {
  auto probe = abstract_methods->find(ir_class);
  if (probe != abstract_methods->end()) return;
  auto super = ir_class->super();
  Map<Selector<ResolutionShape>, ir::Method*> super_abstracts;
  // If the super or the class' mixins are not abstract, we assume that this
  //   `ir_class` doesn't need to implement anything from any of its parents.
  //   If necessary, we will provide error messages on the super/mixin, as they
  //   should have been marked 'abstract' otherwise.
  if (super != null && super->is_abstract()) {
    fill_abstract_methods_map(super, abstract_methods, diagnostics);
    super_abstracts = abstract_methods->at(super);
  }
  bool all_mixins_are_non_abstract = true;
  for (auto mixin : ir_class->mixins()) {
    if (mixin->is_abstract()) {
      all_mixins_are_non_abstract = false;
      break;
    }
  }
  if (super_abstracts.empty() && all_mixins_are_non_abstract && !ir_class->is_abstract()) {
    // Handle the most common case.
    (*abstract_methods)[ir_class] = Map<Selector<ResolutionShape>, ir::Method*>();
    return;
  }

  Map<Selector<ResolutionShape>, ir::Method*> class_abstracts;
  for (auto selector : super_abstracts.keys()) {
    ir::Method* method = super_abstracts.at(selector);
    if (method->is_abstract()) {
      class_abstracts[selector] = method;
    }
  }
  for (auto mixin : ir_class->mixins()) {
    fill_abstract_methods_map(mixin, abstract_methods, diagnostics);
    auto mixin_abstracts = abstract_methods->at(mixin);
    for (auto selector : mixin_abstracts.keys()) {
      ir::Method* method = mixin_abstracts.at(selector);
      class_abstracts[selector] = method;
    }
  }
  if (ir_class->is_abstract() || !class_abstracts.empty()) {
    // This doesn't work if the methods don't have the exact same signature.
    // With optional parameters the selectors might not match 100%. This means
    // that we need to do another check before reporting errors.
    for (auto method : ir_class->methods()) {
      Selector<ResolutionShape> selector(method->name(), method->resolution_shape());
      if (method->is_abstract()) {
        if (method->name().is_valid()) {
          class_abstracts[selector] = method;
        } else {
          ASSERT(diagnostics->encountered_error());
        }
      } else {
        auto probe = class_abstracts.find(selector);
        if (probe != class_abstracts.end()) {
          class_abstracts[selector] = method;
        }
      }
    }
  }
  (*abstract_methods)[ir_class] = class_abstracts;
}

/// Checks that the klass has its mixins flattened.
/// Only does a conservative check.
static bool mixins_are_flattened(std::vector<Module*> modules) {
  for (auto module : modules) {
    for (auto klass : module->classes()) {
      if (klass->mixins().is_empty()) continue;
      UnorderedSet<ir::Class*> mixins;
      for (auto mixin : klass->mixins()) {
        mixins.insert(mixin);
      }
      for (auto mixin : klass->mixins()) {
        // Require that the super is in the mixins list, unless it is
        // the 'Mixin_' top.
        if (mixin->has_super()) {
          auto super = mixin->super();
          bool is_top = !super->has_super();
          if (!is_top && !mixins.contains(super)) {
            return false;
          }
        }
        // Require that all its mixins are in the mixins list.
        for (auto mixin_mixin : mixin->mixins()) {
          if (!mixins.contains(mixin_mixin)) {
            return false;
          }
        }
      }
    }
  }
  return true;
}

void Resolver::report_abstract_classes(std::vector<Module*> modules) {
  ASSERT(mixins_are_flattened(modules));
  UnorderedMap<ir::Class*, Map<Selector<ResolutionShape>, ir::Method*>> abstract_methods;

  Map<ir::Class*, Map<Symbol, std::vector<ResolutionShape>>> all_method_shapes;
  // Lazily fill the method shapes.
  auto method_shapes_for = [&](ir::Class* klass) {
    auto probe = all_method_shapes.find(klass);
    if (probe != all_method_shapes.end()) return probe->second;
    Map<Symbol, std::vector<ResolutionShape>> result;
    for (auto method : klass->methods()) {
      if (method->is_abstract()) continue;
      auto name = method->name();
      result[name].push_back(method->resolution_shape());
    }
    return result;
  };

  UnorderedMap<ir::Class*, Set<ir::Class*>> all_contributing;
  // Lazily fill the contributing classes.
  std::function<Set<ir::Class*> (ir::Class*)> contributing_for;
  contributing_for = [&](ir::Class* klass) {
    auto probe = all_contributing.find(klass);
    if (probe != all_contributing.end()) return probe->second;
    Set<ir::Class*> result;
    if (klass->has_super()) {
      auto super_probe = all_contributing.find(klass->super());
      Set<ir::Class*> super_contributing = (super_probe != all_contributing.end())
          ? super_probe->second
          : contributing_for(klass->super());

      result.insert_all(super_contributing);
    }
    for (auto mixin : klass->mixins()) {
      result.insert(mixin);
    }
    // The class itself also contributes.
    result.insert(klass);
    all_contributing[klass] = result;
    return result;
  };

  for (auto module : modules) {
    for (auto ir_class : module->classes()) {
      fill_abstract_methods_map(ir_class, &abstract_methods, diagnostics());
    }
  }

  for (auto module : modules) {
    for (auto ir_class : module->classes()) {
      if (ir_class->is_interface()) continue;
      if (ir_class->is_abstract()) continue;
      auto class_abstracts = abstract_methods.at(ir_class);
      if (class_abstracts.empty()) continue;
      bool has_abstract_method = false;
      for (auto selector : class_abstracts.keys()) {
        if (class_abstracts[selector]->is_abstract()) {
          has_abstract_method = true;
          break;
        }
      }
      if (!has_abstract_method) continue;

      Map<ir::Method*, CallShape> missing_methods;

      // We might have a non-implemented abstract method.
      // Do a more thorough check that handles optional arguments as well.
      // We also look at super classes of the abstract class now.
      for (auto selector : class_abstracts.keys()) {
        auto method = class_abstracts[selector];
        if (method->is_abstract()) {
          auto shape = method->resolution_shape();
          auto name = method->name();
          std::vector<ResolutionShape> potentially_implementing;

          // Classes that can contribute methods.
          auto contributing_classes = contributing_for(ir_class);

          for (auto contributing : contributing_classes) {
            auto shapes = method_shapes_for(contributing);
            auto probe = shapes.find(name);
            if (probe != shapes.end()) {
              for (auto shape : probe->second) {
                potentially_implementing.push_back(shape);
              }
            }
          }
          if (potentially_implementing.empty()) {
            missing_methods.set(method, CallShape::invalid());
            continue;
          }
          auto missing_shape = CallShape::invalid();
          if (!shape.is_fully_shadowed_by(potentially_implementing, &missing_shape)) {
            // If the missing_shape is valid, then we have partial shadowing.
            missing_methods.set(method, missing_shape);
          }
        }
      }

      if (missing_methods.empty()) continue;

      diagnostics()->start_group();
      report_error(ir_class,
                   "Non-abstract class '%s' is missing implementations",
                   ir_class->name().c_str());
      for (auto missing_method : missing_methods.keys()) {
        auto missing_shape = missing_methods.at(missing_method);
        if (missing_shape.is_valid()) {
          // TODO(florian): report which shape is missing.
          report_note(missing_method,
                      "Method '%s' is only partially implemented",
                      missing_method->name().c_str());
        } else {
          report_note(missing_method,
                      "Missing implementation for '%s'",
                      missing_method->name().c_str());
        }
      }
      diagnostics()->end_group();
    }
  }
}

void Resolver::check_interface_implementations_and_flatten(std::vector<Module*> modules) {
  ASSERT(mixins_are_flattened(modules));
  // For each interface, the set it represents.
  UnorderedMap<ir::Class*, Set<ir::Class*>> flattened_interfaces;

  std::function<Set<ir::Class*> (ir::Class*)> flatten;
  flatten = [&](ir::Class* klass) {
    auto probe = flattened_interfaces.find(klass);
    if (probe != flattened_interfaces.end()) return probe->second;

    Set<ir::Class*> flattened;
    if (klass->is_interface()) flattened.insert(klass);
    if (klass->has_super()) flattened.insert_all(flatten(klass->super()));
    for (auto mixin : klass->mixins()) {
      flattened.insert_all(flatten(mixin));
    }
    for (auto ir_interface : klass->interfaces()) {
      flattened.insert_all(flatten(ir_interface));
    }
    flattened_interfaces[klass] = flattened;
    return flattened;
  };
  for (auto module : modules) {
    for (auto ir_class : module->classes()) {
      flatten(ir_class);
    }
  }

  UnorderedMap<ir::Class*, UnorderedSet<Selector<ResolutionShape>>> interface_methods;

  for (auto module : modules) {
    for (auto ir_class : module->classes()) {
      auto interfaces = flattened_interfaces.at(ir_class);
      if (interfaces.empty()) continue;

      ir_class->replace_interfaces(interfaces.to_list());

      UnorderedSet<Selector<ResolutionShape>> maybe_missing_methods;
      for (auto ir_interface : interfaces) {
        for (auto method : ir_interface->methods()) {
          Selector<ResolutionShape> selector(method->name(), method->resolution_shape());
          maybe_missing_methods.insert(selector);
        }
      }
      if (maybe_missing_methods.empty()) continue;

      Map<Symbol, std::vector<ResolutionShape>> all_existing_shapes;

      // Find the methods in this class and the superclasses.
      // TODO(florian): we could cache super methods.
      auto current = ir_class;
      while (current != null) {
        for (int i = -1; i < current->mixins().length(); i++) {
          ir::Class* current_or_mixin = i == -1
              ? current
              : current->mixins()[i];
          for (auto class_method : current_or_mixin->methods()) {
            auto name = class_method->name();
            auto shape = class_method->resolution_shape();
            all_existing_shapes[name].push_back(shape);
            Selector<ResolutionShape> selector(name, shape);
            maybe_missing_methods.erase(selector);
            if (maybe_missing_methods.empty()) break;
          }
          if (maybe_missing_methods.empty()) break;
        }
        current = current->super();
        if (maybe_missing_methods.empty()) break;
      }
      if (!maybe_missing_methods.empty()) {
        // Do a more expensive check.
        UnorderedMap<Selector<ResolutionShape>, CallShape> really_missing_methods;

        for (auto method_selector : maybe_missing_methods.underlying_set())  {
          auto name = method_selector.name();
          auto shape = method_selector.shape();
          auto probe = all_existing_shapes.find(name);
          if (probe == all_existing_shapes.end()) {
            really_missing_methods.add(method_selector, CallShape::invalid());
            continue;
          }
          auto missing_shape = CallShape::invalid();
          bool is_fully_shadowed = shape.is_fully_shadowed_by(probe->second, &missing_shape);
          if (!is_fully_shadowed) {
            really_missing_methods.add(method_selector, missing_shape);
          }
        }

        if (!really_missing_methods.empty()) {
          diagnostics()->start_group();
          report_error(ir_class, "Missing implementations for interface methods");

          for (auto ir_interface : interfaces) {
            for (auto method : ir_interface->methods()) {
              Selector<ResolutionShape> selector(method->name(), method->resolution_shape());
              auto probe = really_missing_methods.find(selector);
              if (probe != really_missing_methods.end()) {
                // TODO(florian): report which shape is missing.
                if (probe->second.is_valid()) {
                  report_note(method, "Method '%s' is only partially implemented", method->name().c_str());
                } else {
                  report_note(method, "Missing implementation for '%s'", method->name().c_str());
                }
              }
            }
          }
          diagnostics()->end_group();
        }
      }
    }
  }
}

void Resolver::flatten_mixins(std::vector<Module*> modules) {
  // For each mixin, the flatten list of mixins it represents.
  // For example:
  //     mixin Mix1:
  //     mixin Mix2 extends Mix1:
  //     mixin Mix3:
  //     mixin Mix4 extends Mix3 with Mix2:
  //     class A extends Object with Mix4:
  // Here the flattened list of mixins for A is [Mix4, Mix2, Mix1, Mix3]
  // The mixins are ordered so that earlier mixins shadow methods of later mixins.
  // Note that mixins may appear multiple times.
  // For mixins their own set does not include the super mixins.
  // In our example the list of mixins for Mix4 is [Mix2, Mix1].
  UnorderedMap<ir::Class*, List<ir::Class*>> flattened_mixins;

  // Recursively flattens the mixins of the given class.
  // Drop any 'Mixin_' class, since it doesn't add anything.
  // If the given class is a mixin, also remembers the full list of
  // mixins that are mixed in in the 'flattened_mixins' map.
  std::function<List<ir::Class*> (ir::Class*)> flatten;
  flatten = [&](ir::Class* klass) {
    auto probe = flattened_mixins.find(klass);
    if (probe != flattened_mixins.end()) return probe->second;

    ListBuilder<ir::Class*> flattened_builder;
    for (int i = klass->mixins().length() - 1; i >= 0; i--) {
      auto ir_mixin = klass->mixins()[i];
      if (!ir_mixin->has_super()) {
        // Skip the Mixin_ top.
        continue;
      }
      flattened_builder.add(flatten(ir_mixin));
    }
    // Contrary to the 'flattened_mixins' map, each class only has the set
    // of mixins between itself and super as mixin list.
    // The map contains all the mixins (including the class and super mixins).
    klass->replace_mixins(flattened_builder.build());

    if (!klass->is_mixin()) return List<ir::Class*>();

    if (klass->has_super()) flattened_builder.add(flatten(klass->super()));
    auto flattened = flattened_builder.build();
    // Now add ourselves to the front, unless we are the `Mixin_` class.
    ListBuilder<ir::Class*> with_self;
    if (klass->has_super()) with_self.add(klass);
    with_self.add(flattened);
    auto flattened_with_self = with_self.build();
    flattened_mixins[klass] = flattened_with_self;
    return flattened_with_self;
  };

  for (auto module : modules) {
    for (auto ir_class : module->classes()) {
      flatten(ir_class);
    }
  }
}

void Resolver::resolve_fill_method(ir::Method* method,
                                   ir::Class* holder,
                                   Scope* scope,
                                   Module* entry_module,
                                   Module* core_module) {
  // Skip synthetic methods already compiled.
  if (method->body() != null) {
    ASSERT(ir_to_ast_map_.find(method) == ir_to_ast_map_.end());
    return;
  }

  MethodResolver resolver(method, holder, scope, &ir_to_ast_map_, entry_module, core_module,
                          lsp_, source_manager_, diagnostics_);
  resolver.resolve_fill();
  auto& new_assignments = resolver.global_assignments();
  global_assignments_.insert(global_assignments_.end(),
                             new_assignments.begin(),
                             new_assignments.end());

  if (!method->is_synthetic()) {
    auto ast_node = ir_to_ast_map_.at(method)->as_Declaration();
    if (ast_node->toitdoc().is_valid()) {
      LocalScope scope_with_parameters(scope);
      for (auto parameter : method->parameters()) {
        scope_with_parameters.add(parameter->name(), ResolutionEntry(parameter));
      }
      auto toitdoc = resolve_toitdoc(ast_node->toitdoc(),
                                     ast_node,
                                     &scope_with_parameters,
                                     lsp_,
                                     ir_to_ast_map_,
                                     diagnostics());
      toitdocs_.set_toitdoc(method, toitdoc);
      method->set_deprecation(extract_deprecation_message(toitdoc));
    }
  }
}

void Resolver::resolve_field(ir::Field* field,
                             ir::Class* holder,
                             Scope* scope,
                             Module* entry_module,
                             Module* core_module) {
  // We pick a random resolution-shape. It's not used anyway.
  ResolutionShape fake_shape(0);
  ir::MethodInstance fake_method(ir::Method::MethodKind::FIELD_INITIALIZER,
                                 Symbol::synthetic("<field-init>"),
                                 holder,
                                 fake_shape,
                                 false,
                                 field->range(),
                                 field->outline_range());
  MethodResolver resolver(&fake_method, holder, scope, &ir_to_ast_map_, entry_module, core_module,
                          lsp_, source_manager_, diagnostics_);
  resolver.resolve_field(field);

  auto ast_node = ir_to_ast_map_.at(field)->as_Declaration();
  if (ast_node->toitdoc().is_valid()) {
    auto toitdoc = resolve_toitdoc(ast_node->toitdoc(),
                                   ast_node,
                                   scope,
                                   lsp_,
                                   ir_to_ast_map_,
                                   diagnostics());
    toitdocs_.set_toitdoc(field, toitdoc);
    field->set_deprecation(extract_deprecation_message(toitdoc));
  }
}

void Resolver::resolve_fill_toplevel_methods(Module* module,
                                             Module* entry_module,
                                             Module* core_module) {
  auto scope = module->scope();
  for (auto method : module->methods()) {
    resolve_fill_method(method, null, scope, entry_module, core_module);
  }
}

void Resolver::resolve_fill_globals(Module* module,
                                    Module* entry_module,
                                    Module* core_module) {

  auto scope = module->scope();
  for (auto global : module->globals()) {
    ASSERT(global->body() == null);
    resolve_fill_method(global, null, scope, entry_module, core_module);
  }
}

static ir::Class* resolve_tree_root(Symbol name, ModuleScope* scope) {
  auto lookup_result = scope->lookup_shallow(name);
  if (!lookup_result.is_class()) FATAL("Missing tree root");
  return lookup_result.klass();
}

List<ir::Class*> Resolver::find_tree_roots(Module* core_module) {

  ListBuilder<ir::Class*> tree_roots;

  auto core_scope = core_module->scope();

#define T(_, n) tree_roots.add(resolve_tree_root(Symbols:: n, core_scope));
TREE_ROOT_CLASSES(T)
#undef T

  return tree_roots.build();
}

static ir::Method* resolve_entry_point(Symbol name, int arity, ModuleScope* scope) {
  CallShape shape(arity);
  auto lookup_result = scope->lookup_shallow(name);
  for (auto candidate : lookup_result.nodes()) {
    if (!candidate->is_Method()) continue;
    auto method = candidate->as_Method();
    if (!method->resolution_shape().accepts(shape)) continue;
    return method;
  }
  FATAL("Missing entry point %s", name.c_str());
  return null;
}

List<ir::Method*> Resolver::find_entry_points(Module* core_module) {
  auto core_scope = core_module->scope();

  ListBuilder<ir::Method*> entries;

#define E(n, lib_name, a) \
  entries.add(resolve_entry_point(Symbols:: n, a, core_scope));
ENTRY_POINTS(E)
#undef E

  return entries.build();
}

List<ir::Type> Resolver::find_literal_types(Module* core_module) {
  static Symbol literal_type_symbols[] = {
    Symbols::bool_,
    Symbols::True,
    Symbols::False,
    Symbols::int_,
    Symbols::float_,
    Symbols::string,
    Symbols::Null_,
  };
  int literal_type_count = sizeof(literal_type_symbols) / sizeof(*literal_type_symbols);
  auto result = ListBuilder<ir::Type>::allocate(literal_type_count);

  auto core_scope = core_module->scope();
  for (int i = 0; i < literal_type_count; i++) {
    auto lookup_entry = core_scope->lookup(literal_type_symbols[i]).entry;
    if (!lookup_entry.is_class()) FATAL("MISSING LITERAL TYPE");
    result[i] = ir::Type(lookup_entry.klass());
  }
  return result;
}

void Resolver::resolve_fill_module(Module* module,
                                   Module* entry_module,
                                   Module* core_module) {
  auto unit = module->unit();
  if (unit->toitdoc().is_valid()) {
    auto toitdoc = resolve_toitdoc(unit->toitdoc(),
                                   unit,
                                   module->scope(),
                                   lsp_,
                                   ir_to_ast_map_,
                                   diagnostics());
    toitdocs_.set_toitdoc(module, toitdoc);
    module->set_deprecation(extract_deprecation_message(toitdoc));
  }
  resolve_fill_toplevel_methods(module, entry_module, core_module);
  resolve_fill_classes(module, entry_module, core_module);
  resolve_fill_globals(module, entry_module, core_module);
}

void Resolver::resolve_fill_classes(Module* module,
                                    Module* entry_module,
                                    Module* core_module) {
  auto module_scope = module->scope();
  for (auto klass : module->classes()) {
    resolve_fill_class(klass, module_scope, entry_module, core_module);
  }
}

void Resolver::resolve_fill_class(ir::Class* klass,
                                  ModuleScope* module_scope,
                                  Module* entry_module,
                                  Module* core_module) {
  auto ast_node = ir_to_ast_map_.at(klass)->as_Class();

  // Note that we build up the super-chain multiple times. That is, we
  // visit a super class as often as the super class is present.
  // We could only compute a super class once (especially, if the classes
  // are sorted by inheritance).
  // If this section ever shows up on profiles it would be easy to change.

  Map<Symbol, std::vector<ir::Node*>> declarations;

  for (auto current = klass; current != null; current = current->super()) {
    for (auto method : current->methods()) {
      auto name = method->name();
      if (!name.is_valid()) continue;
      declarations[name].push_back(method);
    }
    // Add statics to the scope of the class.
    if (current == klass) {
      for (auto node : current->statics()->nodes()) {
        if (!node->name().is_valid()) continue;
        // Named constructors/factories can not be accessed directly. (They need to
        // be prefixed with the classes name).
        if (node->is_constructor()) continue;
        if (node->is_factory()) continue;
        declarations[node->name()].push_back(node);
      }
      // Add the SUPER_CLASS_SEPARATOR so that `super` resolution can
      // find super class entries.
      for (auto name : declarations.keys()) {
        declarations[name].push_back(ClassScope::SUPER_CLASS_SEPARATOR);
      }
    }
    // The mixins must happen after the `SUPER_CLASS_SEPARATOR`.
    // Note that the mixins are already in the correct order:
    // For `class A extends B with C D`, the `mixins` are [D, C].
    for (auto mixin : current->mixins()) {
      for (auto method : mixin->methods()) {
        auto name = method->name();
        if (!name.is_valid()) continue;
        declarations[name].push_back(method);
      }
    }
  }

  ClassScope class_scope(klass, module_scope);

  for (auto name : declarations.keys()) {
    auto& vector = declarations[name];
    // Note that overridden members are multiple times in the vector.
    // We use those for super-resolution, and they don't take up that much
    // space. In general they don't affect the resolution: either we find the
    // overridden member first (since subclasses have the members added
    // first), or we skip over them when searching for a valid member.
    // Either way they won't matter, unless we search for them in the super
    // resolution.
    auto list = ListBuilder<ir::Node*>::build_from_vector(vector);
    class_scope.add(name, ResolutionEntry(list));
  }

  if (ast_node->toitdoc().is_valid()) {
    auto toitdoc = resolve_toitdoc(ast_node->toitdoc(),
                                   ast_node,
                                   &class_scope,
                                   lsp_,
                                   ir_to_ast_map_,
                                   diagnostics());
    toitdocs_.set_toitdoc(klass, toitdoc);
    klass->set_deprecation(extract_deprecation_message(toitdoc));
  }

  for (auto field : klass->fields()) {
    // Fields must be resolved first, as their type is used for
    // setting parameters.
    resolve_field(field, klass, &class_scope, entry_module, core_module);
  }
  // Resolve the methods.
  for (auto constructor : klass->unnamed_constructors()) {
    resolve_fill_method(constructor, klass, &class_scope, entry_module, core_module);
  }
  for (auto factory : klass->factories()) {
    resolve_fill_method(factory, klass, &class_scope, entry_module, core_module);
  }
  for (auto statik : klass->statics()->nodes()) {
    resolve_fill_method(statik, klass, &class_scope, entry_module, core_module);
  }
  for (auto method : klass->methods()) {
    resolve_fill_method(method, klass, &class_scope, entry_module, core_module);
  }
}

void Resolver::add_global_assignment_typechecks() {
  for (auto assignment : global_assignments_) {
    auto global = assignment->global();
    if (!global->has_explicit_type()) continue;
    auto type = global->return_type();
    if (!type.is_class()) continue;
    auto value = assignment->right();
    value = _new ir::Typecheck(ir::Typecheck::GLOBAL_AS_CHECK,
                               value,
                               type,
                               type.klass()->name(),
                               value->range());
    assignment->replace_right(value);
  }
}

} // namespace toit::compiler
} // namespace toit
