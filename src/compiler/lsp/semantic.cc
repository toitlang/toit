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

#include <vector>
#include <algorithm>

#include "semantic.h"

#include "lsp.h"

#include "../ast.h"
#include "../ir.h"

namespace toit {
namespace compiler {

namespace {

using namespace ir;

// This list must be kept in sync with the one in compiler.toit.
enum class TokenType {
  NAMESPACE = 0,
  CLASS,
  INTERFACE,
  PARAMETER,
  VARIABLE,
};

// The order of these bits must be kept in sync with the one in compiler.toit.
static const int DEFINITION_BIT = 1;
static const int READONLY_BIT = DEFINITION_BIT << 1;
static const int STATIC_BIT = READONLY_BIT << 1;
static const int ABSTRACT_BIT = STATIC_BIT << 1;
static const int DEFAULT_LIBRARY_BIT = ABSTRACT_BIT << 1;

struct SemanticToken {
  int line;
  int column;
  int length;
  TokenType type;
  int modifiers;
};

class TokenVisitor : public TraversingVisitor {
 public:
  TokenVisitor(const char* path, SourceManager* manager) : _path(path), _manager(manager) { }

  void visit_ast_import(ast::Import* import, Module* module) {
    auto prefix = import->prefix();
    if (prefix != null) {
      int modifiers = DEFINITION_BIT;
      emit_token(prefix->range(), TokenType::NAMESPACE, modifiers);
    }
    for (auto segment : import->segments()) {
      emit_token(segment->range(), TokenType::NAMESPACE);
    }
    for (auto show : import->show_identifiers()) {
      UnorderedSet<ModuleScope*> already_visited;
      auto entry = module->scope()->non_prefixed_imported()->lookup(show->data(), &already_visited);
      if (entry.is_empty()) continue;
      switch (entry.kind()) {
        case ResolutionEntry::Kind::NODES:
        case ResolutionEntry::Kind::AMBIGUOUS:
          // Just take the first node.
          emit_token(show->range(), entry.nodes().first());
          break;

        case ResolutionEntry::Kind::PREFIX:
          // This is an error, but we might as well mark it as namespace.
          emit_token(show->range(), TokenType::NAMESPACE);
          break;
      }
    }
  }

  std::vector<SemanticToken> tokens() const { return _tokens; }

 private:
  void emit_token(const Source::Range& range, ir::Node* node, bool is_definition = false) {
    int modifiers = 0;
    if (is_definition) modifiers |= DEFINITION_BIT;
    if (node->is_Local()) {
      auto local = node->as_Local();
      if (local->is_final()) modifiers |= READONLY_BIT;
      emit_token(range, local->is_Parameter() ? TokenType::PARAMETER : TokenType::VARIABLE, modifiers);
    } else if (node->is_Class()) {
      auto klass = node->as_Class();
      if (klass->is_abstract()) modifiers |= ABSTRACT_BIT;
      if (klass->is_runtime_class()) modifiers |= DEFAULT_LIBRARY_BIT;
      emit_token(range, klass->is_interface() ? TokenType::INTERFACE : TokenType::CLASS, modifiers);
    }
  }
  void emit_token(const Source::Range& range, TokenType type, int modifiers = 0) {
    auto location_from = _manager->compute_location(range.from());
    auto location_to = _manager->compute_location(range.to());
    if (location_from.source->absolute_path() != _path) return;
    if (location_from.line_number != location_to.line_number) return;
    int column_from = utf16_offset_in_line(location_from);
    int column_to = utf16_offset_in_line(location_to);
    _tokens.push_back({
      .line = location_from.line_number - 1,
      .column = column_from,
      .length = column_to - column_from,
      .type = type,
      .modifiers = modifiers,
    });
  }

  const char* _path;
  SourceManager* _manager;
  std::vector<SemanticToken> _tokens;
};

}

void emit_tokens(Module* module, const char* path, SourceManager* manager, LspProtocol* protocol) {
  TokenVisitor visitor(path, manager);

  for (auto prefixed : module->imported_modules()) {
    if (!prefixed.is_explicitly_imported) continue;
    visitor.visit_ast_import(prefixed.import, module);
  }

  // TODO(florian): run through the classes, globals and methods.

  auto tokens = visitor.tokens();

  std::sort(tokens.begin(), tokens.end(), [&](const SemanticToken& a,
                                              const SemanticToken& b) {
    if (a.line < b.line) return true;
    if (a.line > b.line) return false;
    return a.column < b.column;
  });

  protocol->semantic()->emit_size(static_cast<int>(tokens.size()));
  int last_line = 0;
  int last_column = 0;
  for (auto token : tokens) {
    int delta_line = token.line - last_line;
    int delta_column = delta_line == 0 ? token.column - last_column : token.column;
    int encoded_token_type = static_cast<int>(token.type);
    protocol->semantic()->emit_token(delta_line,
                                     delta_column,
                                     token.length,
                                     encoded_token_type,
                                     token.modifiers);
    last_line = token.line;
    last_column = token.column;
  }
  exit(0);
}

} // namespace toit::compiler
} // namespace toit

