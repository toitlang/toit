// Copyright (C) 2025 Toit contributors.
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

#include "format.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "ast.h"
#include "format_doc.h"
#include "format_trivia.h"
#include "sources.h"
#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

Expression* peel_parens(Expression* e) {
  while (e != null && e->is_Parenthesis()) {
    e = e->as_Parenthesis()->expression();
  }
  return e;
}

// Whether the inner of a Parenthesis wrapper is trivial enough that the
// parens are pure noise (`(x)` -> `x`). Anything with structure is the
// author's explicit grouping and is preserved.
bool is_trivial_inner(Expression* e) {
  if (e == null) return false;
  return e->is_Identifier()
      || e->is_LiteralNull()
      || e->is_LiteralUndefined()
      || e->is_LiteralBoolean()
      || e->is_LiteralInteger()
      || e->is_LiteralCharacter()
      || e->is_LiteralFloat()
      || e->is_LiteralString();
}

// Toit's parser builds `a and b and c` as `a and (b and c)`; assignment
// ops are right-assoc as well. Everything else is left-assoc.
bool is_right_assoc(Token::Kind kind) {
  int precedence = Token::precedence(kind);
  return precedence == PRECEDENCE_AND
      || precedence == PRECEDENCE_OR
      || precedence == PRECEDENCE_ASSIGNMENT;
}

bool is_bitwise(Token::Kind kind) {
  int precedence = Token::precedence(kind);
  return precedence == PRECEDENCE_BIT_SHIFT
      || precedence == PRECEDENCE_BIT_AND
      || precedence == PRECEDENCE_BIT_OR
      || precedence == PRECEDENCE_BIT_XOR;
}

// Once bitwise operators mix with different operators, readers stop
// trusting the precedence table; make the grouping explicit even where
// precedence wouldn't require parens. Same operator on both sides reads
// unambiguously as a chain.
bool needs_bitwise_clarity(Token::Kind parent_kind, Token::Kind child_kind) {
  bool parent_bitwise = is_bitwise(parent_kind);
  bool child_bitwise = is_bitwise(child_kind);
  if (!parent_bitwise && !child_bitwise) return false;
  // An assignment is a statement-level boundary; its RHS needs no
  // defensive parens (`x = a & b` reads fine).
  if (Token::precedence(parent_kind) == PRECEDENCE_ASSIGNMENT) return false;
  if (parent_kind == child_kind) return false;
  return true;
}

// Whether `e` contains a Call anywhere. A Binary call argument that
// embeds a Call needs parens in flat position: Toit's greedy Call
// parsing would otherwise absorb the rest of the outer argument list
// into the inner call.
bool contains_call(Expression* e) {
  if (e == null) return false;
  if (e->is_Call()) return true;
  if (e->is_Parenthesis()) return contains_call(e->as_Parenthesis()->expression());
  if (e->is_Unary()) return contains_call(e->as_Unary()->expression());
  if (e->is_Binary()) {
    Binary* binary = e->as_Binary();
    return contains_call(binary->left()) || contains_call(binary->right());
  }
  if (e->is_Dot()) return contains_call(e->as_Dot()->receiver());
  if (e->is_Index()) {
    Index* index = e->as_Index();
    if (contains_call(index->receiver())) return true;
    for (auto argument : index->arguments()) {
      if (contains_call(argument)) return true;
    }
    return false;
  }
  if (e->is_NamedArgument()) {
    return contains_call(e->as_NamedArgument()->expression());
  }
  return false;
}

// A call argument that carries a suite: a Block (`foo: body`), a Lambda
// (`foo:: body`), or a named argument whose value is one
// (`--if-absent=: body`). These render after the regular arguments,
// with the suite's body on indented lines.
bool is_blockish(Expression* argument) {
  if (argument->is_Block() || argument->is_Lambda()) return true;
  if (argument->is_NamedArgument()) {
    Expression* value = argument->as_NamedArgument()->expression();
    return value != null && (value->is_Block() || value->is_Lambda());
  }
  return false;
}

bool is_control_flow(Expression* e) {
  return e->is_If() || e->is_While() || e->is_For() || e->is_TryFinally();
}

// Rough token count of an expression; used to keep heavy suite bodies
// off their header's line regardless of width.
int token_count(Expression* e) {
  if (e == null) return 0;
  // Parens don't count: the formatter adds and removes them, and the
  // count must be stable across formatting runs (idempotence).
  if (e->is_Parenthesis()) {
    return token_count(e->as_Parenthesis()->expression());
  }
  if (e->is_Binary()) {
    Binary* binary = e->as_Binary();
    return token_count(binary->left()) + 1 + token_count(binary->right());
  }
  if (e->is_Unary()) return 1 + token_count(e->as_Unary()->expression());
  if (e->is_Dot()) return token_count(e->as_Dot()->receiver()) + 2;
  if (e->is_Index()) {
    Index* index = e->as_Index();
    int count = token_count(index->receiver()) + 2;
    for (auto argument : index->arguments()) count += token_count(argument);
    return count;
  }
  if (e->is_IndexSlice()) {
    IndexSlice* slice = e->as_IndexSlice();
    return token_count(slice->receiver()) + 3
        + token_count(slice->from()) + token_count(slice->to());
  }
  if (e->is_Call()) {
    Call* call = e->as_Call();
    int count = token_count(call->target());
    for (auto argument : call->arguments()) count += token_count(argument);
    return count;
  }
  if (e->is_NamedArgument()) {
    return 1 + token_count(e->as_NamedArgument()->expression());
  }
  if (e->is_Return()) return 1 + token_count(e->as_Return()->value());
  if (e->is_BreakContinue()) {
    return 1 + token_count(e->as_BreakContinue()->value());
  }
  if (e->is_DeclarationLocal()) {
    DeclarationLocal* declaration = e->as_DeclarationLocal();
    return 2 + token_count(declaration->type()) + token_count(declaration->value());
  }
  if (e->is_LiteralList() || e->is_LiteralSet() || e->is_LiteralByteArray()) {
    auto elements = e->is_LiteralList() ? e->as_LiteralList()->elements()
        : e->is_LiteralSet() ? e->as_LiteralSet()->elements()
        : e->as_LiteralByteArray()->elements();
    int count = 2;
    for (auto element : elements) count += token_count(element);
    return count;
  }
  if (e->is_LiteralMap()) {
    LiteralMap* map = e->as_LiteralMap();
    int count = 2;
    for (int i = 0; i < map->keys().length(); i++) {
      count += token_count(map->keys()[i]) + 1 + token_count(map->values()[i]);
    }
    return count;
  }
  if (e->is_Block() || e->is_Lambda()) {
    Sequence* body = e->is_Block() ? e->as_Block()->body()
                                   : e->as_Lambda()->body();
    int count = 1;
    if (body != null) {
      for (auto statement : body->expressions()) count += token_count(statement);
    }
    return count;
  }
  // Identifiers, literals, interpolated strings, ...
  return 1;
}

// Whether `e` contains a Block or Lambda anywhere: inlining such a
// body stacks a second suite `:` onto the line.
bool contains_suite(Expression* e) {
  if (e == null) return false;
  if (e->is_Block() || e->is_Lambda()) return true;
  if (e->is_Parenthesis()) return contains_suite(e->as_Parenthesis()->expression());
  if (e->is_Unary()) return contains_suite(e->as_Unary()->expression());
  if (e->is_Binary()) {
    Binary* binary = e->as_Binary();
    return contains_suite(binary->left()) || contains_suite(binary->right());
  }
  if (e->is_Dot()) return contains_suite(e->as_Dot()->receiver());
  if (e->is_Index()) {
    Index* index = e->as_Index();
    if (contains_suite(index->receiver())) return true;
    for (auto argument : index->arguments()) {
      if (contains_suite(argument)) return true;
    }
    return false;
  }
  if (e->is_IndexSlice()) {
    IndexSlice* slice = e->as_IndexSlice();
    return contains_suite(slice->receiver())
        || contains_suite(slice->from())
        || contains_suite(slice->to());
  }
  if (e->is_Call()) {
    Call* call = e->as_Call();
    if (contains_suite(call->target())) return true;
    for (auto argument : call->arguments()) {
      if (contains_suite(argument)) return true;
    }
    return false;
  }
  if (e->is_NamedArgument()) {
    return contains_suite(e->as_NamedArgument()->expression());
  }
  if (e->is_Return()) return contains_suite(e->as_Return()->value());
  if (e->is_BreakContinue()) return contains_suite(e->as_BreakContinue()->value());
  if (e->is_DeclarationLocal()) {
    DeclarationLocal* declaration = e->as_DeclarationLocal();
    return contains_suite(declaration->value());
  }
  if (e->is_If()) {
    If* ternary = e->as_If();
    return contains_suite(ternary->expression())
        || contains_suite(ternary->yes())
        || contains_suite(ternary->no());
  }
  return false;
}

// A single `return` or `throw` statement: a terminal one-liner that
// reads well inline, so it gets a small extra width allowance.
bool is_return_or_throw(Expression* statement_node) {
  Expression* s = peel_parens(statement_node);
  if (s == null) return false;
  if (s->is_Return()) return true;
  if (s->is_Call()) {
    Expression* target = peel_parens(s->as_Call()->target());
    return target != null && target->is_Identifier()
        && strcmp(target->as_Identifier()->data().c_str(), "throw") == 0;
  }
  return false;
}

class Lowering {
 public:
  Lowering(Unit* unit, List<Scanner::Comment> comments, const FormatStyle& style)
      : unit_(unit)
      , source_(unit->source())
      , text_(source_->text())
      , style_(style) {
    attach_trivia(unit, source_, comments, &trivia_);
  }

  std::string run() {
    Doc* doc = unit_doc();
    return print_doc(doc, 0, style_);
  }

 private:
  Unit* unit_;
  Source* source_;
  const uint8* text_;
  FormatStyle style_;
  TriviaTable trivia_;
  DocBuilder b_;

  // ------------------------------------------------------- helpers

  int pos(Source::Position p) const { return source_->offset_in_source(p); }
  int start(Node* node) const { return pos(node->full_range().from()); }
  int end(Node* node) const { return pos(node->full_range().to()); }

  std::string bytes(int from, int to) const {
    return std::string(reinterpret_cast<const char*>(text_) + from, to - from);
  }

  std::string node_bytes(Node* node) const {
    return bytes(start(node), end(node));
  }

  // Source bytes of a frozen node. Some ranges (empty Sequence) extend
  // past the last token into trailing whitespace; trim it so verbatim
  // reproduction doesn't accrete newlines across formatting runs.
  std::string frozen_bytes(Node* node) const {
    std::string content = node_bytes(node);
    while (!content.empty()) {
      char last = content.back();
      if (last == ' ' || last == '\t' || last == '\n' || last == '\r') {
        content.pop_back();
      } else {
        break;
      }
    }
    return content;
  }

  int column_of(int offset) const {
    int line_start = offset;
    while (line_start > 0 && text_[line_start - 1] != '\n') line_start--;
    return offset - line_start;
  }

  // Source bytes of a node, as a doc. Multi-line content (multi-line
  // strings and string interpolations) becomes pinned verbatim text:
  // the bytes are content, never re-indented.
  Doc* node_text(Node* node) {
    std::string content = node_bytes(node);
    if (content.find('\n') != std::string::npos) {
      return b_.verbatim(std::move(content), -1);
    }
    return b_.text(std::move(content));
  }

  int capped_blanks(int blanks) const {
    return blanks > style_.max_blank_lines ? style_.max_blank_lines : blanks;
  }

  bool has_comments(Node* node) const {
    const NodeTrivia* trivia = trivia_.find(node);
    return trivia != null
        && (!trivia->leading.empty() || !trivia->trailing.empty()
            || trivia->frozen);
  }

  // The inline-suite budget for a construct whose body is `body`.
  int suite_budget(Sequence* body) const {
    if (body != null && body->expressions().length() == 1
        && is_return_or_throw(body->expressions().first())) {
      return style_.inline_suite_width + style_.inline_return_throw_bonus;
    }
    return style_.inline_suite_width;
  }

  // The body sequence of a Block / Lambda argument (possibly behind a
  // NamedArgument).
  Sequence* blockish_body(Expression* argument) const {
    Expression* value = argument;
    if (value->is_NamedArgument()) value = value->as_NamedArgument()->expression();
    if (value == null) return null;
    if (value->is_Block()) return value->as_Block()->body();
    if (value->is_Lambda()) return value->as_Lambda()->body();
    return null;
  }

  // ------------------------------------------------------- trivia

  Doc* comment_doc(const CommentTrivia& comment) {
    if (comment.spans_lines) {
      // Interior lines of a multi-line comment follow the comment's
      // own movement.
      return b_.verbatim(comment.text, comment.original_column);
    }
    return b_.text(comment.text);
  }

  // Trailing (end-of-line) comments of a node, rendered after it.
  // `//` comments end their line, so the surrounding list must render
  // broken.
  Doc* trailing_trivia(Node* node) {
    const NodeTrivia* trivia = trivia_.find(node);
    if (trivia == null || trivia->trailing.empty()) return b_.nil();
    std::vector<Doc*> docs;
    for (auto& comment : trivia->trailing) {
      bool glued = comment.attached && comment.is_multiline
          && !comment.spans_lines;
      if (!glued) {
        docs.push_back(b_.text(std::string(style_.trailing_comment_gap, ' ')));
      }
      docs.push_back(comment_doc(comment));
      if (!comment.is_multiline || comment.spans_lines) {
        docs.push_back(b_.break_parent());
      }
    }
    return b_.concat(std::move(docs));
  }

  // A child in a hardline-separated list (unit declarations, class
  // members, body statements): preserved blank lines, leading
  // comments, the child itself, trailing comments. `first_entity`
  // tracks whether anything has been emitted on the list's first line
  // yet. `trim_leading_blanks` drops blank lines before the first
  // entity (start of file).
  void append_list_child(std::vector<Doc*>* docs,
                         Node* child,
                         Doc* child_doc,
                         bool* first_entity,
                         bool trim_leading_blanks) {
    const NodeTrivia* trivia = trivia_.find(child);
    auto separate = [&](int blanks) {
      blanks = capped_blanks(blanks);
      if (*first_entity) {
        if (!trim_leading_blanks && blanks > 0) {
          for (int i = 0; i < blanks; i++) docs->push_back(b_.hardline());
        }
        *first_entity = false;
      } else {
        for (int i = 0; i < blanks + 1; i++) docs->push_back(b_.hardline());
      }
    };
    if (trivia != null) {
      for (auto& comment : trivia->leading) {
        separate(comment.blank_lines_before);
        docs->push_back(comment_doc(comment));
      }
    }
    separate(trivia == null ? 0 : trivia->blank_lines_before);
    docs->push_back(child_doc);
    docs->push_back(trailing_trivia(child));
  }

  void append_dangling(std::vector<Doc*>* docs, Node* owner) {
    const NodeTrivia* trivia = trivia_.find(owner);
    if (trivia == null) return;
    for (auto& comment : trivia->dangling) {
      for (int i = 0; i < capped_blanks(comment.blank_lines_before) + 1; i++) {
        docs->push_back(b_.hardline());
      }
      docs->push_back(comment_doc(comment));
    }
  }

  // ------------------------------------------------------- expressions

  // `outer` is the precedence of the enclosing operator
  // (PRECEDENCE_NONE at statement level and at other positions the
  // parser treats as full-expression boundaries).
  Doc* expr(Expression* e, int outer) {
    // Preserve the author's grouping parens around non-trivial
    // sub-expressions; peel `(x)` around bare identifiers/literals.
    while (e != null && e->is_Parenthesis()) {
      Expression* inner = e->as_Parenthesis()->expression();
      if (is_trivial_inner(peel_parens(inner))) {
        e = peel_parens(inner);
      } else if (inner->is_Block() || inner->is_Lambda()) {
        return paren_block(inner);
      } else {
        return b_.concat({b_.text("("),
                          expr(inner, PRECEDENCE_NONE),
                          b_.text(")")});
      }
    }
    if (e->is_Binary()) return binary(e->as_Binary(), outer);
    if (e->is_Unary()) return unary(e->as_Unary(), outer);
    if (e->is_Dot()) {
      Dot* dot = e->as_Dot();
      return b_.concat({receiver(dot->receiver()),
                        b_.text("."),
                        node_text(dot->name())});
    }
    if (e->is_Index()) {
      Index* index = e->as_Index();
      std::vector<Doc*> docs;
      docs.push_back(receiver(index->receiver()));
      docs.push_back(b_.text("["));
      // Inside `[...]` the precedence context resets: the brackets are
      // a delimited construct.
      for (int i = 0; i < index->arguments().length(); i++) {
        if (i > 0) docs.push_back(b_.text(", "));
        docs.push_back(expr(index->arguments()[i], PRECEDENCE_NONE));
      }
      docs.push_back(b_.text("]"));
      return b_.concat(std::move(docs));
    }
    if (e->is_IndexSlice()) {
      IndexSlice* slice = e->as_IndexSlice();
      std::vector<Doc*> docs;
      docs.push_back(receiver(slice->receiver()));
      docs.push_back(b_.text("["));
      if (slice->from() != null) docs.push_back(expr(slice->from(), PRECEDENCE_NONE));
      docs.push_back(b_.text(".."));
      if (slice->to() != null) docs.push_back(expr(slice->to(), PRECEDENCE_NONE));
      docs.push_back(b_.text("]"));
      return b_.concat(std::move(docs));
    }
    if (e->is_Call()) return call(e->as_Call(), outer);
    if (e->is_NamedArgument()) return named_argument(e->as_NamedArgument(), false);
    if (e->is_Nullable()) {
      return b_.concat({expr(e->as_Nullable()->type(), PRECEDENCE_POSTFIX),
                        b_.text("?")});
    }
    if (e->is_Return()) {
      Return* ret = e->as_Return();
      if (ret->value() == null) return b_.text("return");
      return b_.concat({b_.text("return "),
                        expr(ret->value(), PRECEDENCE_NONE)});
    }
    if (e->is_BreakContinue()) {
      BreakContinue* bc = e->as_BreakContinue();
      std::vector<Doc*> docs;
      docs.push_back(b_.text(bc->is_break() ? "break" : "continue"));
      if (bc->label() != null) {
        docs.push_back(b_.text("."));
        docs.push_back(node_text(bc->label()));
      }
      if (bc->value() != null) {
        docs.push_back(b_.text(" "));
        docs.push_back(expr(bc->value(), PRECEDENCE_NONE));
      }
      return b_.concat(std::move(docs));
    }
    if (e->is_DeclarationLocal()) {
      DeclarationLocal* declaration = e->as_DeclarationLocal();
      std::vector<Doc*> docs;
      docs.push_back(node_text(declaration->name()));
      if (declaration->type() != null) {
        docs.push_back(b_.text("/"));
        docs.push_back(expr(declaration->type(), PRECEDENCE_POSTFIX));
      }
      if (declaration->value() != null) {
        docs.push_back(b_.text(std::string(" ")
                               + Token::symbol(declaration->kind()).c_str()
                               + " "));
        // `x := ?` declares without initializing.
        if (declaration->value()->is_LiteralUndefined()) {
          docs.push_back(b_.text("?"));
        } else {
          // The RHS of an assignment-precedence operator is a
          // statement-level boundary.
          docs.push_back(expr(declaration->value(), PRECEDENCE_NONE));
        }
      }
      return b_.concat(std::move(docs));
    }
    if (e->is_LiteralList()) {
      return collection(e->as_LiteralList()->elements(), "[", "]", e);
    }
    if (e->is_LiteralByteArray()) {
      return collection(e->as_LiteralByteArray()->elements(), "#[", "]", e);
    }
    if (e->is_LiteralSet()) {
      return collection(e->as_LiteralSet()->elements(), "{", "}", e);
    }
    if (e->is_LiteralMap()) return map_literal(e->as_LiteralMap());
    if (e->is_If()) return ternary(e->as_If(), outer);
    // Identifiers, literals, interpolated strings, Error nodes: source
    // bytes are the canonical rendering (escapes, radix, formats).
    return node_text(e);
  }

  // The conditional operator. The parser builds it as an If whose
  // branches are bare expressions (a statement `if` has Sequence
  // branches). The condition parses below `?`; the branches are full
  // expressions whose `:` is protected by the parser's delimiter
  // machinery, so bare calls in all three positions are safe.
  Doc* ternary(If* if_node, int outer) {
    // Broken form per the corpus: condition on the first line, `? yes`
    // and `: no` on continuation lines.
    Doc* result = b_.group(b_.concat(
        {expr(if_node->expression(), PRECEDENCE_CONDITIONAL),
         b_.indent(style_.continuation_step,
                   b_.concat({b_.line(),
                              b_.text("? "),
                              expr(if_node->yes(), PRECEDENCE_NONE),
                              b_.line(),
                              b_.text(": "),
                              expr(if_node->no(), PRECEDENCE_NONE)}))}));
    if (outer == PRECEDENCE_NONE) return result;
    return b_.concat({b_.text("("), result, b_.text(")")});
  }

  // The receiver of a Dot / Index / IndexSlice. Parens around a
  // receiver are semantic (`Foo.bar` is a static lookup, `(Foo).bar`
  // a member access on the class object) and resolution would be
  // needed to canonicalise them — preserve exactly what the author
  // wrote (collapsed to one pair).
  Doc* receiver(Expression* e) {
    if (e == null) return b_.nil();
    if (e->is_Parenthesis()) {
      Expression* inner = peel_parens(e);
      return b_.concat({b_.text("("),
                        expr(inner, PRECEDENCE_NONE),
                        b_.text(")")});
    }
    return expr(e, PRECEDENCE_POSTFIX);
  }

  Doc* unary(Unary* u, int outer) {
    // Only the keyword `not` needs defensive parens in a non-NONE
    // context (`foo not x` is a parse error; `foo (not x)` is fine).
    // Punctuation unaries bind tightly. `not`'s operand is parsed via
    // parse_call directly, so it sits at a statement-level boundary.
    bool parens = u->kind() == Token::NOT && outer != PRECEDENCE_NONE;
    std::vector<Doc*> docs;
    if (parens) docs.push_back(b_.text("("));
    const char* op = Token::symbol(u->kind()).c_str();
    if (u->prefix()) {
      docs.push_back(b_.text(op));
      if (u->kind() == Token::NOT) docs.push_back(b_.text(" "));
      int operand_prec = u->kind() == Token::NOT ? PRECEDENCE_NONE
                                                 : PRECEDENCE_POSTFIX;
      docs.push_back(expr(u->expression(), operand_prec));
    } else {
      docs.push_back(expr(u->expression(), PRECEDENCE_POSTFIX));
      docs.push_back(b_.text(op));
    }
    if (parens) docs.push_back(b_.text(")"));
    return b_.concat(std::move(docs));
  }

  // A Binary operand, with the bitwise-clarity override.
  Doc* binary_operand(Expression* child, int operand_prec, Token::Kind parent_kind) {
    if (child != null && !child->is_Parenthesis() && child->is_Binary()) {
      Token::Kind child_kind = child->as_Binary()->kind();
      if (needs_bitwise_clarity(parent_kind, child_kind)) {
        return b_.concat({b_.text("("),
                          expr(child, PRECEDENCE_NONE),
                          b_.text(")")});
      }
    }
    return expr(child, operand_prec);
  }

  // Collects the operands of a same-operator chain in left-to-right
  // order. Parenthesised or different-operator children stay single
  // operands.
  void flatten_chain(Binary* binary, Token::Kind op, std::vector<Expression*>* operands) {
    if (is_right_assoc(op)) {
      operands->push_back(binary->left());
      Expression* right = binary->right();
      if (right != null && !right->is_Parenthesis()
          && right->is_Binary() && right->as_Binary()->kind() == op) {
        flatten_chain(right->as_Binary(), op, operands);
      } else {
        operands->push_back(right);
      }
    } else {
      Expression* left = binary->left();
      if (left != null && !left->is_Parenthesis()
          && left->is_Binary() && left->as_Binary()->kind() == op) {
        flatten_chain(left->as_Binary(), op, operands);
      } else {
        operands->push_back(left);
      }
      operands->push_back(binary->right());
    }
  }

  Doc* binary(Binary* binary, int outer) {
    Token::Kind kind = binary->kind();
    int precedence = Token::precedence(kind);
    bool parens = precedence <= outer && outer != PRECEDENCE_NONE;

    bool right_assoc = is_right_assoc(kind);
    int left_prec = right_assoc ? precedence : precedence - 1;
    int right_prec = right_assoc ? precedence - 1 : precedence;
    // The RHS of an assignment is a statement-level boundary: nothing
    // to its right can bind into it (`x = foo a b` needs no parens).
    if (precedence == PRECEDENCE_ASSIGNMENT) right_prec = PRECEDENCE_NONE;
    // `or` / `and` parse each operand via parse_call directly: both
    // sides are statement-level boundaries.
    if (precedence == PRECEDENCE_OR || precedence == PRECEDENCE_AND) {
      left_prec = PRECEDENCE_NONE;
      right_prec = PRECEDENCE_NONE;
    }

    // Assignment-shaped binaries don't participate in chain breaking;
    // the break opportunity lives in the RHS (a call or collection
    // breaks by itself).
    if (precedence == PRECEDENCE_ASSIGNMENT) {
      std::vector<Doc*> docs;
      if (parens) docs.push_back(b_.text("("));
      docs.push_back(binary_operand(binary->left(), left_prec, kind));
      docs.push_back(b_.text(std::string(" ") + Token::symbol(kind).c_str() + " "));
      docs.push_back(binary_operand(binary->right(), right_prec, kind));
      if (parens) docs.push_back(b_.text(")"));
      return b_.concat(std::move(docs));
    }

    // A same-operator chain is one break unit: flat
    // `a + b + c`, or broken with the operator leading each
    // continuation line. Leading operators keep the re-parsed nesting
    // identical for left-assoc chains (an at-newline RHS would parse
    // as a full expression and right-nest); trailing operators are
    // only safe for right-assoc ones, so leading is used uniformly.
    std::vector<Expression*> operands;
    flatten_chain(binary, kind, &operands);

    std::vector<Doc*> chain;
    int edge_prec = right_assoc ? right_prec : left_prec;
    int interior_prec = precedence;  // Chain-interior operands.
    for (size_t i = 0; i < operands.size(); i++) {
      bool first = i == 0;
      bool last = i + 1 == operands.size();
      int operand_prec;
      if (right_assoc) {
        operand_prec = last ? edge_prec : (first ? left_prec : left_prec);
      } else {
        operand_prec = first ? edge_prec : (last ? right_prec : interior_prec);
      }
      if (!first) {
        chain.push_back(b_.line());
        chain.push_back(b_.text(std::string(Token::symbol(kind).c_str()) + " "));
      }
      chain.push_back(chain_operand(operands[i], operand_prec, kind));
    }

    Doc* chain_doc = chain.size() == 1
        ? chain[0]
        : b_.group(b_.concat({chain[0],
                              b_.indent(style_.continuation_step,
                                        b_.concat(std::vector<Doc*>(
                                            chain.begin() + 1, chain.end())))}));
    if (!parens) return chain_doc;
    return b_.concat({b_.text("("), chain_doc, b_.text(")")});
  }

  // A chain operand. In a mixed `and`/`or` chain, a nested logical
  // chain stays bare while it renders on one line (the parse is
  // unambiguous and `foo and bar or gee` reads fine), but gets parens
  // the moment it breaks: its continuation lines would sit at the same
  // indent as the outer chain's, hiding the nesting from the reader.
  // The outer chain's break points are tried first (the nested group
  // re-fits after the outer breaks), so the parenthesised form only
  // appears when the nested chain alone is too wide.
  Doc* chain_operand(Expression* operand, int operand_prec, Token::Kind chain_kind) {
    int chain_prec = Token::precedence(chain_kind);
    bool logical_chain = chain_prec == PRECEDENCE_OR || chain_prec == PRECEDENCE_AND;
    if (logical_chain && operand != null && !operand->is_Parenthesis()
        && operand->is_Binary()) {
      int operand_op_prec = Token::precedence(operand->as_Binary()->kind());
      if (operand_op_prec == PRECEDENCE_OR || operand_op_prec == PRECEDENCE_AND) {
        return nested_logical_chain(operand->as_Binary());
      }
    }
    return binary_operand(operand, operand_prec, chain_kind);
  }

  Doc* nested_logical_chain(Binary* binary_node) {
    Token::Kind kind = binary_node->kind();
    std::vector<Expression*> operands;
    flatten_chain(binary_node, kind, &operands);
    std::vector<Doc*> chain;
    for (size_t i = 0; i < operands.size(); i++) {
      if (i > 0) {
        chain.push_back(b_.line());
        chain.push_back(b_.text(std::string(Token::symbol(kind).c_str()) + " "));
      }
      // Both operand positions of `and` / `or` are statement-level
      // boundaries.
      chain.push_back(chain_operand(operands[i], PRECEDENCE_NONE, kind));
    }
    return b_.group(b_.concat({b_.if_broken(b_.text("("), b_.nil()),
                               chain[0],
                               b_.indent(style_.continuation_step,
                                         b_.concat(std::vector<Doc*>(
                                             chain.begin() + 1, chain.end()))),
                               b_.if_broken(b_.text(")"), b_.nil())}));
  }

  Doc* named_argument(NamedArgument* argument, bool newline_position) {
    std::vector<Doc*> docs;
    docs.push_back(b_.text(argument->inverted() ? "--no-" : "--"));
    docs.push_back(node_text(argument->name()));
    Expression* value = argument->expression();
    if (value != null) {
      docs.push_back(b_.text("="));
      // On its own continuation line the value is parsed as a full
      // expression; on a shared line it is not.
      docs.push_back(expr(value, newline_position ? PRECEDENCE_NONE
                                                  : PRECEDENCE_POSTFIX));
    }
    return b_.concat(std::move(docs));
  }

  // A call argument sharing a line with other call tokens. Parsed at
  // assignment precedence; Toit's greedy Call makes inner calls and
  // multi-arg binaries ambiguous, so those get parens.
  Doc* call_argument_flat(Expression* argument, bool multi_arg) {
    if (argument->is_NamedArgument()) {
      return named_argument(argument->as_NamedArgument(), false);
    }
    Expression* inner = peel_parens(argument);
    if (inner != null && inner->is_Binary()
        && Token::precedence(inner->as_Binary()->kind()) != PRECEDENCE_ASSIGNMENT) {
      Token::Kind kind = inner->as_Binary()->kind();
      int precedence = Token::precedence(kind);
      bool must_paren = style_.paren_binary_arguments
          || precedence <= PRECEDENCE_ASSIGNMENT
          || contains_call(inner)
          || multi_arg;
      if (!must_paren) return expr(inner, PRECEDENCE_NONE);
      return b_.concat({b_.text("("),
                        expr(inner, PRECEDENCE_NONE),
                        b_.text(")")});
    }
    if (inner != null && inner->is_Call()) {
      // Greedy Call: must be wrapped when sharing a line.
      return b_.concat({b_.text("("),
                        expr(inner, PRECEDENCE_NONE),
                        b_.text(")")});
    }
    return expr(argument, PRECEDENCE_POSTFIX);
  }

  // A regular (non-suite) call argument in a breakable position. The
  // legal parens differ by mode: on its own continuation line an
  // argument is parsed as a full expression (bare binaries and nested
  // calls are fine); on a shared line the flat rules apply.
  Doc* call_argument(Expression* argument, bool multi_arg) {
    if (argument->is_NamedArgument()) {
      NamedArgument* named = argument->as_NamedArgument();
      if (named->expression() == null) {
        return named_argument(named, false);
      }
      return b_.if_broken(named_argument(named, true),
                          named_argument(named, false));
    }
    Expression* inner = peel_parens(argument);
    // On its own continuation line an argument is a full expression:
    // binaries stay bare there even under paren_binary_arguments —
    // the line break already delimits the argument.
    bool differs_broken = inner != null
        && (inner->is_Call()
            || (inner->is_Binary()
                && Token::precedence(inner->as_Binary()->kind()) != PRECEDENCE_ASSIGNMENT));
    if (differs_broken) {
      return b_.if_broken(expr(inner, PRECEDENCE_NONE),
                          call_argument_flat(argument, multi_arg));
    }
    return call_argument_flat(argument, multi_arg);
  }

  // Block parameters: ` | x y/int |`.
  Doc* block_parameters(List<Parameter*> parameters) {
    if (parameters.is_empty()) return b_.nil();
    std::vector<Doc*> docs;
    docs.push_back(b_.text(" |"));
    for (auto p : parameters) {
      docs.push_back(b_.text(" "));
      docs.push_back(parameter(p));
    }
    docs.push_back(b_.text(" |"));
    return b_.concat(std::move(docs));
  }

  // The suite of a Block / Lambda argument: `: body` inline (single
  // statement, fits) or the body on indented lines. `intro` is `:` or
  // `::`, possibly preceded by `--name=`.
  Doc* block_suite(Doc* intro, Expression* blockish) {
    Expression* value = blockish;
    if (value->is_NamedArgument()) value = value->as_NamedArgument()->expression();
    Sequence* body = value->is_Block() ? value->as_Block()->body()
                                       : value->as_Lambda()->body();
    Doc* params = block_parameters(value->is_Block()
                                       ? value->as_Block()->parameters()
                                       : value->as_Lambda()->parameters());
    return b_.concat({intro, params, trailing_trivia(body),
                      suite_body(body, true)});
  }

  // A parenthesized block/lambda, `(: body)` — a block in argument
  // position. Broken form per the corpus: body at +indent_step from
  // the `(`, closing paren on its own line at the paren's column.
  Doc* paren_block(Expression* value) {
    Sequence* body = value->is_Block() ? value->as_Block()->body()
                                       : value->as_Lambda()->body();
    Doc* params = block_parameters(value->is_Block()
                                       ? value->as_Block()->parameters()
                                       : value->as_Lambda()->parameters());
    auto statements = body == null ? List<Expression*>() : body->expressions();
    return b_.group(b_.concat({b_.text(value->is_Block() ? "(:" : "(::"),
                               params,
                               trailing_trivia(body),
                               statements.is_empty() ? b_.nil()
                                                     : suite_body(body, true),
                               b_.if_broken(b_.concat({b_.hardline(), b_.text(")")}),
                                            b_.text(")"))}),
                    suite_budget(body));
  }

  Doc* block_suite_broken(Doc* intro, Expression* blockish) {
    Expression* value = blockish;
    if (value->is_NamedArgument()) value = value->as_NamedArgument()->expression();
    Sequence* body = value->is_Block() ? value->as_Block()->body()
                                       : value->as_Lambda()->body();
    Doc* params = block_parameters(value->is_Block()
                                       ? value->as_Block()->parameters()
                                       : value->as_Lambda()->parameters());
    return b_.concat({intro, params, trailing_trivia(body),
                      suite_body(body, false)});
  }

  // A suite body after its `:`: ` stmt` when the enclosing group is
  // flat (single simple statement), or the statements on their own
  // lines at +indent_step. The caller wraps a group around the whole
  // construct; a multi-statement body hardline-forces it broken.
  Doc* suite_body(Sequence* body, bool allow_inline) {
    auto statements = body == null ? List<Expression*>() : body->expressions();
    if (statements.is_empty()) return b_.nil();
    // A lone collection literal hugs the suite colon: `map:  {` with
    // the elements breaking internally (corpus shape).
    if (allow_inline && statements.length() == 1
        && !has_comments(statements.first())) {
      Expression* only = statements.first();
      if (only->is_LiteralList() || only->is_LiteralMap()
          || only->is_LiteralSet() || only->is_LiteralByteArray()) {
        return b_.concat({b_.text(" "), expr(only, PRECEDENCE_NONE)});
      }
    }
    bool inline_ok = allow_inline
        && statements.length() == 1
        && !is_control_flow(peel_parens(statements.first()))
        && !trivia_.is_frozen(statements.first())
        && token_count(statements.first()) <= style_.max_inline_suite_tokens
        && (style_.inline_nested_suites
            || !contains_suite(statements.first()));
    std::vector<Doc*> docs;
    bool first_entity = true;
    std::vector<Doc*> list;
    for (auto statement_node : statements) {
      append_list_child(&list, statement_node, statement(statement_node),
                        &first_entity, true);
    }
    append_dangling(&list, body);
    Doc* list_doc = b_.concat(std::move(list));
    if (inline_ok) {
      return b_.indent(style_.indent_step,
                       b_.concat({b_.line(), list_doc}));
    }
    return b_.indent(style_.indent_step,
                     b_.concat({b_.hardline(), b_.break_parent(), list_doc}));
  }

  Doc* call(Call* c, int outer) {
    // Toit's Call is greedy: emitted anywhere but a statement-level
    // boundary it must be parenthesised, or the re-parse absorbs the
    // surrounding context into the argument list.
    bool parens = outer != PRECEDENCE_NONE;

    auto arguments = c->arguments();
    int first_blockish = arguments.length();
    for (int i = 0; i < arguments.length(); i++) {
      if (is_blockish(arguments[i])) {
        first_blockish = i;
        break;
      }
    }
    // Suite arguments are syntactically last (anything after them
    // would parse into their bodies).

    int tail_count = arguments.length() - first_blockish;
    // A lone named suite (`foo key --if-absent=: 0`) is an argument
    // like any other: on the head's line when the head is flat, on its
    // own continuation line when the head breaks.
    bool named_suite_in_head = tail_count == 1
        && arguments[first_blockish]->is_NamedArgument();
    int head_args = named_suite_in_head ? arguments.length() : first_blockish;

    bool multi_arg = first_blockish >= 2;

    // The leading run of unbreakable positional arguments; used to
    // decide whether a final collection literal may hug the call.
    int glued_args = 0;
    std::vector<Doc*> glued_docs;
    while (glued_args < head_args
           && !arguments[glued_args]->is_NamedArgument()
           && !is_blockish(arguments[glued_args])
           && !has_comments(arguments[glued_args])) {
      Doc* doc = call_argument_flat(arguments[glued_args], multi_arg);
      if (doc_has_breakpoints(doc)) break;
      glued_docs.push_back(doc);
      glued_args++;
    }

    // A final collection literal hugs the call (`send-request_ CMD {`
    // and `client_.rest.select "roles" --filters=[` with the elements
    // breaking internally — brackets are delimited constructs, so the
    // call's indentation rules are suspended inside). Only when
    // everything before it is glued: a hug after a broken argument
    // list does not re-parse as the same call.
    Expression* hugged = null;
    if (!named_suite_in_head && glued_args == head_args - 1
        && tail_count == 0) {
      Expression* last_argument = arguments[head_args - 1];
      Expression* collection = last_argument;
      if (last_argument->is_NamedArgument()) {
        collection = last_argument->as_NamedArgument()->expression();
      }
      if (collection != null
          && (collection->is_LiteralList() || collection->is_LiteralMap()
              || collection->is_LiteralSet() || collection->is_LiteralByteArray())
          && !has_comments(last_argument)) {
        hugged = last_argument;
        head_args--;
      }
    }

    std::vector<Doc*> head;
    head.push_back(expr(c->target(), PRECEDENCE_POSTFIX));
    std::vector<Doc*> argument_docs;
    if (hugged != null) {
      // All preceding arguments are unbreakable; render them glued.
      for (auto doc : glued_docs) {
        head.push_back(b_.text(" "));
        head.push_back(doc);
      }
    } else {
      // Runs of positional arguments form a nested group: when the
      // call breaks, the run stays on the target's line (corpus shape:
      // `client_.post encoded` + named args on continuation lines) and
      // only breaks per-argument when the run itself is too wide.
      int i = 0;
      while (i < head_args) {
        Expression* argument = arguments[i];
        // Only the leading run glues to the target; a positional after
        // a named argument must take its own line (sharing the named
        // argument's line would parse into its value).
        bool positional_run = i == 0
            && !argument->is_NamedArgument()
            && !(named_suite_in_head && i == arguments.length() - 1);
        if (positional_run) {
          std::vector<Doc*> run;
          while (i < head_args && !arguments[i]->is_NamedArgument()
                 && !(named_suite_in_head && i == arguments.length() - 1)) {
            Expression* run_argument = arguments[i];
            const NodeTrivia* trivia = trivia_.find(run_argument);
            run.push_back(b_.line());
            if (trivia != null) {
              for (auto& comment : trivia->leading) {
                run.push_back(comment_doc(comment));
                run.push_back(b_.hardline());
              }
            }
            run.push_back(call_argument(run_argument, multi_arg));
            run.push_back(trailing_trivia(run_argument));
            i++;
          }
          argument_docs.push_back(b_.group(b_.concat(std::move(run))));
          continue;
        }
        const NodeTrivia* trivia = trivia_.find(argument);
        argument_docs.push_back(b_.line());
        if (trivia != null) {
          for (auto& comment : trivia->leading) {
            argument_docs.push_back(comment_doc(comment));
            argument_docs.push_back(b_.hardline());
          }
        }
        if (named_suite_in_head && i == arguments.length() - 1) {
          NamedArgument* named = argument->as_NamedArgument();
          Expression* value = named->expression();
          Doc* intro = b_.concat({b_.text(named->inverted() ? "--no-" : "--"),
                                  node_text(named->name()),
                                  b_.text(value->is_Block() ? "=:" : "=::")});
          argument_docs.push_back(b_.group(block_suite(intro, argument),
                                           suite_budget(blockish_body(argument))));
        } else {
          argument_docs.push_back(call_argument(argument, multi_arg));
        }
        argument_docs.push_back(trailing_trivia(argument));
        i++;
      }
    }
    bool has_breakable_arguments = !argument_docs.empty();
    if (has_breakable_arguments) {
      head.push_back(b_.indent(style_.continuation_step,
                               b_.concat(std::move(argument_docs))));
    }
    Doc* head_doc = has_breakable_arguments
        ? b_.group(b_.concat(std::move(head)))
        : b_.concat(std::move(head));

    std::vector<Doc*> docs;
    docs.push_back(head_doc);
    if (hugged != null) {
      docs.push_back(b_.text(" "));
      if (hugged->is_NamedArgument()) {
        NamedArgument* named = hugged->as_NamedArgument();
        docs.push_back(b_.text(named->inverted() ? "--no-" : "--"));
        docs.push_back(node_text(named->name()));
        docs.push_back(b_.text("="));
        docs.push_back(expr(named->expression(), PRECEDENCE_NONE));
      } else {
        docs.push_back(expr(hugged, PRECEDENCE_NONE));
      }
    }
    if (named_suite_in_head) {
      // Already rendered in the head.
    } else if (tail_count == 1 && is_blockish(arguments[first_blockish])) {
      // The classic trailing block: `foo a: body`, attached to the
      // head. The body's inline-vs-broken break binds to the
      // *statement's* group so the whole line is judged against the
      // inline-suite budget.
      Expression* argument = arguments[first_blockish];
      Doc* intro = b_.text(argument->is_Block() ? ":" : "::");
      docs.push_back(block_suite(intro, argument));
    } else if (tail_count > 1) {
      // From the first suite argument on, every argument goes on its
      // own continuation line: suites would swallow same-line
      // followers, and the parser requires one argument per line.
      // Each line is parsed as a full expression.
      for (int i = first_blockish; i < arguments.length(); i++) {
        Expression* argument = arguments[i];
        Doc* line_doc;
        if (is_blockish(argument)) {
          Doc* intro;
          if (argument->is_NamedArgument()) {
            NamedArgument* named = argument->as_NamedArgument();
            Expression* value = named->expression();
            intro = b_.concat({b_.text(named->inverted() ? "--no-" : "--"),
                               node_text(named->name()),
                               b_.text(value->is_Block() ? "=:" : "=::")});
          } else {
            intro = b_.text(argument->is_Block() ? ":" : "::");
          }
          line_doc = block_suite(intro, argument);
        } else if (argument->is_NamedArgument()) {
          line_doc = named_argument(argument->as_NamedArgument(), true);
        } else {
          line_doc = expr(argument, PRECEDENCE_NONE);
        }
        int line_budget = is_blockish(argument)
            ? suite_budget(blockish_body(argument))
            : style_.inline_suite_width;
        docs.push_back(b_.indent(style_.continuation_step,
                                 b_.concat({b_.hardline(),
                                            b_.group(line_doc, line_budget)})));
      }
    }

    // A call carrying a suite is one break unit judged against the
    // inline-suite budget: when the call's own extent exceeds it, the
    // suite body moves to its own line (the head group decides
    // argument wrapping independently). The group lives here, not at
    // statement level, so the decision is the same wherever the call
    // is embedded (statement, map value, argument).
    bool has_suite = tail_count > 0 || named_suite_in_head;
    Sequence* lone_suite_body = has_suite && arguments.length() - first_blockish == 1
        ? blockish_body(arguments[first_blockish])
        : null;
    Doc* result = has_suite
        ? b_.group(b_.concat(std::move(docs)), suite_budget(lone_suite_body))
        : b_.concat(std::move(docs));
    if (!parens) return result;
    return b_.concat({b_.text("("), result, b_.text(")")});
  }

  bool spans_lines(Node* node) const {
    int from = start(node);
    int to = end(node);
    for (int i = from; i < to; i++) {
      if (text_[i] == '\n') return true;
    }
    return false;
  }

  Doc* collection(List<Expression*> elements, const char* open, const char* close, Expression* owner) {
    if (elements.is_empty()) {
      return b_.text(std::string(open) + close);
    }
    std::vector<Doc*> inner;
    if (style_.keep_multiline_collections && spans_lines(owner)) {
      inner.push_back(b_.break_parent());
    }
    for (int i = 0; i < elements.length(); i++) {
      if (i > 0) inner.push_back(b_.line());
      bool last = i + 1 == elements.length();
      append_element(&inner, elements[i], expr(elements[i], PRECEDENCE_NONE), last);
    }
    append_collection_dangling(&inner, owner);
    return b_.group(b_.concat({b_.text(open),
                               b_.indent(style_.indent_step,
                                         b_.concat({b_.softline(),
                                                    b_.concat(std::move(inner))})),
                               b_.softline(),
                               b_.text(close)}));
  }

  // Comment lines between the last element and the closing bracket.
  void append_collection_dangling(std::vector<Doc*>* docs, Expression* owner) {
    const NodeTrivia* trivia = trivia_.find(owner);
    if (trivia == null) return;
    for (auto& comment : trivia->dangling) {
      docs->push_back(b_.hardline());
      docs->push_back(comment_doc(comment));
    }
  }

  // One collection element with its comments. The separating comma
  // goes before any trailing comment; the last element's comma only
  // appears in broken form.
  void append_element(std::vector<Doc*>* docs, Expression* element,
                      Doc* element_doc, bool last) {
    const NodeTrivia* trivia = trivia_.find(element);
    if (trivia != null) {
      for (int i = 0; i < capped_blanks(trivia->blank_lines_before); i++) {
        docs->push_back(b_.hardline());
      }
      for (auto& comment : trivia->leading) {
        docs->push_back(comment_doc(comment));
        docs->push_back(b_.hardline());
      }
    }
    docs->push_back(element_doc);
    docs->push_back(last ? b_.if_broken(b_.text(","), b_.nil()) : b_.text(","));
    docs->push_back(trailing_trivia(element));
  }

  Doc* map_literal(LiteralMap* map) {
    if (map->keys().is_empty()) return b_.text("{:}");
    std::vector<Doc*> inner;
    if (style_.keep_multiline_collections && spans_lines(map)) {
      inner.push_back(b_.break_parent());
    }
    for (int i = 0; i < map->keys().length(); i++) {
      if (i > 0) inner.push_back(b_.line());
      bool last = i + 1 == map->keys().length();
      Expression* key = map->keys()[i];
      Expression* value = map->values()[i];
      // Leading trivia sits on the key; trailing trivia on the value.
      const NodeTrivia* trivia = trivia_.find(key);
      if (trivia != null) {
        for (int blank = 0; blank < capped_blanks(trivia->blank_lines_before); blank++) {
          inner.push_back(b_.hardline());
        }
        for (auto& comment : trivia->leading) {
          inner.push_back(comment_doc(comment));
          inner.push_back(b_.hardline());
        }
      }
      inner.push_back(expr(key, PRECEDENCE_NONE));
      inner.push_back(b_.text(": "));
      inner.push_back(expr(value, PRECEDENCE_NONE));
      inner.push_back(last ? b_.if_broken(b_.text(","), b_.nil()) : b_.text(","));
      inner.push_back(trailing_trivia(value));
    }
    append_collection_dangling(&inner, map);
    return b_.group(b_.concat({b_.text("{"),
                               b_.indent(style_.indent_step,
                                         b_.concat({b_.softline(),
                                                    b_.concat(std::move(inner))})),
                               b_.softline(),
                               b_.text("}")}));
  }

  // ------------------------------------------------------- statements

  Doc* statement(Expression* statement_node) {
    if (trivia_.is_frozen(statement_node)) {
      int from = start(statement_node);
      return b_.verbatim(frozen_bytes(statement_node), column_of(from));
    }
    return statement_inner(statement_node);
  }

  Doc* statement_inner(Expression* statement_node) {
    if (statement_node->is_If()) {
      // A statement `if` has Sequence branches; the conditional
      // operator (`c ? a : b`) in statement position does not.
      If* if_node = statement_node->as_If();
      if (if_node->yes() != null && if_node->yes()->is_Sequence()) {
        return if_statement(if_node);
      }
      return expr(statement_node, PRECEDENCE_NONE);
    }
    if (statement_node->is_While()) return while_statement(statement_node->as_While());
    if (statement_node->is_For()) return for_statement(statement_node->as_For());
    if (statement_node->is_TryFinally()) {
      return try_statement(statement_node->as_TryFinally());
    }
    return expr(statement_node, PRECEDENCE_NONE);
  }

  // A control-flow branch: parser-wise a Sequence.
  Sequence* branch_sequence(Expression* branch) {
    if (branch == null) return null;
    if (branch->is_Sequence()) return branch->as_Sequence();
    return null;
  }

  Doc* if_statement(If* if_node) {
    int budget = suite_budget(branch_sequence(if_node->yes()));
    std::vector<Doc*> docs;
    const char* keyword = "if ";
    If* current = if_node;
    bool has_else = false;
    while (true) {
      Sequence* yes = branch_sequence(current->yes());
      docs.push_back(b_.text(keyword));
      docs.push_back(expr(current->expression(), PRECEDENCE_NONE));
      docs.push_back(b_.text(":"));
      if (yes != null) docs.push_back(trailing_trivia(yes));
      docs.push_back(suite_body(yes, !has_else && current->no() == null));
      Expression* no = current->no();
      if (no == null) break;
      has_else = true;
      docs.push_back(b_.hardline());
      docs.push_back(b_.break_parent());
      if (no->is_If()) {
        // The parser encodes `else if` as a directly nested If.
        keyword = "else if ";
        current = no->as_If();
        continue;
      }
      Sequence* else_body = branch_sequence(no);
      docs.push_back(b_.text("else:"));
      if (else_body != null) docs.push_back(trailing_trivia(else_body));
      docs.push_back(suite_body(else_body, false));
      break;
    }
    return b_.group(b_.concat(std::move(docs)), budget);
  }

  Doc* while_statement(While* while_node) {
    Sequence* body = branch_sequence(while_node->body());
    return b_.group(b_.concat({b_.text("while "),
                               expr(while_node->condition(), PRECEDENCE_NONE),
                               b_.text(":"),
                               body != null ? trailing_trivia(body) : b_.nil(),
                               suite_body(body, true)}),
                    suite_budget(body));
  }

  Doc* for_statement(For* for_node) {
    std::vector<Doc*> docs;
    docs.push_back(b_.text("for "));
    if (for_node->initializer() != null) {
      docs.push_back(expr(for_node->initializer(), PRECEDENCE_NONE));
    }
    docs.push_back(b_.text(";"));
    if (for_node->condition() != null) {
      docs.push_back(b_.text(" "));
      docs.push_back(expr(for_node->condition(), PRECEDENCE_NONE));
    }
    docs.push_back(b_.text(";"));
    if (for_node->update() != null) {
      docs.push_back(b_.text(" "));
      docs.push_back(expr(for_node->update(), PRECEDENCE_NONE));
    }
    docs.push_back(b_.text(":"));
    Sequence* body = branch_sequence(for_node->body());
    if (body != null) docs.push_back(trailing_trivia(body));
    docs.push_back(suite_body(body, true));
    return b_.group(b_.concat(std::move(docs)), suite_budget(body));
  }

  Doc* try_statement(TryFinally* try_node) {
    // try/finally is always broken; packing its chunks on one line is
    // never produced.
    std::vector<Doc*> docs;
    docs.push_back(b_.text("try:"));
    docs.push_back(trailing_trivia(try_node->body()));
    docs.push_back(suite_body(try_node->body(), false));
    docs.push_back(b_.hardline());
    docs.push_back(b_.text("finally:"));
    docs.push_back(block_parameters(try_node->handler_parameters()));
    docs.push_back(trailing_trivia(try_node->handler()));
    docs.push_back(suite_body(try_node->handler(), false));
    return b_.concat(std::move(docs));
  }

  // ------------------------------------------------------- declarations

  Doc* parameter(Parameter* p) {
    std::vector<Doc*> docs;
    if (p->is_block()) docs.push_back(b_.text("["));
    if (p->is_named()) docs.push_back(b_.text("--"));
    if (p->is_field_storing()) docs.push_back(b_.text("."));
    docs.push_back(node_text(p->name()));
    if (p->type() != null) {
      docs.push_back(b_.text("/"));
      docs.push_back(expr(p->type(), PRECEDENCE_POSTFIX));
    }
    if (p->default_value() != null) {
      docs.push_back(b_.text("="));
      docs.push_back(expr(p->default_value(), PRECEDENCE_POSTFIX));
    }
    if (p->is_block()) docs.push_back(b_.text("]"));
    return b_.concat(std::move(docs));
  }

  Doc* method_declaration(Method* method) {
    std::vector<Doc*> name_part;
    if (method->is_abstract()) name_part.push_back(b_.text("abstract "));
    if (method->is_static()) name_part.push_back(b_.text("static "));
    name_part.push_back(node_text(method->name_or_dot()));
    if (method->is_setter()) name_part.push_back(b_.text("="));

    Doc* return_part = b_.nil();
    if (method->return_type() != null) {
      return_part = b_.concat({b_.text(" -> "),
                               expr(method->return_type(), PRECEDENCE_POSTFIX)});
    }

    // Flat: `name p1 p2 -> T`. Broken: the return type stays on the
    // name's line, each parameter on its own continuation line.
    std::vector<Doc*> header;
    header.push_back(b_.concat(std::move(name_part)));
    header.push_back(b_.if_broken(return_part, b_.nil()));
    std::vector<Doc*> parameter_docs;
    for (auto p : method->parameters()) {
      const NodeTrivia* trivia = trivia_.find(p);
      parameter_docs.push_back(b_.line());
      if (trivia != null) {
        for (auto& comment : trivia->leading) {
          parameter_docs.push_back(comment_doc(comment));
          parameter_docs.push_back(b_.hardline());
        }
      }
      parameter_docs.push_back(parameter(p));
      parameter_docs.push_back(trailing_trivia(p));
    }
    if (!parameter_docs.empty()) {
      header.push_back(b_.indent(style_.continuation_step,
                                 b_.concat(std::move(parameter_docs))));
    }
    header.push_back(b_.if_broken(b_.nil(), return_part));

    Sequence* body = method->body();
    if (body == null) {
      // `abstract foo` / interface signature: no body, no colon.
      return b_.group(b_.concat(std::move(header)));
    }
    // The body-separator `:` follows the header group's mode: glued
    // when the header is flat (`foo a b:`), on its own line at the
    // method's indent when the parameters wrapped — the dedented colon
    // marks where the signature ends and the body begins.
    header.push_back(b_.if_broken(b_.concat({b_.hardline(), b_.text(":")}),
                                  b_.text(":")));
    Doc* header_doc = b_.group(b_.concat(std::move(header)));

    if (body->expressions().is_empty()) {
      // `foo:` with an empty body keeps its colon — possibly followed
      // by comment-only body lines.
      std::vector<Doc*> docs;
      docs.push_back(header_doc);
      const NodeTrivia* trivia = trivia_.find(method);
      if (trivia != null && !trivia->dangling.empty()) {
        std::vector<Doc*> comments;
        for (auto& comment : trivia->dangling) {
          for (int i = 0; i < capped_blanks(comment.blank_lines_before) + 1; i++) {
            comments.push_back(b_.hardline());
          }
          comments.push_back(comment_doc(comment));
        }
        docs.push_back(b_.indent(style_.indent_step, b_.concat(std::move(comments))));
      }
      return b_.concat(std::move(docs));
    }
    return b_.group(b_.concat({header_doc,
                               trailing_trivia(body),
                               suite_body(body, true)}),
                    suite_budget(body));
  }

  Doc* field_declaration(Field* field) {
    std::vector<Doc*> docs;
    if (field->is_static()) docs.push_back(b_.text("static "));
    if (field->is_abstract()) docs.push_back(b_.text("abstract "));
    docs.push_back(node_text(field->name()));
    if (field->type() != null) {
      docs.push_back(b_.text("/"));
      docs.push_back(expr(field->type(), PRECEDENCE_POSTFIX));
    }
    if (field->initializer() != null) {
      docs.push_back(b_.text(field->is_final() ? " ::= " : " := "));
      if (field->initializer()->is_LiteralUndefined()) {
        docs.push_back(b_.text("?"));
      } else {
        docs.push_back(expr(field->initializer(), PRECEDENCE_NONE));
      }
    }
    return b_.concat(std::move(docs));
  }

  Doc* class_declaration(Class* klass) {
    std::vector<Doc*> header;
    if (klass->has_abstract_modifier()) header.push_back(b_.text("abstract "));
    switch (klass->kind()) {
      case Class::CLASS: header.push_back(b_.text("class ")); break;
      case Class::INTERFACE: header.push_back(b_.text("interface ")); break;
      case Class::MONITOR: header.push_back(b_.text("monitor ")); break;
      case Class::MIXIN: header.push_back(b_.text("mixin ")); break;
    }
    header.push_back(node_text(klass->name()));
    std::vector<Doc*> clauses;
    if (klass->super() != null) {
      clauses.push_back(b_.line());
      clauses.push_back(b_.concat({b_.text("extends "),
                                   expr(klass->super(), PRECEDENCE_POSTFIX)}));
    }
    if (!klass->mixins().is_empty()) {
      clauses.push_back(b_.line());
      std::vector<Doc*> with_clause;
      with_clause.push_back(b_.text("with"));
      for (auto mixin : klass->mixins()) {
        with_clause.push_back(b_.text(" "));
        with_clause.push_back(expr(mixin, PRECEDENCE_POSTFIX));
      }
      clauses.push_back(b_.concat(std::move(with_clause)));
    }
    if (!klass->interfaces().is_empty()) {
      clauses.push_back(b_.line());
      std::vector<Doc*> implements_clause;
      implements_clause.push_back(b_.text("implements"));
      for (auto interface : klass->interfaces()) {
        implements_clause.push_back(b_.text(" "));
        implements_clause.push_back(expr(interface, PRECEDENCE_POSTFIX));
      }
      clauses.push_back(b_.concat(std::move(implements_clause)));
    }
    if (!clauses.empty()) {
      header.push_back(b_.indent(style_.continuation_step,
                                 b_.concat(std::move(clauses))));
    }
    header.push_back(b_.text(":"));
    Doc* header_doc = b_.group(b_.concat(std::move(header)));

    // Trailing trivia of the class itself ("after the last member") is
    // rendered by the enclosing declaration list; the header line's
    // EOL comment lives on the name node.
    auto members = klass->members();
    if (members.is_empty()) {
      return b_.concat({header_doc, trailing_trivia(klass->name())});
    }
    std::vector<Doc*> body;
    bool first_entity = false;  // The header line is already content.
    for (auto member : members) {
      append_list_child(&body, member, declaration(member), &first_entity, false);
    }
    append_dangling(&body, klass);
    return b_.concat({header_doc,
                      trailing_trivia(klass->name()),
                      b_.indent(style_.indent_step, b_.concat(std::move(body)))});
  }

  Doc* import_declaration(Import* import) {
    std::vector<Doc*> docs;
    docs.push_back(b_.text("import "));
    if (import->is_relative()) {
      docs.push_back(b_.text(std::string(import->dot_outs() + 1, '.')));
    }
    for (int i = 0; i < import->segments().length(); i++) {
      if (i > 0) docs.push_back(b_.text("."));
      docs.push_back(node_text(import->segments()[i]));
    }
    if (import->prefix() != null) {
      docs.push_back(b_.text(" as "));
      docs.push_back(node_text(import->prefix()));
    } else if (import->show_all()) {
      docs.push_back(b_.text(" show *"));
    } else if (!import->show_identifiers().is_empty()) {
      docs.push_back(b_.text(" show"));
      for (auto identifier : import->show_identifiers()) {
        docs.push_back(b_.text(" "));
        docs.push_back(node_text(identifier));
      }
    }
    return b_.concat(std::move(docs));
  }

  Doc* export_declaration(Export* export_node) {
    std::vector<Doc*> docs;
    docs.push_back(b_.text("export"));
    if (export_node->export_all()) {
      docs.push_back(b_.text(" *"));
    } else {
      for (auto identifier : export_node->identifiers()) {
        docs.push_back(b_.text(" "));
        docs.push_back(node_text(identifier));
      }
    }
    return b_.concat(std::move(docs));
  }

  Doc* declaration(Node* node) {
    if (trivia_.is_frozen(node)) {
      return b_.verbatim(frozen_bytes(node), column_of(start(node)));
    }
    if (node->is_Class()) return class_declaration(node->as_Class());
    if (node->is_Method()) return method_declaration(node->as_Method());
    if (node->is_Field()) return field_declaration(node->as_Field());
    if (node->is_Import()) return import_declaration(node->as_Import());
    if (node->is_Export()) return export_declaration(node->as_Export());
    // Anything unexpected: reproduce the source bytes.
    return b_.verbatim(node_bytes(node), column_of(start(node)));
  }

  Doc* unit_doc() {
    std::vector<Node*> children;
    for (auto import : unit_->imports()) children.push_back(import);
    for (auto export_node : unit_->exports()) children.push_back(export_node);
    for (auto decl : unit_->declarations()) children.push_back(decl);
    std::sort(children.begin(), children.end(), [&](Node* a, Node* b) {
      return start(a) < start(b);
    });

    std::vector<Doc*> docs;
    bool first_entity = true;
    for (auto child : children) {
      append_list_child(&docs, child, declaration(child), &first_entity, true);
    }
    append_dangling(&docs, unit_);
    docs.push_back(b_.hardline());  // Files end with a newline.
    return b_.concat(std::move(docs));
  }
};

} // anonymous namespace

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size,
                   const FormatStyle& style) {
  FormatStyle effective = style;
  // Experiment scaffolding for style calibration; remove once the
  // style table is settled.
  if (const char* width = getenv("TOIT_FORMAT_EXP_INLINE_WIDTH")) {
    effective.inline_suite_width = atoi(width);
  }
  if (const char* tokens = getenv("TOIT_FORMAT_EXP_INLINE_TOKENS")) {
    effective.max_inline_suite_tokens = atoi(tokens);
  }
  if (const char* bonus = getenv("TOIT_FORMAT_EXP_RETURN_THROW_BONUS")) {
    effective.inline_return_throw_bonus = atoi(bonus);
  }
  if (getenv("TOIT_FORMAT_EXP_NO_NESTED_SUITE_INLINE") != null) {
    effective.inline_nested_suites = false;
  }
  if (getenv("TOIT_FORMAT_EXP_PAREN_BINARY_ARGS") != null) {
    effective.paren_binary_arguments = true;
  }
  Lowering lowering(unit, comments, effective);
  std::string formatted = lowering.run();
  *formatted_size = formatted.size();
  uint8* result = unvoid_cast<uint8*>(malloc(formatted.size() + 1));
  memcpy(result, formatted.data(), formatted.size());
  result[formatted.size()] = '\0';
  return result;
}

} // namespace toit::compiler
} // namespace toit
