// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

#include "format_statement.h"

#include <string>
#include <vector>

#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

class StatementPrinter {
 public:
  StatementPrinter(Source* source,
                   const FormatStyle& style,
                   const FormatExpressionOptions& expression_options,
                   FormatCommentState* comments)
      : source_(source)
      , style_(style)
      , expression_options_(expression_options)
      , comments_(comments) {}

  bool sequence(Sequence* sequence, int indentation, std::string* result) {
    ASSERT(sequence != null && result != null);
    std::vector<std::string> statements;
    // Earlier container printers have already consumed their comments. Using
    // zero here lets the first statement claim own-line comments immediately
    // after a suite's colon even though Sequence's AST range starts at its
    // first expression.
    int cursor = 0;
    for (auto expression : sequence->expressions()) {
      int expression_start = start(expression);
      if (comments_ != null) {
        int original_indentation = line(expression_start).indentation;
        std::string leading;
        if (!comments_->render_own_line(
            cursor,
            expression_start,
            indentation - original_indentation,
            &leading,
            style_.max_blank_lines)) return false;
        if (!leading.empty()) statements.push_back(std::move(leading));
      }
      std::string text;
      if (comments_ != null && should_render_verbatim(expression)) {
        int first_line = facts()->line_index_at(expression_start);
        int last_line = facts()->line_index_at(
            std::max(expression_start, end(expression) - 1));
        if (contains_multiline_string(expression)) {
          text = comments_->render_verbatim_preserving_continuations(
              first_line, last_line, indentation);
        } else {
          text = comments_->render_verbatim(
              first_line, last_line, indentation);
        }
      } else if (!statement(expression, indentation, &text)) {
        return false;
      }
      statements.push_back(std::move(text));
      cursor = end(expression);
    }
    *result = join(statements, "\n");
    return true;
  }

 private:
  Source* source_;
  const FormatStyle& style_;
  const FormatExpressionOptions& expression_options_;
  FormatCommentState* comments_;

  FormatSource* facts() const {
    return const_cast<FormatSource*>(comments_->source());
  }

  int start(Node* node) const {
    return source_->offset_in_source(node->full_range().from());
  }

  int end(Node* node) const {
    return source_->offset_in_source(node->full_range().to());
  }

  const FormatLine& line(int offset) const {
    return facts()->lines()[facts()->line_index_at(offset)];
  }

  bool is_control(Expression* expression) const {
    return (expression->is_If() && expression->as_If()->yes() != null &&
            expression->as_If()->yes()->is_Sequence()) ||
        expression->is_While() || expression->is_For() ||
        expression->is_TryFinally();
  }

  bool contains_multiline_string(Expression* expression) const {
    int from = start(expression);
    int to = end(expression);
    const uint8* bytes = source_->text();
    for (int offset = from; offset + 2 < to; offset++) {
      if (bytes[offset] == '"' && bytes[offset + 1] == '"' &&
          bytes[offset + 2] == '"') return true;
    }
    return false;
  }

  bool should_render_verbatim(Expression* expression) const {
    int from = start(expression);
    int to = end(expression);
    if (contains_multiline_string(expression)) return true;
    int first_line = facts()->line_index_at(from);
    int header_to = facts()->lines()[first_line].to;
    if (comments_->has_unconsumed_in(from, header_to)) return true;
    if (is_control(expression)) return false;
    int last_line = facts()->line_index_at(
        std::max(from, to - 1));
    return comments_->has_unconsumed_in(
        facts()->lines()[first_line].from,
        facts()->lines()[last_line].to);
  }

  static std::string join(const std::vector<std::string>& parts,
                          const char* separator) {
    std::string result;
    for (const auto& part : parts) {
      if (!result.empty()) result += separator;
      result += part;
    }
    return result;
  }

  bool flat(Expression* expression, std::string* result) {
    return format_expression_flat(
        expression, source_, result, expression_options_);
  }

  bool formatted(Expression* expression,
                 int indentation,
                 FormatOutput* result) {
    return format_expression(expression,
                             source_,
                             indentation,
                             result,
                             style_,
                             expression_options_);
  }

  static std::string indent(int indentation) {
    return std::string(indentation, ' ');
  }

  static std::string render_prefixed(const std::string& prefix,
                                     const FormatOutput& output,
                                     int indentation) {
    ASSERT(!output.lines().empty());
    std::string result = indent(indentation) + prefix +
        output.lines()[0].text;
    for (int i = 1; i < static_cast<int>(output.lines().size()); i++) {
      result += "\n" + indent(indentation + output.lines()[i].indentation) +
          output.lines()[i].text;
    }
    return result;
  }

  bool local_fragment(DeclarationLocal* declaration, std::string* result) {
    std::string text;
    if (!flat(declaration->name(), &text)) return false;
    if (declaration->type() != null) {
      std::string type;
      if (!flat(declaration->type(), &type)) return false;
      text += "/" + type;
    }
    text += " " + std::string(Token::symbol(declaration->kind()).c_str());
    if (declaration->value() != null) {
      std::string value;
      if (!flat(declaration->value(), &value)) return false;
      text += " " + value;
    }
    *result = text;
    return true;
  }

  bool suite(Expression* expression,
             int indentation,
             std::string* result) {
    if (expression == null || !expression->is_Sequence()) return false;
    return sequence(expression->as_Sequence(), indentation, result);
  }

  bool control_if(If* conditional,
                  int indentation,
                  const std::string& keyword,
                  std::string* result) {
    std::string condition;
    if (!flat(conditional->expression(), &condition)) return false;
    std::string body;
    if (!suite(conditional->yes(),
               indentation + style_.indentation_step,
               &body)) return false;
    *result = indent(indentation) + keyword + " " + condition + ":";
    if (!body.empty()) *result += "\n" + body;

    Expression* no = conditional->no();
    if (no == null) return true;
    if (no->is_If() && no->as_If()->yes()->is_Sequence()) {
      std::string tail;
      if (!control_if(no->as_If(), indentation, "else if", &tail)) {
        return false;
      }
      *result += "\n" + tail;
      return true;
    }
    std::string else_body;
    if (!suite(no, indentation + style_.indentation_step, &else_body)) {
      return false;
    }
    *result += "\n" + indent(indentation) + "else:";
    if (!else_body.empty()) *result += "\n" + else_body;
    return true;
  }

  bool statement(Expression* expression,
                 int indentation,
                 std::string* result) {
    if (expression->is_Return()) {
      Return* return_expression = expression->as_Return();
      if (return_expression->value() == null) {
        *result = indent(indentation) + "return";
        return true;
      }
      FormatOutput value;
      if (!formatted(return_expression->value(), indentation, &value)) {
        return false;
      }
      *result = render_prefixed("return ", value, indentation);
      return true;
    }
    if (expression->is_DeclarationLocal()) {
      DeclarationLocal* declaration = expression->as_DeclarationLocal();
      std::string prefix;
      if (!flat(declaration->name(), &prefix)) return false;
      if (declaration->type() != null) {
        std::string type;
        if (!flat(declaration->type(), &type)) return false;
        prefix += "/" + type;
      }
      prefix += " " +
          std::string(Token::symbol(declaration->kind()).c_str());
      if (declaration->value() == null) {
        *result = indent(indentation) + prefix;
        return true;
      }
      FormatOutput value;
      if (!formatted(declaration->value(), indentation, &value)) return false;
      *result = render_prefixed(prefix + " ", value, indentation);
      return true;
    }
    if (expression->is_BreakContinue()) {
      BreakContinue* jump = expression->as_BreakContinue();
      std::string text = jump->is_break() ? "break" : "continue";
      if (jump->label() != null) {
        std::string label;
        if (!flat(jump->label(), &label)) return false;
        text += "." + label;
      }
      if (jump->value() != null) {
        std::string value;
        if (!flat(jump->value(), &value)) return false;
        text += " " + value;
      }
      *result = indent(indentation) + text;
      return true;
    }
    if (expression->is_If() &&
        expression->as_If()->yes() != null &&
        expression->as_If()->yes()->is_Sequence()) {
      return control_if(
          expression->as_If(), indentation, "if", result);
    }
    if (expression->is_While()) {
      While* loop = expression->as_While();
      std::string condition;
      if (!flat(loop->condition(), &condition)) return false;
      std::string body;
      if (!suite(loop->body(),
                 indentation + style_.indentation_step,
                 &body)) return false;
      *result = indent(indentation) + "while " + condition + ":";
      if (!body.empty()) *result += "\n" + body;
      return true;
    }
    if (expression->is_For()) {
      For* loop = expression->as_For();
      std::string initializer;
      if (loop->initializer() != null) {
        if (loop->initializer()->is_DeclarationLocal()) {
          if (!local_fragment(
              loop->initializer()->as_DeclarationLocal(), &initializer)) {
            return false;
          }
        } else if (!flat(loop->initializer(), &initializer)) {
          return false;
        }
      }
      std::string condition;
      if (loop->condition() != null && !flat(loop->condition(), &condition)) {
        return false;
      }
      std::string update;
      if (loop->update() != null && !flat(loop->update(), &update)) {
        return false;
      }
      std::string body;
      if (!suite(loop->body(),
                 indentation + style_.indentation_step,
                 &body)) return false;
      *result = indent(indentation) + "for " + initializer + "; " +
          condition + "; " + update + ":";
      if (!body.empty()) *result += "\n" + body;
      return true;
    }
    if (expression->is_TryFinally()) {
      TryFinally* attempt = expression->as_TryFinally();
      std::string body;
      if (!sequence(attempt->body(),
                    indentation + style_.indentation_step,
                    &body)) return false;
      *result = indent(indentation) + "try:";
      if (!body.empty()) *result += "\n" + body;
      *result += "\n" + indent(indentation) + "finally:";
      if (!attempt->handler_parameters().is_empty()) {
        *result += " |";
        for (auto parameter : attempt->handler_parameters()) {
          std::string name;
          if (!flat(parameter->name(), &name)) return false;
          *result += " " + name;
        }
        *result += " |";
      }
      std::string handler;
      if (!sequence(attempt->handler(),
                    indentation + style_.indentation_step,
                    &handler)) return false;
      if (!handler.empty()) *result += "\n" + handler;
      return true;
    }

    FormatOutput output;
    if (!formatted(expression, indentation, &output)) return false;
    *result = output.render(indentation);
    return true;
  }
};

} // namespace

bool format_sequence(Sequence* sequence,
                     Source* source,
                     int indentation,
                     std::string* result,
                     const FormatStyle& style,
                     const FormatExpressionOptions& expression_options,
                     FormatCommentState* comments) {
  ASSERT(source != null && result != null);
  ASSERT(indentation >= 0);
  StatementPrinter printer(source, style, expression_options, comments);
  return printer.sequence(sequence, indentation, result);
}

} // namespace compiler
} // namespace toit
