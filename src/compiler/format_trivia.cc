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

#include "format_trivia.h"

#include <algorithm>

namespace toit {
namespace compiler {

using namespace ast;

void TriviaTable::mark_emitted(int id) {
  ASSERT(id >= 0 && id < static_cast<int>(emitted_.size()));
  if (emitted_[id]) {
    duplicate_emission_ = true;
    if (getenv("TOIT_FORMAT_DEBUG_TRIVIA") != null) {
      fprintf(stderr, "duplicate comment %d at [%d, %d)\n",
              id, comment_ranges_[id].first, comment_ranges_[id].second);
    }
  } else {
    emitted_[id] = true;
  }
}

bool TriviaTable::all_comments_emitted() const {
  if (duplicate_emission_) return false;
  for (int id = 0; id < static_cast<int>(emitted_.size()); id++) {
    if (emitted_[id]) continue;
    if (getenv("TOIT_FORMAT_DEBUG_TRIVIA") != null) {
      fprintf(stderr, "unemitted comment %d at [%d, %d)\n",
              id, comment_ranges_[id].first, comment_ranges_[id].second);
    }
    return false;
  }
  return true;
}

// Routes comments to AST nodes by walking the tree in source order,
// mirroring the printer's structure. Every list the printer can render
// comments into is a "slot list": unit declarations, class members,
// body statements, call arguments, collection elements, parameters.
//
// For each gap between slot children:
//   - a comment with code before it on its own line is trailing trivia
//     of the previous child (EOL comments),
//   - any other comment is leading trivia of the next child (or
//     dangling trivia of the list owner when there is no next child).
//
// A comment *inside* a slot child that no deeper slot list consumed has
// no place the printer knows how to render; the enclosing statement is
// marked frozen and is later reproduced verbatim from source.
class TriviaWalker {
 public:
  TriviaWalker(Source* source,
               List<Scanner::Comment> comments,
               TriviaTable* table,
               int initial_anchor)
      : source_(source)
      , text_(source->text())
      , size_(source->size())
      , table_(table)
      , gap_anchor_(initial_anchor) {
    for (int i = 0; i < comments.length(); i++) {
      if (comments[i].is_valid()) comments_.push_back(comments[i]);
    }
    std::sort(comments_.begin(), comments_.end(),
              [&](const Scanner::Comment& a, const Scanner::Comment& b) {
                return pos(a.range().from()) < pos(b.range().from());
              });
    std::vector<std::pair<int, int>> ranges;
    for (auto& comment : comments_) {
      ranges.push_back({pos(comment.range().from()),
                        pos(comment.range().to())});
    }
    table_->initialize_comment_ranges(std::move(ranges));
  }

  void walk_unit(Unit* unit) {
    // Imports, exports and declarations live in separate lists; merge
    // them in source order.
    std::vector<Node*> children;
    for (auto import : unit->imports()) children.push_back(import);
    for (auto exp : unit->exports()) children.push_back(exp);
    for (auto decl : unit->declarations()) children.push_back(decl);
    std::sort(children.begin(), children.end(), [&](Node* a, Node* b) {
      return start(a) < start(b);
    });
    walk_slots(children, unit, null, size_);
  }

 private:
  Source* source_;
  const uint8* text_;
  int size_;
  TriviaTable* table_;
  std::vector<Scanner::Comment> comments_;
  size_t next_ = 0;
  // End offset of the last consumed entity (node or comment); blank
  // lines are counted from here.
  int gap_anchor_;
  // The innermost statement-equivalent being walked; the freeze target
  // for comments at positions the printer has no slot for.
  Node* current_stmt_ = null;

  int pos(Source::Position p) const { return source_->offset_in_source(p); }
  int start(Node* n) const { return pos(n->full_range().from()); }
  int end(Node* n) const { return pos(n->full_range().to()); }

  int comment_start(size_t i) const { return pos(comments_[i].range().from()); }
  int comment_end(size_t i) const { return pos(comments_[i].range().to()); }

  // Column of `offset` on its line.
  int column_of(int offset) const {
    int line_start = offset;
    while (line_start > 0 && text_[line_start - 1] != '\n') line_start--;
    return offset - line_start;
  }

  // Whether there is non-whitespace before `offset` on its line.
  bool has_code_before_on_line(int offset) const {
    for (int i = offset - 1; i >= 0 && text_[i] != '\n'; i--) {
      if (text_[i] != ' ' && text_[i] != '\t') return true;
    }
    return false;
  }

  bool same_line(int left, int right) const {
    if (left > right) return false;
    for (int offset = left; offset < right; offset++) {
      if (text_[offset] == '\n') return false;
    }
    return true;
  }

  // Whitespace-only lines fully inside [from, to). Lines with content
  // in the gap (a class or method header between the anchor and the
  // first body slot) don't count, and neither do the partial lines at
  // either end.
  int blank_lines_between(int from, int to) const {
    int i = from;
    bool at_line_start = (from == 0) || (text_[from - 1] == '\n');
    if (!at_line_start) {
      while (i < to && text_[i] != '\n') i++;
      i++;
    }
    int blanks = 0;
    while (i < to) {
      int j = i;
      while (j < size_ && text_[j] != '\n'
             && (text_[j] == ' ' || text_[j] == '\t' || text_[j] == '\r')) {
        j++;
      }
      if (j < to && text_[j] == '\n') {
        blanks++;
        i = j + 1;
        continue;
      }
      // Content line (or the line runs past `to`): skip it without
      // counting.
      while (i < to && text_[i] != '\n') i++;
      i++;
    }
    return blanks;
  }

  CommentTrivia make_trivia(size_t i, int blank_before) const {
    CommentTrivia trivia;
    trivia.id = i;
    trivia.is_multiline = comments_[i].is_multiline();
    int from = comment_start(i);
    int to = comment_end(i);
    trivia.text.assign(reinterpret_cast<const char*>(text_) + from, to - from);
    trivia.spans_lines = trivia.text.find('\n') != std::string::npos;
    trivia.blank_lines_before = blank_before;
    trivia.original_column = column_of(from);
    trivia.attached = from > 0 && text_[from - 1] != ' '
        && text_[from - 1] != '\t' && text_[from - 1] != '\n';
    return trivia;
  }

  void freeze(Node* node) {
    Node* target = current_stmt_ != null ? current_stmt_ : node;
    table_->get(target)->frozen = true;
  }

  // Whether comments indented deeper than the next sibling should
  // attach to `prev` as dangling trivia: a method whose body consists
  // only of comments (`on-foo:` followed by indented comment lines)
  // owns those comments; they are not leading trivia of the next
  // member.
  static bool owns_deeper_comments(Node* prev) {
    if (prev == null || !prev->is_Method()) return false;
    Method* method = prev->as_Method();
    return method->body() != null && method->body()->expressions().is_empty();
  }

  // Consumes all comments that start before `limit`. EOL comments (code
  // before them on their line) go to `trailing_target`; comments
  // indented deeper than `next_column` go to `deeper_owner`'s dangling
  // list; the rest go to `leading_target`, or to `dangling_owner`'s
  // dangling list when `leading_target` is null. A null
  // `trailing_target` sends EOL comments to the leading/dangling list
  // as well (better misplaced than dropped).
  void consume_comments(int limit,
                        Node* trailing_target,
                        Node* leading_target,
                        Node* dangling_owner,
                        Node* deeper_owner = null,
                        int next_column = -1) {
    while (next_ < comments_.size() && comment_start(next_) < limit) {
      int c_start = comment_start(next_);
      bool is_eol = has_code_before_on_line(c_start);
      bool trails_target = trailing_target != null
          && end(trailing_target) <= c_start
          && same_line(end(trailing_target), c_start);
      int blanks = blank_lines_between(gap_anchor_, c_start);
      CommentTrivia trivia = make_trivia(next_, blanks);
      if (is_eol && trails_target) {
        table_->get(trailing_target)->trailing.push_back(std::move(trivia));
      } else if (is_eol && trailing_target != null) {
        // The code before this comment is punctuation owned by an enclosing
        // construct, not the proposed trailing node (which is on another
        // line or even after the comment). Preserve the enclosing statement.
        freeze(trailing_target);
      } else if (!is_eol && deeper_owner != null && next_column >= 0
                 && trivia.original_column > next_column) {
        table_->get(deeper_owner)->dangling.push_back(std::move(trivia));
      } else if (leading_target != null) {
        table_->get(leading_target)->leading.push_back(std::move(trivia));
      } else if (dangling_owner != null) {
        table_->get(dangling_owner)->dangling.push_back(std::move(trivia));
      } else if (current_stmt_ != null) {
        freeze(current_stmt_);
      }
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  // Consumes comments inside `node` that none of its slot lists took.
  // The printer has no place for them; freeze the enclosing statement.
  void consume_interior_leftovers(Node* node) {
    int node_end = end(node);
    bool froze = false;
    while (next_ < comments_.size() && comment_start(next_) < node_end) {
      freeze(node);
      froze = true;
      gap_anchor_ = comment_end(next_);
      next_++;
    }
    if (froze) {
      // The verbatim reproduction covers the statement's whole range.
      gap_anchor_ = gap_anchor_ > node_end ? gap_anchor_ : node_end;
    }
  }

  // The opening delimiter is not an AST node. Preserve an end-of-line
  // comment after it in a dedicated gap; own-line comments remain leading
  // trivia of the first child.
  void consume_collection_opening(int limit, Node* first, Node* owner) {
    while (next_ < comments_.size() && comment_start(next_) < limit) {
      int c_start = comment_start(next_);
      CommentTrivia trivia = make_trivia(
          next_, blank_lines_between(gap_anchor_, c_start));
      if (has_code_before_on_line(c_start)) {
        table_->get(owner)->after_open.comments.push_back(std::move(trivia));
      } else {
        table_->get(first)->leading.push_back(std::move(trivia));
      }
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  // Walks a slot list. `owner` receives dangling comments after the
  // last child; `header_node` receives EOL comments in the gap before
  // the first child (e.g. a comment after a class header's colon).
  // `list_end` bounds the tail gap.
  void walk_slots(const std::vector<Node*>& children,
                  Node* owner,
                  Node* header_node,
                  int list_end) {
    Node* prev = header_node;
    for (auto child : children) {
      int child_start = start(child);
      consume_comments(child_start, prev, child, null,
                       owns_deeper_comments(prev) ? prev : null,
                       column_of(child_start));
      table_->get(child)->blank_lines_before =
          blank_lines_between(gap_anchor_, child_start);
      // Nested slot lists measure their gaps within the child.
      if (child_start > gap_anchor_) gap_anchor_ = child_start;
      walk_node(child);
      consume_interior_leftovers(child);
      if (end(child) > gap_anchor_) gap_anchor_ = end(child);
      prev = child;
    }
    consume_comments(list_end, prev, null, owner);
  }

  // A statement list: like walk_slots, but each child becomes the
  // freeze target while its subtree is walked.
  void walk_statements(const std::vector<Node*>& children,
                       Node* owner,
                       Node* header_node,
                       int list_end) {
    Node* prev = header_node;
    for (auto child : children) {
      int child_start = start(child);
      consume_comments(child_start, prev, child, null,
                       owns_deeper_comments(prev) ? prev : null,
                       column_of(child_start));
      table_->get(child)->blank_lines_before =
          blank_lines_between(gap_anchor_, child_start);
      if (child_start > gap_anchor_) gap_anchor_ = child_start;
      Node* saved_stmt = current_stmt_;
      current_stmt_ = child;
      walk_node(child);
      consume_interior_leftovers(child);
      current_stmt_ = saved_stmt;
      if (end(child) > gap_anchor_) gap_anchor_ = end(child);
      prev = child;
    }
    consume_comments(list_end, prev, null, owner);
  }

  static std::vector<Node*> sequence_statements(Sequence* sequence) {
    std::vector<Node*> result;
    if (sequence == null) return result;
    for (auto expression : sequence->expressions()) result.push_back(expression);
    return result;
  }

  int line_end_after(int offset) const {
    while (offset < size_ && text_[offset] != '\n') offset++;
    return offset;
  }

  // The sequence itself is the trailing target for EOL comments on its
  // header line (after `foo ...:`, `else:`, `finally:`); distinct
  // branch bodies of one statement must not share a target. The list
  // extends to the end of the last statement's line so its EOL comment
  // is routed to it (and not to whatever node encloses the sequence).
  void walk_sequence(Sequence* sequence) {
    if (sequence == null) return;
    auto statements = sequence_statements(sequence);
    if (statements.empty()) return;
    int list_end = line_end_after(end(statements.back()));
    walk_statements(statements, sequence, sequence, list_end);
  }

  void walk_node(Node* node) {
    if (node == null) return;
    if (node->is_Class()) {
      Class* klass = node->as_Class();
      std::vector<Node*> members;
      for (auto member : klass->members()) members.push_back(member);
      int body_start = members.empty() ? end(klass) : start(members.front());
      consume_class_header_comments(klass, body_start);
      walk_slots(members, klass, null, end(klass));
      return;
    }
    if (node->is_Method()) {
      Method* method = node->as_Method();
      std::vector<Node*> parameters;
      for (auto parameter : method->parameters()) parameters.push_back(parameter);
      if (!parameters.empty()) {
        walk_slots(
            parameters, method, method->name_or_dot(), end(parameters.back()));
        // Comments between the last parameter and the return arrow
        // still belong to the signature, not the body.
        int signature_limit = method->return_type() != null
            ? start(method->return_type())
            : -1;
        consume_glued_comments(parameters.back(), signature_limit);
      }
      consume_method_header_comment(method);
      walk_sequence(method->body());
      return;
    }
    if (node->is_Field()) {
      Field* field = node->as_Field();
      walk_expression(field->type());
      walk_expression(field->initializer());
      return;
    }
    if (node->is_Expression()) {
      walk_expression(node->as_Expression());
      return;
    }
    // Imports, exports: no inner slots.
  }

  void walk_expression(Expression* expression) {
    if (expression == null) return;
    if (expression->is_Parenthesis()) {
      walk_expression(expression->as_Parenthesis()->expression());
    } else if (expression->is_Binary()) {
      Binary* binary = expression->as_Binary();
      walk_expression(binary->left());
      walk_expression(binary->right());
    } else if (expression->is_Unary()) {
      walk_expression(expression->as_Unary()->expression());
    } else if (expression->is_Dot()) {
      walk_expression(expression->as_Dot()->receiver());
    } else if (expression->is_Index()) {
      Index* index = expression->as_Index();
      walk_expression(index->receiver());
      for (auto argument : index->arguments()) walk_expression(argument);
    } else if (expression->is_IndexSlice()) {
      IndexSlice* slice = expression->as_IndexSlice();
      walk_expression(slice->receiver());
      walk_expression(slice->from());
      walk_expression(slice->to());
    } else if (expression->is_Call()) {
      walk_call(expression->as_Call());
    } else if (expression->is_NamedArgument()) {
      walk_expression(expression->as_NamedArgument()->expression());
    } else if (expression->is_Nullable()) {
      walk_expression(expression->as_Nullable()->type());
    } else if (expression->is_Return()) {
      walk_expression(expression->as_Return()->value());
    } else if (expression->is_BreakContinue()) {
      walk_expression(expression->as_BreakContinue()->value());
    } else if (expression->is_DeclarationLocal()) {
      DeclarationLocal* declaration = expression->as_DeclarationLocal();
      walk_expression(declaration->type());
      walk_expression(declaration->value());
    } else if (expression->is_If()) {
      If* if_node = expression->as_If();
      walk_expression(if_node->expression());
      if (if_node->yes() != null && if_node->yes()->is_Sequence()) {
        consume_suite_header_comment(
            if_node->expression(), if_node->yes()->as_Sequence());
      }
      walk_branch(if_node->yes());
      if (if_node->yes() != null
          && if_node->yes()->is_Sequence()
          && if_node->no() != null) {
        // A comment-only suite has no statement slot to claim its comment.
        // Keep comments before the following else/else-if dangling in this
        // suite rather than letting them migrate one branch on every run.
        consume_else_gap(
            start(if_node->no()),
            if_node->yes()->as_Sequence(),
            if_node->no());
      }
      walk_branch(if_node->no());
    } else if (expression->is_While()) {
      While* while_node = expression->as_While();
      walk_expression(while_node->condition());
      if (while_node->body() != null && while_node->body()->is_Sequence()) {
        consume_suite_header_comment(
            while_node->condition(), while_node->body()->as_Sequence());
      }
      walk_branch(while_node->body());
    } else if (expression->is_For()) {
      For* for_node = expression->as_For();
      walk_expression(for_node->initializer());
      walk_expression(for_node->condition());
      walk_expression(for_node->update());
      walk_branch(for_node->body());
    } else if (expression->is_TryFinally()) {
      TryFinally* try_node = expression->as_TryFinally();
      walk_branch(try_node->body());
      walk_branch(try_node->handler());
    } else if (expression->is_Block()) {
      walk_sequence(expression->as_Block()->body());
    } else if (expression->is_Lambda()) {
      walk_sequence(expression->as_Lambda()->body());
    } else if (expression->is_Sequence()) {
      walk_sequence(expression->as_Sequence());
    } else if (expression->is_LiteralList()) {
      walk_elements(expression->as_LiteralList()->elements(), expression);
    } else if (expression->is_LiteralByteArray()) {
      walk_elements(expression->as_LiteralByteArray()->elements(), expression);
    } else if (expression->is_LiteralSet()) {
      walk_elements(expression->as_LiteralSet()->elements(), expression);
    } else if (expression->is_LiteralMap()) {
      walk_map(expression->as_LiteralMap());
    } else if (expression->is_LiteralStringInterpolation()) {
      LiteralStringInterpolation* interpolation =
          expression->as_LiteralStringInterpolation();
      for (auto inner : interpolation->expressions()) walk_expression(inner);
    }
    // Identifiers and literals: no inner structure.
  }

  // A suite's empty Sequence range points at the following token, not at its
  // header. Consume a comment after `if/while ...:` using the condition range
  // instead, so adjacent empty else-if branches cannot steal each other's
  // comments.
  void consume_suite_header_comment(Node* header_last, Sequence* body) {
    int from = end(header_last);
    int line_end = line_end_after(from);
    int colon = -1;
    for (int offset = from; offset < line_end; offset++) {
      if (text_[offset] == ':') {
        colon = offset;
        break;
      }
    }
    if (colon >= 0) {
      // Anything still pending before the suite separator belongs inside the
      // condition/header expression (for example an EOL comment after a
      // binary operator). It cannot be re-anchored after `:` merely because
      // both positions are end-of-line comments.
      while (next_ < comments_.size() && comment_start(next_) < colon) {
        freeze(header_last);
        gap_anchor_ = comment_end(next_);
        next_++;
      }
      consume_header_line_comments(line_end, body);
    }
  }

  void consume_method_header_comment(Method* method) {
    Sequence* body = method->body();
    if (body == null) return;
    int limit = end(method);
    if (!body->expressions().is_empty()) {
      limit = start(body->expressions().first());
    }
    int signature_end = end(method->name_or_dot());
    if (method->return_type() != null) {
      signature_end = std::max(signature_end, end(method->return_type()));
    }
    for (auto parameter : method->parameters()) {
      signature_end = std::max(signature_end, end(parameter));
    }
    int colon = find_map_colon(signature_end, limit);
    if (colon >= 0) {
      // Comments before the body separator sit in a syntax gap such as
      // `foo -> /* type */ any:`. Moving them after the colon keeps their
      // line category but loses their token anchor, so preserve the whole
      // declaration until method-header gaps have dedicated rendering.
      while (next_ < comments_.size() && comment_start(next_) < colon) {
        table_->get(method)->frozen = true;
        gap_anchor_ = comment_end(next_);
        next_++;
      }
      consume_header_line_comments(line_end_after(colon), body);
    }
  }

  void consume_class_header_comments(Class* klass, int limit) {
    int signature_end = end(klass->name());
    if (klass->super() != null) {
      signature_end = std::max(signature_end, end(klass->super()));
    }
    for (auto mixin : klass->mixins()) {
      signature_end = std::max(signature_end, end(mixin));
    }
    for (auto interface : klass->interfaces()) {
      signature_end = std::max(signature_end, end(interface));
    }
    int colon = find_map_colon(signature_end, limit);
    if (colon < 0) return;

    // Header-internal comments have no AST node or layout-tree gap. Freezing the
    // class is conservative and, importantly, preserves whether a comment
    // describes the name, a clause keyword, or a clause expression.
    while (next_ < comments_.size() && comment_start(next_) < colon) {
      table_->get(klass)->frozen = true;
      gap_anchor_ = comment_end(next_);
      next_++;
    }

    // A comment after the separator belongs after the complete header, even
    // when the header itself spans multiple lines. The name is the existing
    // printable anchor for that position.
    int line_end = line_end_after(colon);
    while (next_ < comments_.size() && comment_start(next_) < line_end) {
      CommentTrivia trivia = make_trivia(
          next_, blank_lines_between(gap_anchor_, comment_start(next_)));
      table_->get(klass->name())->trailing.push_back(std::move(trivia));
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  void consume_header_line_comments(int limit, Sequence* body) {
    while (next_ < comments_.size() && comment_start(next_) < limit) {
      CommentTrivia trivia = make_trivia(
          next_, blank_lines_between(gap_anchor_, comment_start(next_)));
      table_->get(body)->trailing.push_back(std::move(trivia));
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  void consume_else_gap(int limit, Sequence* yes, Expression* no) {
    while (next_ < comments_.size() && comment_start(next_) < limit) {
      int c_start = comment_start(next_);
      CommentTrivia trivia = make_trivia(
          next_, blank_lines_between(gap_anchor_, c_start));
      if (has_code_before_on_line(c_start) && no->is_Sequence()) {
        // This is after the final `else:` header.
        table_->get(no)->trailing.push_back(std::move(trivia));
      } else {
        table_->get(yes)->dangling.push_back(std::move(trivia));
      }
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  // A control-flow branch body: a Sequence in the AST.
  void walk_branch(Expression* body) {
    if (body == null) return;
    if (body->is_Sequence()) {
      walk_sequence(body->as_Sequence());
    } else {
      walk_expression(body);
    }
  }

  // Collection elements. The list extends to the closing bracket so a
  // trailing comment on the last element (or a dangling comment line
  // before the bracket) is routed here.
  // Consumes single-line block comments glued directly to the end of
  // `target` (`bar/List/*<int>*/`): they annotate the token they touch
  // and must stay its trailing trivia, even when the slot list they
  // followed has already ended.
  // `limit >= 0` additionally takes detached single-line block
  // comments up to that offset (the return arrow): they sit between
  // signature tokens and stay with the signature.
  void consume_glued_comments(Node* target, int limit = -1) {
    int expected = end(target);
    while (next_ < comments_.size()) {
      if (!comments_[next_].is_multiline()) break;
      int c_start = comment_start(next_);
      bool glued = c_start == expected;
      bool in_signature = limit >= 0 && c_start < limit
          && has_code_before_on_line(c_start);
      if (!glued && !in_signature) break;
      CommentTrivia trivia = make_trivia(next_, 0);
      if (trivia.spans_lines) break;
      table_->get(target)->trailing.push_back(std::move(trivia));
      gap_anchor_ = comment_end(next_);
      expected = comment_end(next_);
      next_++;
    }
  }

  void walk_elements(List<Expression*> elements, Node* owner) {
    if (elements.is_empty()) return;
    std::vector<Node*> children;
    for (auto element : elements) children.push_back(element);
    consume_collection_opening(start(children.front()), children.front(), owner);
    walk_slots(children, owner, null, end(owner));
  }

  int find_map_colon(int from, int to) const {
    size_t comment = next_;
    for (int offset = from; offset < to; offset++) {
      while (comment < comments_.size() && comment_end(comment) <= offset) {
        comment++;
      }
      if (comment < comments_.size()
          && comment_start(comment) <= offset
          && offset < comment_end(comment)) {
        offset = comment_end(comment) - 1;
        continue;
      }
      if (text_[offset] == ':') return offset;
    }
    return -1;
  }

  // Consumes comments in one side of a map entry's ':' gap. Single-line
  // block comments have a stable inline rendering. Line-ending comments
  // freeze the map expression until the layout IR has a dedicated line-suffix
  // primitive; freezing is conservative and preserves the bytes exactly.
  void consume_map_gap(int limit, GapTrivia* gap, LiteralMap* map) {
    while (next_ < comments_.size() && comment_start(next_) < limit) {
      CommentTrivia trivia = make_trivia(
          next_, blank_lines_between(gap_anchor_, comment_start(next_)));
      if (!trivia.is_multiline || trivia.spans_lines) {
        freeze(map);
      } else {
        gap->comments.push_back(std::move(trivia));
      }
      gap_anchor_ = comment_end(next_);
      next_++;
    }
  }

  void walk_map(LiteralMap* map) {
    if (map->keys().is_empty()) return;
    consume_collection_opening(
        start(map->keys().first()), map->keys().first(), map);
    Node* previous = null;
    for (int i = 0; i < map->keys().length(); i++) {
      Expression* key = map->keys()[i];
      Expression* value = map->values()[i];
      int key_start = start(key);
      consume_comments(key_start, previous, key, null);
      table_->get(key)->blank_lines_before =
          blank_lines_between(gap_anchor_, key_start);
      if (key_start > gap_anchor_) gap_anchor_ = key_start;
      walk_expression(key);
      consume_interior_leftovers(key);
      if (end(key) > gap_anchor_) gap_anchor_ = end(key);

      int value_start = start(value);
      int colon = find_map_colon(end(key), value_start);
      if (colon < 0) {
        freeze(map);
        colon = value_start;
      }
      MapEntryTrivia* entry = table_->get_map_entry(key);
      consume_map_gap(colon, &entry->before_colon, map);
      if (colon < value_start) gap_anchor_ = std::max(gap_anchor_, colon + 1);
      consume_map_gap(value_start, &entry->after_colon, map);

      if (value_start > gap_anchor_) gap_anchor_ = value_start;
      walk_expression(value);
      consume_interior_leftovers(value);
      if (end(value) > gap_anchor_) gap_anchor_ = end(value);
      previous = value;
    }
    consume_comments(end(map), previous, null, map);
  }

  void walk_call(Call* call) {
    walk_expression(call->target());
    if (call->arguments().is_empty()) return;
    std::vector<Node*> arguments;
    for (auto argument : call->arguments()) arguments.push_back(argument);
    // An end-of-line comment after the target belongs to the target, while
    // an own-line comment before the first argument remains leading trivia
    // of that argument.
    walk_slots(arguments, call, call->target(), end(arguments.back()));
  }
};

void attach_trivia(Unit* unit,
                   Source* source,
                   List<Scanner::Comment> comments,
                   TriviaTable* table) {
  int preamble_end = 0;
  const uint8* text = source->text();
  if (source->size() >= 2 && text[0] == '#' && text[1] == '!') {
    while (preamble_end < source->size()
           && text[preamble_end] != '\n'
           && text[preamble_end] != '\r') {
      preamble_end++;
    }
    table->set_preamble(std::string(
        reinterpret_cast<const char*>(text), preamble_end));
    if (preamble_end < source->size() && text[preamble_end] == '\r') {
      preamble_end++;
    }
    if (preamble_end < source->size() && text[preamble_end] == '\n') {
      preamble_end++;
    }
  }
  TriviaWalker walker(source, comments, table, preamble_end);
  walker.walk_unit(unit);
}

} // namespace toit::compiler
} // namespace toit
