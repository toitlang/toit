// Copyright (C) 2022 Toitware ApS.
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

#include <utility>
#include <vector>
#include <string>

#include "../../top.h"

#include "completion_kind.h"
#include "protocol.h"

#include "../diagnostic.h"
#include "../ir.h"
#include "../list.h"
#include "../map.h"
#include "../queryable_class.h"
#include "../sources.h"
#include "../resolver_scope.h"
#include "../symbol.h"

namespace toit {
namespace compiler {

namespace ast {
class Node;
class Dot;
class Class;
}

class IterableScope;
class ImportScope;
class Queryables;
class ToitdocScopeIterator;
class ToitdocRegistry;

/// For some operations, the LSP client sends the server a selection for which it
/// wants information. This selection is given to the compiler which then detects
/// it during the compilation process.
/// When the compiler finds a selection it invokes the selection handler with all
/// the information that could be relevant. Different selection handlers then
/// use the information to supply the requested information to the LSP server.
/// For example, a selection handler could ask for a completion, or be a request
/// for a goto-definition target.
class LspSelectionHandler {
 public:
  /// The constructor takes a protocol as argument. All information that is
  /// sent to the LSP server must go through the protocol.
  explicit LspSelectionHandler(LspProtocol* protocol) : _protocol(protocol) { }
  virtual ~LspSelectionHandler() { }

  /// Handles a class or interface node.
  ///
  /// This is used when a class resolves a superclass (in the extends clause) or for
  ///   finding interfaces (in the implements clause).
  virtual void class_or_interface(ast::Node* node, IterableScope* scope, ir::Class* holder, ir::Node* resolved, bool needs_interface) = 0;

  /// Handles a type node.
  ///
  /// This is used for type annotations.
  /// Contrary to class_or_interface, it also supports `any`, `none` (if allowed), and the shorthands.
  virtual void type(ast::Node* node, IterableScope* scope, ResolutionEntry resolved, bool allow_none) = 0;

  // This method is also called for `named` selections.
  virtual void call_virtual(ir::CallVirtual* node,  // With the receiver being an LspSelectionDot.
                            ir::Type type,
                            List<ir::Class*> classes) = 0;
  virtual void call_prefixed(ast::Dot* node,
                             ir::Node* resolved1,
                             ir::Node* resolved2,
                             List<ir::Node*> candidates,
                             IterableScope* scope) = 0;
  // Class calls are dotted calls, where the receiver is a Class.
  // They can be static calls, named-constructor calls, or dynamic calls (if the class has
  //   an unnamed constructor).
  virtual void call_class(ast::Dot* node,
                          ir::Class* klass,
                          ir::Node* resolved1,
                          ir::Node* resolved2,
                          List<ir::Node*> candidates,
                          IterableScope* scope) = 0;
  virtual void call_static(ast::Node* node,
                           ir::Node* resolved1,
                           ir::Node* resolved2,
                           List<ir::Node*> candidates,
                           IterableScope* scope,
                           ir::Method* surrounding) = 0;
  virtual void call_block(ast::Dot* node, ir::Node* ir_receiver) = 0;

  virtual void call_static_named(ast::Node* name_node, ir::Node* ir_call_target, List<ir::Node*> candidates) = 0;

  virtual void call_primitive(ast::Node* node, Symbol module_name, Symbol primitive_name,
                              int module, int primitive, bool on_module) = 0;

  // For simplicity, the field-storing-parameter isn't yet resolved.
  // Since it's only necessary to run through the fields that shouldn't be a problem.
  virtual void field_storing_parameter(ast::Parameter* node,
                                       List<ir::Field*> fields,
                                       bool field_storing_is_allowed) = 0;

  virtual void this_(ast::Identifier* node, ir::Class* enclosing_class, IterableScope* scope, ir::Method* surrounding) = 0;

  // The module scope may be null, if the import couldn't be resolved.
  virtual void show(ast::Node* node, ResolutionEntry entry, ModuleScope* scope) = 0;

  virtual void return_label(ast::Node* node, int label_index, const std::vector<std::pair<Symbol, ast::Node*>>& labels) = 0;

  virtual void toitdoc_ref(ast::Node* node,
                           List<ir::Node*> candidates,
                           ToitdocScopeIterator* iterator,
                           bool is_signature_toitdoc) = 0;


 protected:
  LspProtocol* protocol() { return _protocol; }

 private:
  LspProtocol* _protocol;
};

} // namespace toit::compiler
} // namespace toit
