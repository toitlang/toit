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

#include "../top.h"
#include "ast.h"
#include "sources.h"
#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

Expression* peel_parentheses(Expression* expression) {
  while (expression->is_Parenthesis()) {
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

class ExpressionLowering {
 public:
  ExpressionLowering(Source* source, LayoutBuilder* layouts,
                     LogicalOperatorBindings* bindings,
                     SyntaxProtection* syntax,
                     const FormatStyle& style)
      : source_(source)
      , layouts_(layouts)
      , bindings_(bindings)
      , syntax_(syntax)
      , style_(style) {}

  LoweredExpression lower(Expression* expression, int outer_precedence) {
    ASSERT(expression != null);

    // Parenthesis nodes describe how the input happened to spell the tree.
    // Precedence and line topology below describe how the output must spell
    // it. Peeling here is the small canonicalization step discussed in the
    // formatter design; it does not need a separate AST rewrite pass.
    expression = peel_parentheses(expression);

    LayoutMarker start = layouts_->marker();
    LayoutMarker end = layouts_->marker();
    Layout* contents = lower_contents(expression, outer_precedence);
    LoweredExpression result = {
        layouts_->concat(
            {layouts_->mark(start), contents, layouts_->mark(end)}),
        {start, end},
    };
    if (requires_parentheses_in(expression, outer_precedence)) {
      syntax_->require_parentheses(result.span);
    }
    return result;
  }

 private:
  Source* source_;
  LayoutBuilder* layouts_;
  LogicalOperatorBindings* bindings_;
  SyntaxProtection* syntax_;
  const FormatStyle& style_;

  bool requires_parentheses_in(Expression* expression,
                               int outer_precedence) const {
    if (outer_precedence == PRECEDENCE_NONE) return false;
    if (expression->is_Binary()) {
      return Token::precedence(expression->as_Binary()->kind()) <=
             outer_precedence;
    }
    if (expression->is_Call()) return PRECEDENCE_CALL <= outer_precedence;
    if (expression->is_Unary()) {
      int precedence = expression->as_Unary()->kind() == Token::NOT
                           ? PRECEDENCE_NOT
                           : PRECEDENCE_POSTFIX;
      return precedence <= outer_precedence;
    }
    // Atoms do not need a made-up precedence above POSTFIX: their grammar
    // category directly tells us that they fit every operator context. This
    // explicit case also prevents an unsupported node from silently being
    // treated as an atom.
    if (is_atomic(expression)) return false;
    if (expression->is_Error()) UNREACHABLE();
    UNREACHABLE();
  }

  static bool is_atomic(Expression* expression) {
    return expression->is_Identifier() || expression->is_LiteralNull() ||
           expression->is_LiteralUndefined() ||
           expression->is_LiteralBoolean() || expression->is_LiteralInteger() ||
           expression->is_LiteralCharacter() ||
           (expression->is_LiteralString() &&
            !expression->as_LiteralString()->is_multiline()) ||
           expression->is_LiteralFloat();
  }

  std::string source_text(Node* node) const {
    Source::Range range = node->full_range();
    ASSERT(range.is_valid());
    int from = source_->offset_in_source(range.from());
    int to = source_->offset_in_source(range.to());
    ASSERT(from >= 0 && to >= from);
    return std::string(reinterpret_cast<const char*>(source_->text()) + from,
                       to - from);
  }

  Layout* lower_contents(Expression* expression, int outer_precedence) {
    if (expression->is_Binary()) {
      return lower_binary(expression->as_Binary(), outer_precedence);
    }
    if (expression->is_Unary()) {
      return lower_unary(expression->as_Unary(), outer_precedence);
    }
    if (expression->is_Call()) {
      return lower_call(expression->as_Call(), outer_precedence);
    }

    // Atomic nodes retain their exact token bytes. This preserves spelling
    // choices that are data rather than layout, for example `0xff`, string
    // escapes, and identifier dashes.
    if (is_atomic(expression)) {
      return layouts_->text(source_text(expression));
    }

    // Error nodes are malformed source, not an accidental atomic fallback.
    // The end-to-end formatter will freeze their containing region verbatim.
    // Every valid expression kind must be added explicitly above; reaching
    // this point is a missing lowering rule rather than permission to copy an
    // arbitrary subtree (which could retain source newlines or parentheses).
    if (expression->is_Error()) UNREACHABLE();
    UNREACHABLE();
  }

  Layout* lower_unary(Unary* unary, int outer_precedence) {
    LoweredExpression operand = lower(unary->expression(), PRECEDENCE_POSTFIX);
    std::vector<Layout*> parts;
    std::string symbol = Token::symbol(unary->kind()).c_str();
    if (unary->prefix()) {
      parts.push_back(
          layouts_->text(unary->kind() == Token::NOT ? symbol + " " : symbol));
      parts.push_back(operand.layout);
    } else {
      parts.push_back(operand.layout);
      parts.push_back(layouts_->text(symbol));
    }

    // `lower` compares this node's precedence with its context after the
    // public expression span has been installed. No second marker pair is
    // needed merely to parenthesize a unary expression.
    return layouts_->concat(std::move(parts));
  }

  Layout* lower_binary(Binary* binary, int outer_precedence) {
    Token::Kind kind = binary->kind();
    int precedence = Token::precedence(kind);
    bool right_associative = is_right_associative(kind);

    // Equal-precedence protection is placed on the side that would otherwise
    // reassociate. Thus `(a - b) - c` needs no parens, while `a - (b - c)`
    // does. Right-associative operators mirror those contexts.
    int left_context = right_associative ? precedence : precedence - 1;
    int right_context = right_associative ? precedence - 1 : precedence;
    if (precedence == PRECEDENCE_ASSIGNMENT) {
      // The right side of an assignment is parsed as a full expression.
      right_context = PRECEDENCE_NONE;
    }

    LoweredExpression left = lower(binary->left(), left_context);
    LoweredExpression right = lower(binary->right(), right_context);
    std::string symbol = Token::symbol(kind).c_str();
    Layout* contents;
    if (is_logical(kind)) {
      // The regular layout uses the conventional leading-operator form. It
      // deliberately offers a second legal gap after the operator, allowing a
      // later repair to produce the preferred mixed-logical shape:
      //
      //     foo or
      //         bar and gee
      //
      // If the narrow pattern does not match, this remains ordinary correct
      // formatting rather than special logic embedded in generic lowering.
      LayoutGap before_operator = layouts_->gap();
      LayoutGap after_operator = layouts_->gap();
      contents = layouts_->group(layouts_->concat({
          left.layout,
          layouts_->indent(style_.continuation_step,
                           layouts_->concat({
                               layouts_->line(before_operator),
                               layouts_->text(symbol),
                               layouts_->space(after_operator),
                               right.layout,
                           })),
      }));
      bindings_->record(binary, before_operator, after_operator);
    } else {
      // Other binary chains use a leading operator on continuation lines so
      // their left-associative parse is visible.
      contents = layouts_->group(layouts_->concat({
          left.layout,
          layouts_->indent(style_.continuation_step,
                           layouts_->concat({
                               layouts_->line(),
                               layouts_->text(symbol + " "),
                               right.layout,
                           })),
      }));
    }

    return contents;
  }

  Layout* lower_call(Call* call, int outer_precedence) {
    LoweredExpression target = lower(call->target(), PRECEDENCE_POSTFIX);
    std::vector<Layout*> parts = {target.layout};
    for (Expression* argument_node : call->arguments()) {
      LoweredExpression argument = lower(argument_node, PRECEDENCE_NONE);
      parts.push_back(
          layouts_->indent(style_.continuation_step, layouts_->concat({
                                                         layouts_->line(),
                                                         argument.layout,
                                                     })));

      // Calls consume following same-line expressions greedily. In
      // `outer (inner 1)`, parentheses keep `inner 1` one argument. Once the
      // argument moves to its own continuation line, indentation is already a
      // delimiter and the canonical output can omit them.
      if (peel_parentheses(argument_node)->is_Call()) {
        syntax_->require_parentheses_unless_break_between(argument.span,
                                                          target.span.end);
      }
    }
    return layouts_->group(layouts_->concat(std::move(parts)));
  }
};

} // namespace

LoweredExpression lower_expression(Expression* expression, Source* source,
                                   LayoutBuilder* layouts,
                                   LogicalOperatorBindings* bindings,
                                   SyntaxProtection* syntax,
                                   const FormatStyle& style) {
  ASSERT(source != null);
  ASSERT(layouts != null);
  ASSERT(bindings != null);
  ASSERT(syntax != null);
  return ExpressionLowering(source, layouts, bindings, syntax, style)
      .lower(expression, PRECEDENCE_NONE);
}

} // namespace compiler
} // namespace toit
