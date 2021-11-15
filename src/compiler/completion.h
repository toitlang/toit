// Copyright (C) 2019 Toitware ApS.
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

#include <string>

#include "../top.h"

#include "lsp.h"
#include "package.h"

namespace toit {
namespace compiler {

class PackageLock;
class SourceManager;

/// A target handler is invoked when the target of a LSP command is encountered.
class CompletionHandler : public LspSelectionHandler {
 public:
  CompletionHandler(Symbol prefix, const std::string& package_id, SourceManager* source_manager)
      : _prefix(prefix)
      , _package_id(package_id)
      , _source_manager(source_manager) {}

  void class_or_interface(ast::Node* node, IterableScope* scope, ir::Class* holder, ir::Node* resolved, bool needs_interface);
  void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none);
  void call_virtual(ir::CallVirtual* node, ir::Type type, List<ir::Class*> classes);
  void call_prefixed(ast::Dot* node,
                     ir::Node* resolved1,
                     ir::Node* resolved2,
                     List<ir::Node*> candidates,
                     IterableScope* scope);
  void call_class(ast::Dot* node,
                  ir::Class* klass,
                  ir::Node* resolved1,
                  ir::Node* resolved2,
                  List<ir::Node*> candidates,
                  IterableScope* scope);
  void call_static(ast::Node* node,
                   ir::Node* resolved1,
                   ir::Node* resolved2,
                   List<ir::Node*> candidates,
                   IterableScope* scope,
                   ir::Method* surrounding);
  void call_block(ast::Dot* node, ir::Node* ir_receiver);

  void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates);

  void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                      int module, int primitive, bool on_module);

  void field_storing_parameter(ast::Parameter* node,
                               List<ir::Field*> fields,
                               bool field_storing_is_allowed);

  void this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding);

  void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope);

  void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels);

  void toitdoc_ref(ast::Node* node,
                   List<ir::Node*> candidates,
                   ToitdocScopeIterator* iterator,
                   bool is_signature_toitdoc);

  static void import_first_segment(Symbol prefix,
                                   ast::Identifier* segment,
                                   const Package& current_package,
                                   const PackageLock& package_lock);
  static void import_path(Symbol prefix, const char* path, Filesystem* fs);

 private:
  // From https://microsoft.github.io/language-server-protocol/specification#textDocument_completion
  enum CompletionKind {
    NONE = -1,  // Not standard. Just used internally to indicate that no kind was given.
    TEXT = 1,
    METHOD = 2,
    FUNCTION = 3,
    CONSTRUCTOR = 4,
    FIELD = 5,
    VARIABLE = 6,
    CLASS = 7,
    INTERFACE = 8,
    MODULE = 9,
    PROPERTY = 10,
    UNIT = 11,
    VALUE = 12,
    ENUM = 13,
    KEYWORD = 14,
    SNIPPET = 15,
    COLOR = 16,
    FILE = 17,
    REFERENCE = 18,
    FOLDER = 19,
    ENUM_MEMBER = 20,
    CONSTANT = 21,
    STRUCT = 22,
    EVENT = 23,
    OPERATOR = 24,
    TYPE_PARAMETER = 25,
  };

  void complete_static_ids(IterableScope* scope, ir::Method* surrounding);
  void complete_named_args(ir::Method* method);

  void complete(Symbol symbol) { complete(symbol.c_str()); }
  void complete(Symbol symbol, CompletionKind kind) { complete(symbol.c_str(), kind); }
  void complete(const std::string& name) { complete(name, NONE); }

  void complete_if_visible(Symbol name,
                           CompletionKind kind,
                           const std::string& package_id);

  void complete_method(ir::Method* method, const std::string& package_id);
  void complete_entry(Symbol name,
                      const ResolutionEntry& entry,
                      CompletionKind kind_override = CompletionKind::NONE);
  void complete(const std::string& name, CompletionKind kind);

  Symbol _prefix;
  std::string _package_id;
  SourceManager* _source_manager;
  UnorderedSet<std::string> emitted;
};

} // namespace toit::compiler
} // namespace toit
