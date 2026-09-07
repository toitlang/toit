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

#include "format_expression.h"

#include <algorithm>
#include <limits>
#include <string>
#include <vector>

#include "format_statement.h"
#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

Expression* peel_parentheses(Expression* expression) {
  while (expression != null && expression->is_Parenthesis()) {
    expression = expression->as_Parenthesis()->expression();
  }
  return expression;
}

bool is_right_associative(Token::Kind kind) {
  int precedence = Token::precedence(kind);
  return precedence == PRECEDENCE_AND || precedence == PRECEDENCE_OR ||
      precedence == PRECEDENCE_ASSIGNMENT;
}

bool is_logical(Token::Kind kind) {
  int precedence = Token::precedence(kind);
  return precedence == PRECEDENCE_AND || precedence == PRECEDENCE_OR;
}

bool is_bitwise(Token::Kind kind) {
  int precedence = Token::precedence(kind);
  return precedence == PRECEDENCE_BIT_SHIFT ||
      precedence == PRECEDENCE_BIT_AND ||
      precedence == PRECEDENCE_BIT_OR ||
      precedence == PRECEDENCE_BIT_XOR;
}

bool is_static_receiver_candidate(Expression* expression) {
  int identifiers = 0;
  while (expression != null && expression->is_Dot()) {
    identifiers++;
    expression = expression->as_Dot()->receiver();
  }
  if (expression == null || !expression->is_Identifier()) return false;
  return ++identifiers <= 3;
}

bool needs_call_argument_parentheses(Expression* expression) {
  return expression->is_Call() || expression->is_Binary() ||
      expression->is_If() || expression->is_DeclarationLocal() ||
      (expression->is_Unary() &&
       expression->as_Unary()->kind() == Token::NOT);
}

class ExpressionPrinter {
 public:
  ExpressionPrinter(Source* source,
                    int base_indentation,
                    const FormatStyle& style,
                    const FormatExpressionOptions& options)
      : source_(source)
      , base_indentation_(base_indentation)
      , style_(style)
      , options_(options) {}

  bool run(Expression* expression, FormatOutput* result) {
    ASSERT(expression != null && result != null);
    return format(expression, PRECEDENCE_NONE, result);
  }

  bool run_flat(Expression* expression, std::string* result) {
    ASSERT(expression != null && result != null);
    std::string text = flat(expression, PRECEDENCE_NONE);
    if (!supported_) return false;
    *result = text;
    return true;
  }

 private:
  Source* source_;
  int base_indentation_;
  const FormatStyle& style_;
  const FormatExpressionOptions& options_;
  bool supported_ = true;

  int start(Node* node) const {
    return source_->offset_in_source(node->full_range().from());
  }

  int end(Node* node) const {
    return source_->offset_in_source(node->full_range().to());
  }

  std::string source_text(Node* node) const {
    int from = start(node);
    int to = end(node);
    return std::string(
        reinterpret_cast<const char*>(source_->text()) + from, to - from);
  }

  int estimated_flat_width(Expression* expression) {
    if (expression == null) return -1;
    expression = peel_parentheses(expression);
    int from = start(expression);
    int to = end(expression);
    int width = 0;
    bool pending_space = false;
    bool after_opener = false;
    uint8 quote = 0;
    bool escaped = false;
    for (int offset = from; offset < to; offset++) {
      uint8 c = source_->text()[offset];
      if (quote != 0) {
        if ((c & 0xc0) != 0x80) width++;
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == quote) {
          quote = 0;
        }
        continue;
      }
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        if (!after_opener && width > 0) pending_space = true;
        continue;
      }
      // These tokens may be added or removed by the printer. They are useful
      // for rendering, but deliberately irrelevant to the rough measurement.
      if (c == ',') {
        pending_space = width > 0;
        after_opener = false;
        continue;
      }
      if (c == '(') {
        after_opener = true;
        continue;
      }
      if (c == ')' || c == '\\') {
        after_opener = false;
        continue;
      }
      if (c == ']' || c == '}') pending_space = false;
      if (pending_space) {
        width++;
        pending_space = false;
      }
      if ((c & 0xc0) != 0x80) width++;
      if (c == '\'' || c == '"') quote = c;
      after_opener = c == '[' || c == '{';
    }
    return width;
  }

  std::string receiver(Expression* expression) {
    bool had_parentheses = expression->is_Parenthesis();
    Expression* inner = peel_parentheses(expression);
    std::string result = flat(inner, PRECEDENCE_POSTFIX);
    if (had_parentheses &&
        (is_static_receiver_candidate(inner) || inner->is_Call())) {
      return "(" + flat(inner, PRECEDENCE_NONE) + ")";
    }
    return result;
  }

  std::string flat_named_argument(NamedArgument* argument) {
    std::string result = "--";
    if (argument->inverted()) result += "no-";
    result += source_text(argument->name());
    if (argument->expression() != null) {
      Expression* value = argument->expression();
      Expression* inner = peel_parentheses(value);
      std::string value_text = flat(inner, PRECEDENCE_NONE);
      if (value->is_Parenthesis() ||
          needs_call_argument_parentheses(inner)) {
        value_text = "(" + value_text + ")";
      }
      result += "=" + value_text;
    }
    return result;
  }

  std::string flat_parameter(Parameter* parameter) {
    std::string result;
    if (parameter->is_named()) result += "--";
    if (parameter->is_field_storing()) result += ".";
    result += source_text(parameter->name());
    if (parameter->type() != null) {
      result += "/" + flat(parameter->type(), PRECEDENCE_NONE);
    }
    if (parameter->default_value() != null) {
      Expression* value = parameter->default_value();
      bool preserve_parentheses = value->is_Parenthesis();
      std::string value_text = flat(value, PRECEDENCE_NONE);
      result += "=" + (preserve_parentheses
          ? "(" + value_text + ")"
          : value_text);
    }
    return result;
  }

  std::string flat_local(DeclarationLocal* declaration) {
    std::string result = flat(declaration->name(), PRECEDENCE_NONE);
    if (declaration->type() != null) {
      result += "/" + flat(declaration->type(), PRECEDENCE_NONE);
    }
    result += " " + std::string(Token::symbol(declaration->kind()).c_str());
    if (declaration->value() != null) {
      Expression* value = declaration->value();
      std::string value_text = flat(value, PRECEDENCE_NONE);
      if (value->is_Parenthesis()) value_text = "(" + value_text + ")";
      result += " " + value_text;
    }
    return result;
  }

  Expression* suite_value(Expression* argument) {
    if (argument->is_Block() || argument->is_Lambda()) return argument;
    if (!argument->is_NamedArgument()) return null;
    Expression* value = argument->as_NamedArgument()->expression();
    return value != null && (value->is_Block() || value->is_Lambda())
        ? value
        : null;
  }

  std::string suite_introduction(Expression* suite) {
    bool is_block = suite->is_Block();
    List<Parameter*> parameters = is_block
        ? suite->as_Block()->parameters()
        : suite->as_Lambda()->parameters();
    std::string result = is_block ? ":" : "::";
    if (!parameters.is_empty()) {
      result += " |";
      for (auto parameter : parameters) {
        result += " " + flat_parameter(parameter);
      }
      result += " |";
    }
    return result;
  }

  std::string flat_suite(Expression* expression) {
    bool is_block = expression->is_Block();
    Sequence* body = is_block
        ? expression->as_Block()->body()
        : expression->as_Lambda()->body();
    if (body->expressions().length() != 1) {
      supported_ = false;
      return std::string();
    }
    Expression* only = body->expressions().first();
    std::string body_text;
    if (!only->is_Return() && !only->is_BreakContinue() &&
        !only->is_While() && !only->is_For() &&
        !only->is_TryFinally() &&
        !(only->is_If() && only->as_If()->yes() != null &&
          only->as_If()->yes()->is_Sequence())) {
      body_text = flat(only, PRECEDENCE_NONE);
    } else if (!format_sequence(body,
                                source_,
                                0,
                                &body_text,
                                style_,
                                options_)) {
      supported_ = false;
      return std::string();
    }
    if (body_text.find('\n') != std::string::npos) {
      supported_ = false;
      return std::string();
    }
    std::string result = suite_introduction(expression);
    if (!body_text.empty()) result += " " + body_text;
    return result;
  }

  std::string flat_call(Call* call, int outer_precedence) {
    std::string result = flat(call->target(), PRECEDENCE_POSTFIX);
    for (auto argument : call->arguments()) {
      Expression* inner = peel_parentheses(argument);
      if (argument->is_NamedArgument()) {
        result += " " + flat_named_argument(argument->as_NamedArgument());
      } else if (argument->is_Parenthesis() &&
                 (inner->is_Block() || inner->is_Lambda())) {
        result += " (" + flat_suite(inner) + ")";
      } else if (argument->is_Block() || argument->is_Lambda()) {
        result += flat_suite(argument);
      } else if (needs_call_argument_parentheses(inner)) {
        result += " (" + flat(inner, PRECEDENCE_NONE) + ")";
      } else {
        result += " " + flat(argument, PRECEDENCE_NONE);
      }
    }
    return outer_precedence == PRECEDENCE_NONE
        ? result
        : "(" + result + ")";
  }

  template<typename T>
  std::string flat_elements(const char* opening,
                            const char* closing,
                            T elements) {
    std::string result = opening;
    for (int i = 0; i < elements.length(); i++) {
      if (i > 0) result += ", ";
      result += flat(elements[i], PRECEDENCE_NONE);
    }
    return result + closing;
  }

  std::string flat_map(LiteralMap* map) {
    if (map->keys().is_empty()) return "{:}";
    std::string result = "{";
    for (int i = 0; i < map->keys().length(); i++) {
      if (i > 0) result += ", ";
      result += flat(map->keys()[i], PRECEDENCE_NONE) + ": " +
          flat(map->values()[i], PRECEDENCE_NONE);
    }
    return result + "}";
  }

  bool needs_bitwise_parentheses(Token::Kind parent,
                                 Token::Kind child) const {
    if (!options_.parenthesize_mixed_bitwise) return false;
    if (!is_bitwise(parent) && !is_bitwise(child)) return false;
    if (Token::precedence(parent) == PRECEDENCE_ASSIGNMENT) return false;
    return parent != child;
  }

  std::string binary_operand(Expression* expression,
                             int outer_precedence,
                             Token::Kind parent_kind) {
    Expression* inner = peel_parentheses(expression);
    if (inner != null && inner->is_Binary() &&
        needs_bitwise_parentheses(
            parent_kind, inner->as_Binary()->kind())) {
      return "(" + flat(inner, PRECEDENCE_NONE) + ")";
    }
    return flat(expression, outer_precedence);
  }

  std::string flat_binary(Binary* binary, int outer_precedence) {
    Token::Kind kind = binary->kind();
    int precedence = Token::precedence(kind);
    bool parentheses =
        outer_precedence != PRECEDENCE_NONE && precedence <= outer_precedence;
    bool right_associative = is_right_associative(kind);
    int left_precedence = right_associative ? precedence : precedence - 1;
    int right_precedence = right_associative ? precedence - 1 : precedence;
    if (precedence == PRECEDENCE_ASSIGNMENT) {
      right_precedence = PRECEDENCE_NONE;
    }

    std::string result =
        binary_operand(binary->left(), left_precedence, kind) + " " +
        Token::symbol(kind).c_str() + " " +
        binary_operand(binary->right(), right_precedence, kind);
    return parentheses ? "(" + result + ")" : result;
  }

  std::string flat_ternary(If* expression, int outer_precedence) {
    std::string result = flat(expression->expression(), PRECEDENCE_CONDITIONAL) +
        " ? " + flat(expression->yes(), PRECEDENCE_NONE) + " : " +
        flat(expression->no(), PRECEDENCE_NONE);
    return outer_precedence == PRECEDENCE_NONE
        ? result
        : "(" + result + ")";
  }

  std::string flat(Expression* expression, int outer_precedence) {
    if (!supported_ || expression == null) return std::string();
    expression = peel_parentheses(expression);
    if (expression->is_Binary()) {
      return flat_binary(expression->as_Binary(), outer_precedence);
    }
    if (expression->is_Call()) {
      return flat_call(expression->as_Call(), outer_precedence);
    }
    if (expression->is_NamedArgument()) {
      return flat_named_argument(expression->as_NamedArgument());
    }
    if (expression->is_DeclarationLocal()) {
      return flat_local(expression->as_DeclarationLocal());
    }
    if (expression->is_Block() || expression->is_Lambda()) {
      return flat_suite(expression);
    }
    if (expression->is_LiteralList()) {
      return flat_elements(
          "[", "]", expression->as_LiteralList()->elements());
    }
    if (expression->is_LiteralByteArray()) {
      return flat_elements(
          "#[", "]", expression->as_LiteralByteArray()->elements());
    }
    if (expression->is_LiteralSet()) {
      return flat_elements(
          "{", "}", expression->as_LiteralSet()->elements());
    }
    if (expression->is_LiteralMap()) {
      return flat_map(expression->as_LiteralMap());
    }
    if (expression->is_Unary()) {
      Unary* unary = expression->as_Unary();
      std::string operation = Token::symbol(unary->kind()).c_str();
      if (!unary->prefix()) {
        return flat(unary->expression(), PRECEDENCE_POSTFIX) + operation;
      }
      Expression* operand = peel_parentheses(unary->expression());
      std::string operand_text;
      if (unary->kind() == Token::NOT && operand->is_Binary()) {
        operand_text = "(" + flat(operand, PRECEDENCE_NONE) + ")";
      } else {
        operand_text = flat(operand, PRECEDENCE_POSTFIX);
      }
      std::string result = operation +
          (unary->kind() == Token::NOT ? " " : "") + operand_text;
      return unary->kind() == Token::NOT &&
              outer_precedence != PRECEDENCE_NONE
          ? "(" + result + ")"
          : result;
    }
    if (expression->is_Dot()) {
      Dot* dot = expression->as_Dot();
      return receiver(dot->receiver()) + "." + source_text(dot->name());
    }
    if (expression->is_Index()) {
      Index* index = expression->as_Index();
      std::string result = receiver(index->receiver()) + "[";
      for (int i = 0; i < index->arguments().length(); i++) {
        if (i > 0) result += ", ";
        result += flat(index->arguments()[i], PRECEDENCE_NONE);
      }
      return result + "]";
    }
    if (expression->is_IndexSlice()) {
      IndexSlice* slice = expression->as_IndexSlice();
      std::string result = receiver(slice->receiver()) + "[";
      if (slice->from() != null) {
        result += flat(slice->from(), PRECEDENCE_NONE);
      }
      result += "..";
      if (slice->to() != null) result += flat(slice->to(), PRECEDENCE_NONE);
      return result + "]";
    }
    if (expression->is_Nullable()) {
      return flat(expression->as_Nullable()->type(), PRECEDENCE_POSTFIX) + "?";
    }
    if (expression->is_If()) {
      If* conditional = expression->as_If();
      if (conditional->yes() != null && conditional->yes()->is_Sequence()) {
        supported_ = false;
        return std::string();
      }
      return flat_ternary(conditional, outer_precedence);
    }
    if (expression->is_Identifier() || expression->is_LiteralNull() ||
        expression->is_LiteralUndefined() ||
        expression->is_LiteralBoolean() ||
        expression->is_LiteralInteger() ||
        expression->is_LiteralCharacter() ||
        expression->is_LiteralString() ||
        expression->is_LiteralStringInterpolation() ||
        expression->is_LiteralFloat()) {
      std::string result = source_text(expression);
      if (result.find('\n') != std::string::npos ||
          result.find('\r') != std::string::npos) {
        supported_ = false;
        return std::string();
      }
      return result;
    }
    supported_ = false;
    return std::string();
  }

  void flatten_chain(Binary* binary,
                     Token::Kind kind,
                     std::vector<Expression*>* operands) {
    if (is_right_associative(kind)) {
      operands->push_back(binary->left());
      Expression* right = binary->right();
      if (!right->is_Parenthesis() && right->is_Binary() &&
          right->as_Binary()->kind() == kind) {
        flatten_chain(right->as_Binary(), kind, operands);
      } else {
        operands->push_back(right);
      }
      return;
    }

    Expression* left = binary->left();
    if (!left->is_Parenthesis() && left->is_Binary() &&
        left->as_Binary()->kind() == kind) {
      flatten_chain(left->as_Binary(), kind, operands);
    } else {
      operands->push_back(left);
    }
    operands->push_back(binary->right());
  }

  FormatOutput broken_binary(Binary* binary, int outer_precedence) {
    Token::Kind kind = binary->kind();
    int precedence = Token::precedence(kind);
    bool parentheses =
        outer_precedence != PRECEDENCE_NONE && precedence <= outer_precedence;
    std::vector<Expression*> operands;
    flatten_chain(binary, kind, &operands);
    std::string operation = Token::symbol(kind).c_str();

    FormatOutput result = FormatOutput::single_line(
        (parentheses ? "(" : "") + flat(operands[0], precedence));
    bool trailing = is_logical(kind);
    if (trailing && operands.size() > 1) result.append(" " + operation);
    for (int i = 1; i < static_cast<int>(operands.size()); i++) {
      bool last = i + 1 == static_cast<int>(operands.size());
      std::string operand = flat(operands[i], precedence);
      result.add_line(
          style_.continuation_step,
          trailing ? operand + (last ? "" : " " + operation)
                   : operation + " " + operand);
    }
    if (parentheses) result.append(")");
    return result;
  }

  std::string call_argument(Expression* argument) {
    if (argument->is_NamedArgument()) {
      return flat_named_argument(argument->as_NamedArgument());
    }
    Expression* inner = peel_parentheses(argument);
    if (argument->is_Parenthesis() &&
        (inner->is_Block() || inner->is_Lambda())) {
      return "(" + flat_suite(inner) + ")";
    }
    if (needs_call_argument_parentheses(inner)) {
      return "(" + flat(inner, PRECEDENCE_NONE) + ")";
    }
    return flat(argument, PRECEDENCE_NONE);
  }

  FormatOutput broken_call(Call* call) {
    FormatOutput result = FormatOutput::single_line(
        flat(call->target(), PRECEDENCE_POSTFIX));
    for (auto argument : call->arguments()) {
      result.add_line(style_.continuation_step, call_argument(argument));
    }
    return result;
  }

  bool call_requires_suite_shape(Call* call) {
    for (int i = 0; i < call->arguments().length(); i++) {
      Expression* argument = call->arguments()[i];
      Expression* suite = suite_value(argument);
      if (suite == null) continue;
      Sequence* body = suite->is_Block()
          ? suite->as_Block()->body()
          : suite->as_Lambda()->body();
      if (body->expressions().length() != 1 ||
          i + 1 != call->arguments().length()) return true;
      std::string body_text;
      if (!format_sequence(body,
                           source_,
                           0,
                           &body_text,
                           style_,
                           options_)) {
        supported_ = false;
        return true;
      }
      if (body_text.find('\n') != std::string::npos) return true;
    }
    return false;
  }

  std::string named_suite_prefix(NamedArgument* named) {
    std::string result = "--";
    if (named->inverted()) result += "no-";
    return result + source_text(named->name()) + "=";
  }

  void append_suite_body(FormatOutput* result,
                         int header_indentation,
                         int body_indentation,
                         const std::string& header,
                         const std::string& body_text) {
    size_t first_newline = body_text.find('\n');
    if (first_newline == std::string::npos) {
      result->add_line(header_indentation,
                       header + (body_text.empty() ? "" : " " + body_text));
      return;
    }
    result->add_line(header_indentation, header);
    size_t line_start = 0;
    while (line_start < body_text.size()) {
      size_t line_end = body_text.find('\n', line_start);
      if (line_end == std::string::npos) line_end = body_text.size();
      size_t non_space = line_start;
      while (non_space < line_end && body_text[non_space] == ' ') non_space++;
      result->add_line(
          body_indentation + static_cast<int>(non_space - line_start),
          body_text.substr(non_space, line_end - non_space));
      line_start = line_end + 1;
    }
  }

  bool segmented_suite_call(Call* call, FormatOutput* result) {
    std::string first = flat(call->target(), PRECEDENCE_POSTFIX);
    int first_suite = -1;
    for (int i = 0; i < call->arguments().length(); i++) {
      if (suite_value(call->arguments()[i]) != null) {
        first_suite = i;
        break;
      }
      first += " " + call_argument(call->arguments()[i]);
    }
    if (first_suite < 0) return false;
    *result = FormatOutput::single_line(first);

    for (int i = first_suite; i < call->arguments().length(); i++) {
      Expression* argument = call->arguments()[i];
      Expression* suite = suite_value(argument);
      if (suite == null) {
        result->add_line(style_.continuation_step, call_argument(argument));
        continue;
      }
      Sequence* body = suite->is_Block()
          ? suite->as_Block()->body()
          : suite->as_Lambda()->body();
      std::string body_text;
      if (!format_sequence(body,
                           source_,
                           0,
                           &body_text,
                           style_,
                           options_)) return false;
      append_suite_body(
          result,
          style_.continuation_step,
          style_.continuation_step + style_.indentation_step,
          (argument->is_NamedArgument()
              ? named_suite_prefix(argument->as_NamedArgument())
              : std::string()) + suite_introduction(suite),
          body_text);
    }
    return true;
  }

  bool suite_call(Call* call, FormatOutput* result) {
    std::string first = flat(call->target(), PRECEDENCE_POSTFIX);
    Expression* suite = null;
    for (int i = 0; i < call->arguments().length(); i++) {
      Expression* argument = call->arguments()[i];
      Expression* candidate = suite_value(argument);
      if (candidate == null) {
        first += " " + call_argument(argument);
        continue;
      }
      // A suite owns the remainder of its indentation level. The parser does
      // not normally produce later arguments, but refusing this shape keeps
      // the formatter conservative if the grammar grows.
      if (suite != null || i + 1 != call->arguments().length()) return false;
      suite = candidate;
      if (argument->is_NamedArgument()) {
        first += " " + named_suite_prefix(argument->as_NamedArgument());
      }
      first += suite_introduction(suite);
    }
    if (suite == null) return false;

    Sequence* body = suite->is_Block()
        ? suite->as_Block()->body()
        : suite->as_Lambda()->body();
    std::string body_text;
    if (!format_sequence(body,
                         source_,
                         0,
                         &body_text,
                         style_,
                         options_)) return false;

    *result = FormatOutput::single_line(first);
    size_t line_start = 0;
    while (line_start < body_text.size()) {
      size_t line_end = body_text.find('\n', line_start);
      if (line_end == std::string::npos) line_end = body_text.size();
      size_t non_space = line_start;
      while (non_space < line_end && body_text[non_space] == ' ') non_space++;
      result->add_line(
          style_.indentation_step +
              static_cast<int>(non_space - line_start),
          body_text.substr(non_space, line_end - non_space));
      line_start = line_end + 1;
    }
    return true;
  }

  FormatOutput named_suffix_call(Call* call, int first_named) {
    std::string first = flat(call->target(), PRECEDENCE_POSTFIX);
    for (int i = 0; i < first_named; i++) {
      first += " " + call_argument(call->arguments()[i]);
    }
    FormatOutput result = FormatOutput::single_line(first);
    for (int i = first_named; i < call->arguments().length(); i++) {
      result.add_line(
          style_.continuation_step, call_argument(call->arguments()[i]));
    }
    return result;
  }

  FormatOutput backslash_call(Call* call, int split_at) {
    std::string first = flat(call->target(), PRECEDENCE_POSTFIX);
    for (int i = 0; i < split_at; i++) {
      first += " " + call_argument(call->arguments()[i]);
    }
    first += " \\";
    std::string second;
    for (int i = split_at; i < call->arguments().length(); i++) {
      if (!second.empty()) second += " ";
      second += call_argument(call->arguments()[i]);
    }
    FormatOutput result = FormatOutput::single_line(first);
    result.add_line(style_.continuation_step, second);
    return result;
  }

  int first_named_argument(Call* call) {
    for (int i = 0; i < call->arguments().length(); i++) {
      if (call->arguments()[i]->is_NamedArgument()) return i;
    }
    return -1;
  }

  int estimated_call_argument_width(Expression* argument) {
    return estimated_flat_width(argument);
  }

  int best_backslash_split(Call* call) {
    if (call->arguments().length() < 2 || first_named_argument(call) >= 0) {
      return -1;
    }
    int target = estimated_flat_width(call->target());
    if (target < 0) return -1;
    std::vector<int> arguments;
    for (auto argument : call->arguments()) {
      int width = estimated_call_argument_width(argument);
      if (width < 0 || suite_value(argument) != null) return -1;
      arguments.push_back(width);
    }

    int best_split = -1;
    int best_extent = std::numeric_limits<int>::max();
    for (int split = 1; split < static_cast<int>(arguments.size()); split++) {
      int first = target + 2;
      for (int i = 0; i < split; i++) first += 1 + arguments[i];
      int second = style_.continuation_step;
      for (int i = split; i < static_cast<int>(arguments.size()); i++) {
        second += (i == split ? 0 : 1) + arguments[i];
      }
      int extent = std::max(first, second);
      if (extent < best_extent) {
        best_extent = extent;
        best_split = split;
      }
    }
    return is_flat_acceptable(best_extent,
                              base_indentation_,
                              1,
                              1,
                              style_.backslash_penalty,
                              style_)
        ? best_split
        : -1;
  }

  FormatOutput broken_collection(const std::string& opening,
                                 const std::string& closing,
                                 const std::vector<std::string>& items) {
    FormatOutput result = FormatOutput::single_line(opening);
    std::string row;
    int available = preferred_extent_at(base_indentation_, style_) -
        style_.indentation_step;
    for (const auto& item : items) {
      std::string addition = item + ",";
      int addition_width = utf8_code_point_width(addition);
      int row_width = utf8_code_point_width(row);
      if (!row.empty() && row_width + 1 + addition_width > available) {
        result.add_line(style_.indentation_step, row);
        row.clear();
      }
      if (!row.empty()) row += " ";
      row += addition;
    }
    if (!row.empty()) result.add_line(style_.indentation_step, row);
    result.add_line(0, closing);
    return result;
  }

  std::vector<std::string> collection_items(Expression* expression) {
    std::vector<std::string> result;
    if (expression->is_LiteralList()) {
      for (auto element : expression->as_LiteralList()->elements()) {
        result.push_back(flat(element, PRECEDENCE_NONE));
      }
    } else if (expression->is_LiteralByteArray()) {
      for (auto element : expression->as_LiteralByteArray()->elements()) {
        result.push_back(flat(element, PRECEDENCE_NONE));
      }
    } else if (expression->is_LiteralSet()) {
      for (auto element : expression->as_LiteralSet()->elements()) {
        result.push_back(flat(element, PRECEDENCE_NONE));
      }
    } else {
      LiteralMap* map = expression->as_LiteralMap();
      for (int i = 0; i < map->keys().length(); i++) {
        result.push_back(flat(map->keys()[i], PRECEDENCE_NONE) + ": " +
            flat(map->values()[i], PRECEDENCE_NONE));
      }
    }
    return result;
  }

  std::vector<int> collection_item_widths(Expression* expression) {
    std::vector<int> result;
    if (expression->is_LiteralList()) {
      for (auto element : expression->as_LiteralList()->elements()) {
        result.push_back(estimated_flat_width(element));
      }
    } else if (expression->is_LiteralByteArray()) {
      for (auto element : expression->as_LiteralByteArray()->elements()) {
        result.push_back(estimated_flat_width(element));
      }
    } else if (expression->is_LiteralSet()) {
      for (auto element : expression->as_LiteralSet()->elements()) {
        result.push_back(estimated_flat_width(element));
      }
    } else {
      LiteralMap* map = expression->as_LiteralMap();
      for (int i = 0; i < map->keys().length(); i++) {
        int key = estimated_flat_width(map->keys()[i]);
        int value = estimated_flat_width(map->values()[i]);
        result.push_back(key < 0 || value < 0 ? -1 : key + 2 + value);
      }
    }
    return result;
  }

  int estimated_collection_rows(const std::vector<int>& widths) {
    int available = preferred_extent_at(base_indentation_, style_) -
        style_.indentation_step;
    int rows = 0;
    int row_width = 0;
    for (int width : widths) {
      if (width < 0) return widths.size();
      int addition = width + 1;
      if (row_width > 0 && row_width + 1 + addition > available) {
        rows++;
        row_width = 0;
      }
      row_width += (row_width == 0 ? 0 : 1) + addition;
    }
    return rows + (row_width == 0 ? 0 : 1);
  }

  int estimated_collection_width(Expression* expression,
                                 const std::vector<int>& widths) {
    int result = expression->is_LiteralByteArray() ? 3 : 2;
    for (int i = 0; i < static_cast<int>(widths.size()); i++) {
      if (widths[i] < 0) return -1;
      result += widths[i] + (i == 0 ? 0 : 2);
    }
    return result;
  }

  bool render_flat(Expression* expression,
                   int outer_precedence,
                   FormatOutput* result) {
    std::string text = flat(expression, outer_precedence);
    if (!supported_) return false;
    *result = FormatOutput::single_line(text);
    return true;
  }

  bool format(Expression* expression,
              int outer_precedence,
              FormatOutput* result) {
    Expression* inner = peel_parentheses(expression);
    if ((inner->is_Block() || inner->is_Lambda()) &&
        outer_precedence == PRECEDENCE_NONE) {
      Sequence* body = inner->is_Block()
          ? inner->as_Block()->body()
          : inner->as_Lambda()->body();
      std::string body_text;
      if (!format_sequence(body,
                           source_,
                           0,
                           &body_text,
                           style_,
                           options_)) {
        supported_ = false;
        return false;
      }
      if (body_text.find('\n') != std::string::npos) {
        FormatOutput suite_output = FormatOutput::single_line(
            suite_introduction(inner));
        size_t line_start = 0;
        while (line_start < body_text.size()) {
          size_t line_end = body_text.find('\n', line_start);
          if (line_end == std::string::npos) line_end = body_text.size();
          size_t non_space = line_start;
          while (non_space < line_end && body_text[non_space] == ' ') {
            non_space++;
          }
          suite_output.add_line(
              style_.indentation_step +
                  static_cast<int>(non_space - line_start),
              body_text.substr(non_space, line_end - non_space));
          line_start = line_end + 1;
        }
        *result = std::move(suite_output);
        return true;
      }
    }
    if (inner->is_Call() && outer_precedence == PRECEDENCE_NONE &&
        call_requires_suite_shape(inner->as_Call())) {
      FormatOutput suite_output;
      Call* call = inner->as_Call();
      bool has_nonfinal_suite = false;
      for (int i = 0; i + 1 < call->arguments().length(); i++) {
        if (suite_value(call->arguments()[i]) != null) {
          has_nonfinal_suite = true;
          break;
        }
      }
      bool formatted = has_nonfinal_suite
          ? segmented_suite_call(call, &suite_output)
          : suite_call(call, &suite_output);
      if (formatted) {
        *result = std::move(suite_output);
      } else {
        supported_ = false;
      }
      return formatted;
    }

    int flat_width = estimated_flat_width(expression);
    if (flat_width < 0) return render_flat(expression, outer_precedence, result);

    if (inner->is_Binary() &&
        Token::precedence(inner->as_Binary()->kind()) !=
            PRECEDENCE_ASSIGNMENT) {
      Binary* binary = inner->as_Binary();
      std::vector<Expression*> operands;
      flatten_chain(binary, binary->kind(), &operands);
      int splits = std::max(1, static_cast<int>(operands.size()) - 1);
      if (!is_flat_acceptable(flat_width,
                              base_indentation_,
                              splits,
                              splits,
                              0,
                              style_)) {
        *result = broken_binary(binary, outer_precedence);
        return supported_;
      }
    } else if (inner->is_Call() && outer_precedence == PRECEDENCE_NONE) {
      Call* call = inner->as_Call();
      if (!call->arguments().is_empty()) {
        int first_named = first_named_argument(call);
        int backslash_split = best_backslash_split(call);
        int broken_lines = first_named >= 0
            ? call->arguments().length() - first_named
            : backslash_split >= 0 ? 1 : call->arguments().length();
        int broken_penalty = backslash_split >= 0
            ? style_.backslash_penalty
            : 0;
        if (!is_flat_acceptable(flat_width,
                                base_indentation_,
                                broken_lines,
                                broken_lines,
                                broken_penalty,
                                style_)) {
          if (first_named >= 0) {
            int prefix_width = estimated_flat_width(call->target());
            for (int i = 0; i < first_named; i++) {
              prefix_width += 1 +
                  estimated_call_argument_width(call->arguments()[i]);
            }
            *result = is_flat_acceptable(prefix_width,
                                         base_indentation_,
                                         1,
                                         1,
                                         0,
                                         style_)
                ? named_suffix_call(call, first_named)
                : broken_call(call);
          } else if (backslash_split >= 0) {
            *result = backslash_call(call, backslash_split);
          } else {
            *result = broken_call(call);
          }
          return supported_;
        }
      }
    } else if (inner->is_LiteralList() ||
               inner->is_LiteralByteArray() ||
               inner->is_LiteralSet() ||
               inner->is_LiteralMap()) {
      std::vector<int> widths = collection_item_widths(inner);
      if (!widths.empty()) {
        int collection_width = estimated_collection_width(inner, widths);
        int rows = estimated_collection_rows(widths);
        if (!is_flat_acceptable(collection_width,
                                base_indentation_,
                                rows + 1,
                                widths.size(),
                                0,
                                style_)) {
          std::vector<std::string> items = collection_items(inner);
          std::string opening = inner->is_LiteralList()
              ? "["
              : inner->is_LiteralByteArray() ? "#[" : "{";
          std::string closing = inner->is_LiteralList() ||
                  inner->is_LiteralByteArray()
              ? "]"
              : "}";
          *result = broken_collection(opening, closing, items);
          return supported_;
        }
      }
    } else if (inner->is_If()) {
      If* conditional = inner->as_If();
      if (conditional->yes() == null ||
          !conditional->yes()->is_Sequence()) {
        if (!is_flat_acceptable(flat_width,
                                base_indentation_,
                                2,
                                2,
                                0,
                                style_)) {
          *result = FormatOutput::single_line(
              flat(conditional->expression(), PRECEDENCE_CONDITIONAL));
          result->add_line(
              style_.continuation_step,
              "? " + flat(conditional->yes(), PRECEDENCE_NONE));
          result->add_line(
              style_.continuation_step,
              ": " + flat(conditional->no(), PRECEDENCE_NONE));
          return supported_;
        }
      }
    }
    return render_flat(expression, outer_precedence, result);
  }
};

} // namespace

bool format_expression_flat(Expression* expression,
                            Source* source,
                            std::string* result,
                            const FormatExpressionOptions& options) {
  ASSERT(source != null);
  ExpressionPrinter printer(source, 0, FormatStyle(), options);
  return printer.run_flat(expression, result);
}

bool format_expression(Expression* expression,
                       Source* source,
                       int base_indentation,
                       FormatOutput* result,
                       const FormatStyle& style,
                       const FormatExpressionOptions& options) {
  ASSERT(source != null);
  ASSERT(base_indentation >= 0);
  ExpressionPrinter printer(source, base_indentation, style, options);
  return printer.run(expression, result);
}

} // namespace compiler
} // namespace toit
