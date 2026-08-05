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

#include "format_body.h"

#include "../top.h"
#include "ast.h"
#include "sources.h"

#include <algorithm>
#include <cstring>

namespace toit {
namespace compiler {

namespace {

class BodyLowering {
 public:
  BodyLowering(Source* source,
               LayoutBuilder* layouts,
               LogicalOperatorBindings* bindings,
               SyntaxProtection* syntax,
               TriviaLowering* trivia,
               const FormatStyle& style)
      : source_(source)
      , layouts_(layouts)
      , bindings_(bindings)
      , syntax_(syntax)
      , trivia_(trivia)
      , style_(style) {}

  Layout* lower(ast::Sequence* body, int source_from, int source_to) {
    ASSERT(body != null);
    ASSERT(0 <= source_from && source_from <= source_to);
    int source_indentation = 0;
    if (!body->expressions().is_empty()) {
      int first = start(body->expressions().first());
      source_indentation = first - line_start(first);
    } else if (trivia_ != null) {
      std::vector<int> comments = trivia_->comments_in(source_from, source_to);
      if (!comments.empty()) {
        source_indentation = trivia_->comment(comments[0]).original_column;
      }
    }
    Layout* result =
        lower_sequence(body, source_from, source_to, source_indentation);
    ASSERT(trivia_ == null ||
           trivia_->all_comments_consumed(source_from, source_to));
    return result;
  }

 private:
  Source* source_;
  LayoutBuilder* layouts_;
  LogicalOperatorBindings* bindings_;
  SyntaxProtection* syntax_;
  TriviaLowering* trivia_;
  const FormatStyle& style_;

  int start(ast::Node* node) const {
    return source_->offset_in_source(node->full_range().from());
  }

  int end(ast::Node* node) const {
    return source_->offset_in_source(node->full_range().to());
  }

  int line_start(int offset) const {
    const uint8* text = source_->text();
    while (offset > 0 && text[offset - 1] != '\n' && text[offset - 1] != '\r') {
      offset--;
    }
    return offset;
  }

  int line_end(int offset) const {
    const uint8* text = source_->text();
    while (offset < source_->size() && text[offset] != '\n' &&
           text[offset] != '\r') {
      offset++;
    }
    return offset;
  }

  int find_syntax(int from, int to, const char* syntax) const {
    if (trivia_ != null) return trivia_->find_syntax(from, to, syntax);
    int length = std::strlen(syntax);
    const uint8* text = source_->text();
    for (int offset = from; offset + length <= to; offset++) {
      if (std::memcmp(text + offset, syntax, length) == 0) return offset;
    }
    return -1;
  }

  Layout* join_items(std::vector<Layout*> items) {
    if (items.empty()) return layouts_->text("");
    std::vector<Layout*> parts;
    for (Layout* item : items) {
      if (!parts.empty()) parts.push_back(layouts_->hardline());
      parts.push_back(item);
    }
    return layouts_->concat(std::move(parts));
  }

  void append_gap_comments(int from,
                           int to,
                           int source_indentation,
                           std::vector<Layout*>* items) {
    if (trivia_ == null || from >= to) return;
    for (int id : trivia_->comments_in(from, to)) {
      const FormatTrivia::Comment& comment = trivia_->comment(id);
      // A gap before the next outer sibling is also the syntactic limit of a
      // nested sequence. An own-line comment whose indentation is shallower
      // than this sequence belongs to that outer gap and must remain
      // unconsumed here.
      if (!comment.has_code_before &&
          comment.original_column < source_indentation)
        continue;
      if (comment.is_line_comment) {
        // A `//` with code before it must have been consumed together with
        // that statement. At sequence level only a self-contained comment
        // line remains, and it behaves like a verbatim statement.
        ASSERT(!comment.has_code_before);
        items->push_back(trivia_->verbatim_region(comment.from, comment.to));
        continue;
      }
      if (!comment.has_code_before && !comment.has_code_after) {
        items->push_back(trivia_->take_own_line_block(id));
        continue;
      }
      // Prefix/suffix comments are consumed while their semantic statement is
      // lowered. Reaching the surrounding gap means that an attachment shape
      // was not modeled; failing here protects the exact-once invariant.
      UNREACHABLE();
    }
  }

  Layout* lower_sequence(ast::Sequence* sequence,
                         int from,
                         int to,
                         int source_indentation) {
    ASSERT(from <= to);
    std::vector<Layout*> items;
    int cursor = from;
    List<ast::Expression*> expressions = sequence->expressions();
    for (int i = 0; i < expressions.length(); i++) {
      ast::Expression* expression = expressions[i];
      int expression_start = start(expression);
      int expression_limit =
          i + 1 < expressions.length() ? start(expressions[i + 1]) : to;
      ASSERT(cursor <= expression_start &&
             expression_start <= expression_limit);

      Layout* statement = lower_statement(expression, expression_limit);
      if (trivia_ != null) {
        // A block comment on the statement's line but before its first token is
        // an attached prefix. Indentation before that comment belongs to the
        // containing sequence and is deliberately not copied into the layout.
        int prefix_from = std::max(cursor, line_start(expression_start));
        statement = trivia_->take_inline_prefix(statement, prefix_from,
                                                expression_start);
      }
      append_gap_comments(cursor, expression_start, source_indentation, &items);
      items.push_back(statement);
      // Keep the complete previous statement in the next gap's source range.
      // Comments already assigned inside it are skipped by consumption state;
      // an unconsumed, less-indented comment near a nested dedent remains
      // visible to this enclosing sequence even when the nested Sequence's
      // synthetic range extends to the next token.
      cursor = expression_start;
    }
    append_gap_comments(cursor, to, source_indentation, &items);
    return join_items(std::move(items));
  }

  Layout* lower_statement(ast::Expression* expression, int source_limit) {
    if (expression->is_If()) {
      return lower_if(expression->as_If(), source_limit);
    }
    if (expression->is_Return()) {
      return lower_return(expression->as_Return());
    }

    int expression_start = start(expression);
    int expression_end = end(expression);
    if (trivia_ != null) {
      int line_comment =
          trivia_->first_line_comment(expression_start, expression_end, true);
      if (line_comment >= 0) {
        // For a simple statement the statement is the complete replaceable
        // unit on this line, so every byte after its indentation is frozen.
        int frozen_end =
            std::max(expression_end, trivia_->comment(line_comment).to);
        return trivia_->verbatim_region(expression_start, frozen_end);
      }
    }
    return lower_expression(expression, source_, layouts_, bindings_, syntax_,
                            style_, trivia_)
        .layout;
  }

  Layout* lower_return(ast::Return* statement) {
    int statement_start = start(statement);
    int statement_end = end(statement);
    if (trivia_ != null) {
      int line_comment =
          trivia_->first_line_comment(statement_start, statement_end, true);
      if (line_comment >= 0) {
        int frozen_end =
            std::max(statement_end, trivia_->comment(line_comment).to);
        return trivia_->verbatim_region(statement_start, frozen_end);
      }
    }

    Layout* result = layouts_->text("return");
    if (statement->value() != null) {
      Layout* value = lower_expression(statement->value(), source_, layouts_,
                                       bindings_, syntax_, style_, trivia_)
                          .layout;
      result = layouts_->concat({result, layouts_->text(" "), value});
    } else if (trivia_ != null) {
      result = trivia_->take_inline_suffix(result, statement_end,
                                           line_end(statement_end));
    }
    return result;
  }

  Layout* lower_if(ast::If* statement, int source_limit) {
    ASSERT(statement->no() == null);
    ASSERT(statement->yes()->is_Sequence());
    int statement_start = start(statement);
    int condition_end = end(statement->expression());
    int colon = find_syntax(condition_end, source_limit, ":");
    ASSERT(colon >= 0);

    Layout* header;
    if (trivia_ != null) {
      int line_comment =
          trivia_->first_line_comment(statement_start, colon + 1, true);
      if (line_comment >= 0) {
        int frozen_end = std::max(colon + 1, trivia_->comment(line_comment).to);
        header = trivia_->verbatim_region(statement_start, frozen_end);
      } else {
        Layout* condition =
            lower_expression(statement->expression(), source_, layouts_,
                             bindings_, syntax_, style_, trivia_)
                .layout;
        Layout* colon_layout = layouts_->text(":");
        colon_layout = trivia_->take_inline_suffix(colon_layout, colon + 1,
                                                   line_end(colon + 1));
        header =
            layouts_->concat({layouts_->text("if "), condition, colon_layout});
      }
    } else {
      Layout* condition =
          lower_expression(statement->expression(), source_, layouts_,
                           bindings_, syntax_, style_, null)
              .layout;
      header = layouts_->concat(
          {layouts_->text("if "), condition, layouts_->text(":")});
    }

    int statement_indentation = statement_start - line_start(statement_start);
    Layout* body =
        lower_sequence(statement->yes()->as_Sequence(), colon + 1, source_limit,
                       statement_indentation + style_.indentation_step);
    return layouts_->concat({
        header,
        layouts_->indent(style_.indentation_step,
                         layouts_->concat({layouts_->hardline(), body})),
    });
  }
};

} // namespace

Layout* lower_body(ast::Sequence* body,
                   Source* source,
                   int source_from,
                   int source_to,
                   LayoutBuilder* layouts,
                   LogicalOperatorBindings* bindings,
                   SyntaxProtection* syntax,
                   TriviaLowering* trivia,
                   const FormatStyle& style) {
  ASSERT(source != null);
  ASSERT(layouts != null);
  ASSERT(bindings != null);
  ASSERT(syntax != null);
  return BodyLowering(source, layouts, bindings, syntax, trivia, style)
      .lower(body, source_from, source_to);
}

} // namespace compiler
} // namespace toit
