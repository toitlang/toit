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

#include "hover.h"

#include <sstream>
#include <string>
#include <vector>

#include "../resolver_scope.h"
#include "../toitdoc_node.h"

namespace toit {
namespace compiler {

HoverHandler::~HoverHandler() {}

void HoverHandler::terminate() { exit(0); }

namespace {

class ToitdocMarkdownVisitor : public toitdoc::Visitor {
public:
  ToitdocMarkdownVisitor() {}

  std::string result() const { return stream_.str(); }

  void visit_Contents(toitdoc::Contents *node) {
    for (auto section : node->sections()) {
      section->accept(this);
    }
  }

  void visit_Section(toitdoc::Section *node) {
    if (node->title().is_valid()) {
      for (int i = 0; i < node->level(); i++)
        stream_ << "#";
      stream_ << " " << node->title().c_str() << "\n\n";
    }
    for (auto statement : node->statements()) {
      statement->accept(this);
      stream_ << "\n";
    }
  }

  void visit_Statement(toitdoc::Statement *node) {
    // Fallback for unknown statements.
  }

  void visit_CodeSection(toitdoc::CodeSection *node) {
    stream_ << "```\n";
    stream_ << node->code().c_str() << "\n";
    stream_ << "```\n";
  }

  void visit_Itemized(toitdoc::Itemized *node) {
    for (auto item : node->items()) {
      item->accept(this);
    }
  }

  void visit_Item(toitdoc::Item *node) {
    stream_ << "* ";
    bool first = true;
    for (auto statement : node->statements()) {
      // TODO(florian): handle indentation for multi-paragraph items.
      if (!first)
        stream_ << "  ";
      statement->accept(this);
      first = false;
    }
  }

  void visit_Paragraph(toitdoc::Paragraph *node) {
    for (auto expression : node->expressions()) {
      expression->accept(this);
    }
    stream_ << "\n";
  }

  void visit_Expression(toitdoc::Expression *node) {
    // Fallback for unknown expressions.
  }

  void visit_Text(toitdoc::Text *node) { stream_ << node->text().c_str(); }

  void visit_Code(toitdoc::Code *node) {
    stream_ << "`" << node->text().c_str() << "`";
  }

  void visit_Link(toitdoc::Link *node) {
    stream_ << "[" << node->text().c_str() << "](" << node->url().c_str()
            << ")";
  }

  void visit_Ref(toitdoc::Ref *node) {
    // TODO(florian): We could try to resolve the ref to a link.
    stream_ << "`" << node->text().c_str() << "`";
  }

private:
  std::stringstream stream_;
};

} // namespace

void HoverHandler::emit_hover(ir::Node *node) {
  if (node == null || node->is_Error())
    return;

  if (auto reference = node->as_Reference()) {
    node = reference->target();
  }

  // Try to get Toitdoc from the registry first.
  Toitdoc<ir::Node*> toitdoc = Toitdoc<ir::Node*>::invalid();
  if (toitdocs() != null) {
    toitdoc = toitdocs()->toitdoc_for(node);
  }
  
  // Fallback: try to get Toitdoc from AST via ir_to_ast_map.
  Toitdoc<ast::Node*> ast_toitdoc = Toitdoc<ast::Node*>::invalid();
  if (!toitdoc.is_valid() && ir_to_ast_map() != null) {
    auto ast_node = ir_to_ast_map()->lookup(node);
    if (ast_node != null) {
      if (auto decl = ast_node->as_Declaration()) {
        ast_toitdoc = decl->toitdoc();
      } else if (auto klass = ast_node->as_Class()) {
        ast_toitdoc = klass->toitdoc();
      }
    }
  }
  
  // If we have a valid Toitdoc from either source, emit it.
  if (toitdoc.is_valid()) {
    ToitdocMarkdownVisitor visitor;
    toitdoc.contents()->accept(&visitor);
    protocol()->hover()->emit(visitor.result().c_str());
    return;
  }
  
  if (ast_toitdoc.is_valid()) {
    ToitdocMarkdownVisitor visitor;
    ast_toitdoc.contents()->accept(&visitor);
    protocol()->hover()->emit(visitor.result().c_str());
    return;
  }

  // Fallback: emit just the name.
  std::stringstream stream;
  if (auto method = node->as_Method()) {
    stream << "```toit\n" << method->name().c_str() << "\n```";
    protocol()->hover()->emit(stream.str().c_str());
  } else if (auto klass = node->as_Class()) {
    stream << "```toit\nclass " << klass->name().c_str() << "\n```";
    protocol()->hover()->emit(stream.str().c_str());
  }
}

void HoverHandler::class_interface_or_mixin(
    ast::Node *node, IterableScope *scope, ir::Class *holder,
    ir::Node *resolved, bool needs_interface, bool needs_mixin) {
  emit_hover(resolved);
  terminate();
}

void HoverHandler::type(ast::Node *node, IterableScope *scope,
                        ResolutionEntry resolved, bool allow_none) {
  if (resolved.kind() == ResolutionEntry::NODES &&
      !resolved.nodes().is_empty()) {
    emit_hover(resolved.nodes().first());
  }
  terminate();
}

void HoverHandler::call_virtual(ir::CallVirtual *node, ir::Type type,
                                List<ir::Class *> classes) {

  if (type.is_class()) {
    auto klass = type.klass();

    Symbol name = node->selector();
    while (klass) {
      for (auto method : klass->methods()) {
        if (method->name() == name) {
          emit_hover(method);
          terminate();
        }
      }
      klass = klass->super();
    }
    terminate();
  }
}

void HoverHandler::call_prefixed(ast::Dot *node, ir::Node *resolved1,
                                 ir::Node *resolved2,
                                 List<ir::Node *> candidates,
                                 IterableScope *scope) {
  if (resolved1)
    emit_hover(resolved1);
  else if (resolved2)
    emit_hover(resolved2);
  terminate();
}

void HoverHandler::call_class(ast::Dot *node, ir::Class *klass,
                              ir::Node *resolved1, ir::Node *resolved2,
                              List<ir::Node *> candidates,
                              IterableScope *scope) {
  if (resolved1)
    emit_hover(resolved1);
  else if (resolved2)
    emit_hover(resolved2);
  terminate();
}

void HoverHandler::call_static(ast::Node *node, ir::Node *resolved1,
                               ir::Node *resolved2, List<ir::Node *> candidates,
                               IterableScope *scope, ir::Method *surrounding) {
  if (resolved1)
    emit_hover(resolved1);
  else if (resolved2)
    emit_hover(resolved2);
  terminate();
}

void HoverHandler::call_block(ast::Dot *node, ir::Node *ir_receiver) {
  if (ir_receiver)
    emit_hover(ir_receiver);
  terminate();
}

void HoverHandler::call_static_named(ast::Node *name_node,
                                     ir::Node *ir_call_target,
                                     List<ir::Node *> candidates) {
  if (ir_call_target)
    emit_hover(ir_call_target);
  terminate();
}

void HoverHandler::call_primitive(ast::Node *node, Symbol module_name,
                                  Symbol primitive_name, int module,
                                  int primitive, bool on_module) {
  terminate();
}

void HoverHandler::field_storing_parameter(ast::Parameter *node,
                                           List<ir::Field *> fields,
                                           bool field_storing_is_allowed) {
  if (!fields.is_empty())
    emit_hover(fields.first());
  terminate();
}

void HoverHandler::this_(ast::Identifier *node, ir::Class *enclosing_class,
                         IterableScope *scope, ir::Method *surrounding) {
  if (enclosing_class)
    emit_hover(enclosing_class);
  terminate();
}

void HoverHandler::show(ast::Node *node, ResolutionEntry entry,
                        ModuleScope *scope) {
  if (entry.kind() == ResolutionEntry::NODES && !entry.nodes().is_empty()) {
    emit_hover(entry.nodes().first());
  }
  terminate();
}

void HoverHandler::expord(ast::Node *node, ResolutionEntry entry,
                          ModuleScope *scope) {
  if (entry.kind() == ResolutionEntry::NODES && !entry.nodes().is_empty()) {
    emit_hover(entry.nodes().first());
  }
  terminate();
}

void HoverHandler::return_label(
    ast::Node *node, int label_index,
    const std::vector<std::pair<Symbol, ast::Node *>> &labels) {
  terminate();
}

void HoverHandler::toitdoc_ref(ast::Node *node, List<ir::Node *> candidates,
                               ToitdocScopeIterator *iterator,
                               bool is_signature_toitdoc) {
  if (!candidates.is_empty())
    emit_hover(candidates.first());
  terminate();
}

void HoverHandler::import_path(const char *path, const char *segment,
                               bool is_first_segment, const char *resolved,
                               const Package &current_package,
                               const PackageLock &package_lock,
                               Filesystem *fs) {
  // TODO(florian): implement hover for import paths.
  terminate();
}

} // namespace compiler
} // namespace toit
