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

#include <cstring>

#include "ast_equivalence.h"
#include "symbol.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

static bool equiv(Node* a, Node* b);

// Symbols from two separate SymbolCanonicalizers don't share backing
// storage, so the pointer-equality operator== on Symbol doesn't apply.
// Compare the textual content instead.
static bool sym_eq(Symbol a, Symbol b) {
  if (!a.is_valid() && !b.is_valid()) return true;
  if (!a.is_valid() || !b.is_valid()) return false;
  return strcmp(a.c_str(), b.c_str()) == 0;
}

static bool equiv_expr(Expression* a, Expression* b) {
  return equiv(a, b);
}

template <typename T>
static bool equiv_list(List<T*> a, List<T*> b) {
  if (a.length() != b.length()) return false;
  for (int i = 0; i < a.length(); i++) {
    if (!equiv(a[i], b[i])) return false;
  }
  return true;
}

static bool equiv_opt(Node* a, Node* b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return equiv(a, b);
}

// Peels Parenthesis wrappers from the given node. `(x)` is equivalent to
// `x` at the AST level — the formatter can legitimately add or drop parens
// to satisfy layout constraints without changing meaning.
static Node* unwrap(Node* n) {
  while (n != null && n->is_Parenthesis()) {
    n = n->as_Parenthesis()->expression();
  }
  return n;
}

static bool equiv_unit(Unit* a, Unit* b) {
  if (!equiv_list(a->imports(), b->imports())) return false;
  if (!equiv_list(a->exports(), b->exports())) return false;
  if (a->declarations().length() != b->declarations().length()) return false;
  for (int i = 0; i < a->declarations().length(); i++) {
    if (!equiv(a->declarations()[i], b->declarations()[i])) return false;
  }
  return true;
}

static bool equiv_import(Import* a, Import* b) {
  if (a->is_relative() != b->is_relative()) return false;
  if (a->dot_outs() != b->dot_outs()) return false;
  if (a->show_all() != b->show_all()) return false;
  if (!equiv_list(a->segments(), b->segments())) return false;
  if (!equiv_opt(a->prefix(), b->prefix())) return false;
  if (!equiv_list(a->show_identifiers(), b->show_identifiers())) return false;
  return true;
}

static bool equiv_export(Export* a, Export* b) {
  if (a->export_all() != b->export_all()) return false;
  return equiv_list(a->identifiers(), b->identifiers());
}

static bool equiv_class(Class* a, Class* b) {
  if (a->kind() != b->kind()) return false;
  if (a->has_abstract_modifier() != b->has_abstract_modifier()) return false;
  if (!equiv(a->name(), b->name())) return false;
  if (!equiv_opt(a->super(), b->super())) return false;
  if (!equiv_list(a->interfaces(), b->interfaces())) return false;
  if (!equiv_list(a->mixins(), b->mixins())) return false;
  if (!equiv_list(a->members(), b->members())) return false;
  return true;
}

static bool equiv_field(Field* a, Field* b) {
  if (a->is_static() != b->is_static()) return false;
  if (a->is_abstract() != b->is_abstract()) return false;
  if (a->is_final() != b->is_final()) return false;
  if (!equiv(a->name_or_dot(), b->name_or_dot())) return false;
  if (!equiv_opt(a->type(), b->type())) return false;
  if (!equiv_opt(a->initializer(), b->initializer())) return false;
  return true;
}

static bool equiv_method(Method* a, Method* b) {
  if (a->is_setter() != b->is_setter()) return false;
  if (a->is_static() != b->is_static()) return false;
  if (a->is_abstract() != b->is_abstract()) return false;
  if (!equiv(a->name_or_dot(), b->name_or_dot())) return false;
  if (!equiv_opt(a->return_type(), b->return_type())) return false;
  if (!equiv_list(a->parameters(), b->parameters())) return false;
  Sequence* ab = a->body();
  Sequence* bb = b->body();
  if (ab == null && bb == null) return true;
  if (ab == null || bb == null) return false;
  return equiv(ab, bb);
}

static bool equiv_parameter(Parameter* a, Parameter* b) {
  if (a->is_named() != b->is_named()) return false;
  if (a->is_field_storing() != b->is_field_storing()) return false;
  if (a->is_block() != b->is_block()) return false;
  if (!equiv(a->name(), b->name())) return false;
  if (!equiv_opt(a->type(), b->type())) return false;
  if (!equiv_opt(a->default_value(), b->default_value())) return false;
  return true;
}

static bool equiv_named_arg(NamedArgument* a, NamedArgument* b) {
  if (a->inverted() != b->inverted()) return false;
  if (!equiv(a->name(), b->name())) return false;
  return equiv_opt(a->expression(), b->expression());
}

static bool equiv_break_continue(BreakContinue* a, BreakContinue* b) {
  if (a->is_break() != b->is_break()) return false;
  if (!equiv_opt(a->value(), b->value())) return false;
  return equiv_opt(a->label(), b->label());
}

static bool equiv_block(Block* a, Block* b) {
  if (!equiv_list(a->parameters(), b->parameters())) return false;
  return equiv(a->body(), b->body());
}

static bool equiv_lambda(Lambda* a, Lambda* b) {
  if (!equiv_list(a->parameters(), b->parameters())) return false;
  return equiv(a->body(), b->body());
}

static bool equiv_sequence(Sequence* a, Sequence* b) {
  return equiv_list(a->expressions(), b->expressions());
}

static bool equiv_decl_local(DeclarationLocal* a, DeclarationLocal* b) {
  if (a->kind() != b->kind()) return false;
  if (!equiv(a->name(), b->name())) return false;
  if (!equiv_opt(a->type(), b->type())) return false;
  if (!equiv_opt(a->value(), b->value())) return false;
  return true;
}

static bool equiv_if(If* a, If* b) {
  if (!equiv(a->expression(), b->expression())) return false;
  if (!equiv(a->yes(), b->yes())) return false;
  return equiv_opt(a->no(), b->no());
}

static bool equiv_while(While* a, While* b) {
  if (!equiv(a->condition(), b->condition())) return false;
  return equiv(a->body(), b->body());
}

static bool equiv_for(For* a, For* b) {
  if (!equiv_opt(a->initializer(), b->initializer())) return false;
  if (!equiv_opt(a->condition(), b->condition())) return false;
  if (!equiv_opt(a->update(), b->update())) return false;
  return equiv(a->body(), b->body());
}

static bool equiv_try_finally(TryFinally* a, TryFinally* b) {
  if (!equiv(a->body(), b->body())) return false;
  if (!equiv_list(a->handler_parameters(), b->handler_parameters())) return false;
  return equiv(a->handler(), b->handler());
}

static bool equiv_return(Return* a, Return* b) {
  return equiv_opt(a->value(), b->value());
}

static bool equiv_unary(Unary* a, Unary* b) {
  if (a->kind() != b->kind()) return false;
  if (a->prefix() != b->prefix()) return false;
  return equiv(a->expression(), b->expression());
}

static bool equiv_binary(Binary* a, Binary* b) {
  if (a->kind() != b->kind()) return false;
  if (!equiv(a->left(), b->left())) return false;
  return equiv(a->right(), b->right());
}

static bool equiv_call(Call* a, Call* b) {
  if (a->is_call_primitive() != b->is_call_primitive()) return false;
  if (!equiv(a->target(), b->target())) return false;
  return equiv_list(a->arguments(), b->arguments());
}

static bool equiv_dot(Dot* a, Dot* b) {
  if (!equiv(a->receiver(), b->receiver())) return false;
  return equiv(a->name(), b->name());
}

static bool equiv_index(Index* a, Index* b) {
  if (!equiv(a->receiver(), b->receiver())) return false;
  return equiv_list(a->arguments(), b->arguments());
}

static bool equiv_index_slice(IndexSlice* a, IndexSlice* b) {
  if (!equiv(a->receiver(), b->receiver())) return false;
  if (!equiv_opt(a->from(), b->from())) return false;
  return equiv_opt(a->to(), b->to());
}

static bool equiv_identifier(Identifier* a, Identifier* b) {
  return sym_eq(a->data(), b->data());
}

static bool equiv_nullable(Nullable* a, Nullable* b) {
  return equiv(a->type(), b->type());
}

static bool equiv_literal_boolean(LiteralBoolean* a, LiteralBoolean* b) {
  return a->value() == b->value();
}

static bool equiv_literal_integer(LiteralInteger* a, LiteralInteger* b) {
  if (a->is_negated() != b->is_negated()) return false;
  return sym_eq(a->data(), b->data());
}

static bool equiv_literal_character(LiteralCharacter* a, LiteralCharacter* b) {
  return sym_eq(a->data(), b->data());
}

static bool equiv_literal_string(LiteralString* a, LiteralString* b) {
  if (a->is_multiline() != b->is_multiline()) return false;
  return sym_eq(a->data(), b->data());
}

static bool equiv_literal_string_interp(LiteralStringInterpolation* a,
                                        LiteralStringInterpolation* b) {
  if (a->parts().length() != b->parts().length()) return false;
  if (a->formats().length() != b->formats().length()) return false;
  for (int i = 0; i < a->parts().length(); i++) {
    if (!equiv(a->parts()[i], b->parts()[i])) return false;
  }
  for (int i = 0; i < a->formats().length(); i++) {
    LiteralString* af = a->formats()[i];
    LiteralString* bf = b->formats()[i];
    if (af == null && bf == null) continue;
    if (af == null || bf == null) return false;
    if (!equiv(af, bf)) return false;
  }
  return equiv_list(a->expressions(), b->expressions());
}

static bool equiv_literal_float(LiteralFloat* a, LiteralFloat* b) {
  if (a->is_negated() != b->is_negated()) return false;
  return sym_eq(a->data(), b->data());
}

static bool equiv_literal_list(LiteralList* a, LiteralList* b) {
  return equiv_list(a->elements(), b->elements());
}

static bool equiv_literal_byte_array(LiteralByteArray* a, LiteralByteArray* b) {
  return equiv_list(a->elements(), b->elements());
}

static bool equiv_literal_set(LiteralSet* a, LiteralSet* b) {
  return equiv_list(a->elements(), b->elements());
}

static bool equiv_literal_map(LiteralMap* a, LiteralMap* b) {
  return equiv_list(a->keys(), b->keys())
      && equiv_list(a->values(), b->values());
}

static bool equiv(Node* a, Node* b) {
  a = unwrap(a);
  b = unwrap(b);
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;

  // Node kinds must match exactly. (LspSelection inherits from Identifier
  // but is_Identifier() also reports true for LspSelection — we don't treat
  // them as equivalent unless both are the same concrete kind.)
  if (strcmp(a->node_type(), b->node_type()) != 0) return false;

  if (a->is_Unit()) return equiv_unit(a->as_Unit(), b->as_Unit());
  if (a->is_Import()) return equiv_import(a->as_Import(), b->as_Import());
  if (a->is_Export()) return equiv_export(a->as_Export(), b->as_Export());
  if (a->is_Class()) return equiv_class(a->as_Class(), b->as_Class());
  if (a->is_Field()) return equiv_field(a->as_Field(), b->as_Field());
  if (a->is_Method()) return equiv_method(a->as_Method(), b->as_Method());
  if (a->is_Parameter()) return equiv_parameter(a->as_Parameter(), b->as_Parameter());
  if (a->is_NamedArgument()) return equiv_named_arg(a->as_NamedArgument(), b->as_NamedArgument());
  if (a->is_BreakContinue()) return equiv_break_continue(a->as_BreakContinue(), b->as_BreakContinue());
  if (a->is_Block()) return equiv_block(a->as_Block(), b->as_Block());
  if (a->is_Lambda()) return equiv_lambda(a->as_Lambda(), b->as_Lambda());
  if (a->is_Sequence()) return equiv_sequence(a->as_Sequence(), b->as_Sequence());
  if (a->is_DeclarationLocal()) return equiv_decl_local(a->as_DeclarationLocal(), b->as_DeclarationLocal());
  if (a->is_If()) return equiv_if(a->as_If(), b->as_If());
  if (a->is_While()) return equiv_while(a->as_While(), b->as_While());
  if (a->is_For()) return equiv_for(a->as_For(), b->as_For());
  if (a->is_TryFinally()) return equiv_try_finally(a->as_TryFinally(), b->as_TryFinally());
  if (a->is_Return()) return equiv_return(a->as_Return(), b->as_Return());
  if (a->is_Unary()) return equiv_unary(a->as_Unary(), b->as_Unary());
  if (a->is_Binary()) return equiv_binary(a->as_Binary(), b->as_Binary());
  if (a->is_Call()) return equiv_call(a->as_Call(), b->as_Call());
  if (a->is_Dot()) return equiv_dot(a->as_Dot(), b->as_Dot());
  if (a->is_Index()) return equiv_index(a->as_Index(), b->as_Index());
  if (a->is_IndexSlice()) return equiv_index_slice(a->as_IndexSlice(), b->as_IndexSlice());
  if (a->is_Identifier()) return equiv_identifier(a->as_Identifier(), b->as_Identifier());
  if (a->is_Nullable()) return equiv_nullable(a->as_Nullable(), b->as_Nullable());
  if (a->is_LiteralNull()) return true;
  if (a->is_LiteralUndefined()) return true;
  if (a->is_LiteralBoolean()) return equiv_literal_boolean(a->as_LiteralBoolean(), b->as_LiteralBoolean());
  if (a->is_LiteralInteger()) return equiv_literal_integer(a->as_LiteralInteger(), b->as_LiteralInteger());
  if (a->is_LiteralCharacter()) return equiv_literal_character(a->as_LiteralCharacter(), b->as_LiteralCharacter());
  if (a->is_LiteralString()) return equiv_literal_string(a->as_LiteralString(), b->as_LiteralString());
  if (a->is_LiteralStringInterpolation()) {
    return equiv_literal_string_interp(a->as_LiteralStringInterpolation(),
                                       b->as_LiteralStringInterpolation());
  }
  if (a->is_LiteralFloat()) return equiv_literal_float(a->as_LiteralFloat(), b->as_LiteralFloat());
  if (a->is_LiteralList()) return equiv_literal_list(a->as_LiteralList(), b->as_LiteralList());
  if (a->is_LiteralByteArray()) return equiv_literal_byte_array(a->as_LiteralByteArray(), b->as_LiteralByteArray());
  if (a->is_LiteralSet()) return equiv_literal_set(a->as_LiteralSet(), b->as_LiteralSet());
  if (a->is_LiteralMap()) return equiv_literal_map(a->as_LiteralMap(), b->as_LiteralMap());

  // Error, LspSelection, ToitdocReference, TokenNode, Parenthesis (already
  // unwrapped): fall through. Treat any unhandled matching kind as equal —
  // these are edge cases the formatter shouldn't be reshaping.
  return true;
}

} // namespace

bool ast_equivalent(Unit* a, Unit* b) {
  return equiv(a, b);
}

} // namespace toit::compiler
} // namespace toit
