// Copyright (C) 2018 Toitware ApS.
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

#include "parser.h"

#include "diagnostic.h"
#include "symbol_canonicalizer.h"
#include "toitdoc_parser.h"
#include "../flags.h"
#include "../printing.h"

namespace toit {
namespace compiler {

using namespace ast;

static inline bool is_delimiter(Token::Kind token, bool allow_colon, bool allow_semicolon) {
  if (!allow_colon && token == Token::COLON) return true;
  if (!allow_semicolon && token == Token::SEMICOLON) return true;
  return token == Token::DEDENT ||
      token == Token::COMMA ||
      token == Token::RPAREN ||
      token == Token::RBRACE ||
      token == Token::RBRACK ||
      token == Token::ELSE ||
      token == Token::CONDITIONAL ||
      token == Token::FINALLY ||
      token == Token::SLICE ||
      token == Token::EOS;
}

static inline bool is_call_delimiter(Token::Kind token, bool allow_colon) {
  return is_delimiter(token, allow_colon, false) ||
    token == Token::LOGICAL_OR ||
    token == Token::LOGICAL_AND;
}

static bool is_eol(Token::Kind token) {
  return token == Token::NEWLINE || token == Token::DEDENT || token == Token::EOS;
}

/// A range from the previous range's to, to the EOL. If the range would be empty,
///   returns the eol_range.
static Source::Range eol_range(Source::Range previous_range,
                               Source::Range eol_range) {
  if (!previous_range.to().is_before(eol_range.to())) return eol_range;
  return Source::Range(previous_range.to(), eol_range.from());
}

template<typename T>
static inline T add_range(Source::Range range, Source* source, T node) {
  node->set_range(range);
  return node;
}

template<typename T>
static inline T add_range(std::pair<int, int> range, Source* source, T node) {
  node->set_range(source->range(range.first, range.second));
  return node;
}

class ParserPeeker {
 public:
  ParserPeeker(Parser* parser) : parser_(parser) {}

  Token::Kind current_token() { return current_state().token; }

  Parser::State current_state() {
    while (parser_->peek_state(n).token == Token::NEWLINE) n++;
    return parser_->peek_state(n);
  }

  void consume() { n++; }

 private:
  Parser* parser_;
  int n = 0;
};

#define NEW_NODE(constructor, range) \
  add_range(range, source_, _new constructor)

void Parser::report_error(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(range, format, arguments);
  va_end(arguments);
}

void Parser::report_error(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(current_range(), format, arguments);
  va_end(arguments);
}

Unit* Parser::parse_unit(Source* override_source) {
  scanner()->skip_hash_bang_line();

  ListBuilder<Import*> imports;
  ListBuilder<Export*> exports;
  ListBuilder<Node*> declarations;
  while (current_token() != Token::EOS) {
    if (current_token() == Token::IMPORT) {
      if (!declarations.is_empty()) {
        diagnostics()->start_group();
        report_error("Imports must be before declarations");
        diagnostics()->report_note(declarations[0]->range(), "Earlier declaration");
        diagnostics()->end_group();
      }
      imports.add(parse_import());
      continue;
    }
    if (current_token() == Token::EXPORT) {
      if (!declarations.is_empty()) {
        diagnostics()->start_group();
        report_error("Exports must be before declarations");
        diagnostics()->report_note(declarations[0]->range(), "Earlier declaration");
        diagnostics()->end_group();
      }
      exports.add(parse_export());
      continue;
    }
    bool is_abstract = optional(Token::ABSTRACT);
    if (current_token() == Token::CLASS) {
      declarations.add(parse_class_interface_or_monitor(is_abstract));
    } else if (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::monitor) {
      declarations.add(parse_class_interface_or_monitor(is_abstract));
    } else if (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::interface_) {
      declarations.add(parse_class_interface_or_monitor(is_abstract));
    } else {
      declarations.add(parse_declaration(is_abstract));
    }
  }

  auto result = NEW_NODE(Unit(override_source == null ? source_ : override_source,
                              imports.build(),
                              exports.build(),
                              declarations.build()),
                              std::make_pair(0, 0));
  attach_toitdoc(result,
                 scanner()->comments(),
                 source_,
                 scanner()->symbol_canonicalizer(),
                 diagnostics());
  if (!check_tree_height(result)) {
    // Clear the declarations to avoid follow-up stack-overflows.
    result->set_declarations(List<Node*>());
  }
  return result;
}

ToitdocReference* Parser::parse_toitdoc_reference(int* end_offset) {
  if (current_token() == Token::LPAREN) {
    return parse_toitdoc_signature_reference(end_offset);
  }
  return parse_toitdoc_identifier_reference(end_offset);
}

/// Whether the current call is allowed to consume a colon or double-colon.
///
/// This function is called, when a call encounters a ':'/'::' followed by a newline
/// that is sufficiently indented, so that it could be an argument to the call.
///
///     foo bar:
///       block_body
///
/// The difficulty arises because there might be multiple candidates:
///
///     x := true ? foo:
///       body_or_else
///
/// When there is a newline, Toit considers the *first* colon-consuming construct to
/// be the winner. (There are exceptions when there are delimiters).
///
/// The given [kinds] are the constructs that are at the same line as the call.
/// For example, in `if true: call:` the `kinds` would contains `IF` and `CALL`.
/// "Line" may not be literally a line, if there is an operator, or if there are
/// delimiters:
///
///  foo 3
///     + bar:  // <= Checking whether we are allowed to consume this ':' for bar.
///    body
///  In this case the [kinds] of the "line" contains `Call`, `Operator` and `Call`.
///
/// A call is allowed to consume the token, if there is no other colon-consuming
/// construct in the same line, *and* there is no separating/delimiting construct
/// in between.
///
/// The main-difference between ':' and '::' is that constructs like `if`,
/// `while`, ... don't consume double-colons and therefore don't take precedence
/// over a call on the last line.

bool Parser::allowed_to_consume(Token::Kind token) {
  auto& stack = indentation_stack_;

  ASSERT(token == Token::COLON || token == Token::DOUBLE_COLON);
  ASSERT(!stack.is_empty());
  ASSERT(stack.top_kind() == IndentationStack::Kind::CALL);

  int top_indentation = stack.top_indentation();

  // Skip the last call entry.
  for (int i = stack.size() - 2; i > 0; i--) {
    // We only look at the constructs that are on the same line.
    auto level = stack.indentation_at(i);
    if (level != top_indentation) break;

    auto kind = stack.kind_at(i);
    switch (kind) {
      case IndentationStack::IMPORT:
      case IndentationStack::EXPORT:
      case IndentationStack::CLASS:
      case IndentationStack::PRIMITIVE:
      case IndentationStack::DECLARATION_SIGNATURE:
        UNREACHABLE();

      case IndentationStack::IF_BODY:
      case IndentationStack::WHILE_BODY:
      case IndentationStack::FOR_INIT:
      case IndentationStack::FOR_CONDITION:
      case IndentationStack::FOR_BODY:
      case IndentationStack::CONDITIONAL_ELSE:
      case IndentationStack::DECLARATION:
      case IndentationStack::ASSIGNMENT:
      case IndentationStack::LOGICAL:
      case IndentationStack::SEQUENCE:
      case IndentationStack::CONDITIONAL:
        continue;

      case IndentationStack::IF_CONDITION:
      case IndentationStack::WHILE_CONDITION:
      case IndentationStack::FOR_UPDATE:
      case IndentationStack::CONDITIONAL_THEN:
        if (token == Token::DOUBLE_COLON) continue;
        return false;

      case IndentationStack::CALL:
        return false;

      case IndentationStack::BLOCK:
      case IndentationStack::DELIMITED:
      case IndentationStack::LITERAL:
      case IndentationStack::TRY:
        return true;
    }
  }
  return true;
}

/// Returns whether there is a consumer of the given [token].
///
/// Also provides the [next_line_indentation], which is necessary for `:`.
///
/// This function is for better error messages and may be over conservative.
bool Parser::consumer_exists(Token::Kind token, int next_line_indentation) {
  ASSERT(is_delimiter(token, false, false) || token == Token::DOUBLE_COLON);
  ASSERT(next_line_indentation >= 0 || next_line_indentation == -1);
  ASSERT(token != Token::COLON || next_line_indentation >= 0);

  if (token == Token::DEDENT) return true;
  if (token == Token::SEMICOLON) return true;

  auto& stack = indentation_stack_;

  for (int i = stack.size() - 1; i > 0; i--) {
    auto kind = stack.kind_at(i);
    switch (kind) {
      case IndentationStack::IMPORT:
      case IndentationStack::EXPORT:
      case IndentationStack::PRIMITIVE:
        UNREACHABLE();

      case IndentationStack::IF_BODY:
        // TODO(florian): we should make a distinction between 'then' and 'else' branch.
        if (token == Token::ELSE) return true;
        continue;

      case IndentationStack::WHILE_BODY:
      case IndentationStack::FOR_BODY:
      case IndentationStack::CONDITIONAL_ELSE:
      case IndentationStack::DECLARATION:
      case IndentationStack::ASSIGNMENT:
      case IndentationStack::LOGICAL:
      case IndentationStack::BLOCK:
      case IndentationStack::SEQUENCE:
      case IndentationStack::CONDITIONAL:
        continue;

      case IndentationStack::DECLARATION_SIGNATURE:
      case IndentationStack::CONDITIONAL_THEN:
      case IndentationStack::WHILE_CONDITION:
      case IndentationStack::FOR_UPDATE:
      case IndentationStack::IF_CONDITION:
        if (token == Token::COLON) return true;
        // The missing `:` will lead to an error, but we don't want to consume a
        // token if there might still be a consumer.
        continue;

      case IndentationStack::CLASS:
        return false;

      case IndentationStack::CALL:
        if (token == Token::COLON || token == Token::DOUBLE_COLON) {
          // This `if` isn't necessary, since the stored stack-level would always be >= 0, but
          // it but makes the code easier to follow.
          if (next_line_indentation == -1) continue;
          if (stack.indentation_at(i) >= next_line_indentation) continue;
          return true;
        }
        continue;

      case IndentationStack::FOR_INIT:
      case IndentationStack::FOR_CONDITION:
        if (token == Token::SEMICOLON) return true;
        if (token == Token::COLON) return false;
        // The missing `;` will lead to an error, but we don't want to consume a
        // token if there might still be a consumer.
        continue;

      case IndentationStack::TRY:
        if (token == Token::FINALLY) return true;
        if (token == Token::COLON) return false;
        // The missing `finally` will lead to an error, but we don't want to consume a
        // token if there might still be a consumer.
        continue;

      case IndentationStack::LITERAL:
        if (token == Token::COMMA) return true;
        // The following is very conservative.
        // Colons are allowed inside sets and maps, just to cover the case where a
        // map key ends with a colon.
        if (token == Token::COLON && stack.end_token_at(i) == Token::RBRACE) return true;
        // Fall through to delimited.

      case IndentationStack::DELIMITED:
        if (token == Token::COLON) return false;
        if (stack.end_token_at(i) == token) return true;
        continue;
    }
  }
  return false;
}

static bool made_progress(IndentationStack& stack) {
  auto last_pos = stack.start_range_at(0).from();
  for (int i = 50; i < stack.size(); i += 50) {
    auto next_pos = stack.start_range_at(i).from();
    if (!last_pos.is_before(next_pos)) return false;
    last_pos = next_pos;
  }
  return true;
}

namespace {  // anonymous

class TreeHeightChecker : public TraversingVisitor {
 public:
  TreeHeightChecker(int max_height, Diagnostics* diagnostics)
      : max_height_(max_height)
      , diagnostics_(diagnostics) {}

  bool reached_max_depth() const { return reported_error_; }

#define DECLARE(name) \
  void visit_##name(name* node) { \
    if (check_height(node)) { \
      current_height_++; \
      TraversingVisitor::visit_##name(node); \
      current_height_--; \
    } \
  }
NODES(DECLARE)
#undef DECLARE

 private:
  int max_height_;
  Diagnostics* diagnostics_;

  int current_height_ = 0;
  bool reported_error_ = false;

  bool check_height(Node* node) {
    if (reported_error_) return false;
    if (current_height_ >= max_height_) {
      diagnostics_->report_error(node->range(),
                                 "Maximal recursion depth exceeded %d\n",
                                 max_height_);
      reported_error_ = true;
      return false;
    }
    return true;
  }
};

}  // namespace anonymous


bool Parser::check_tree_height(Unit* unit) {
  TreeHeightChecker visitor(Flags::max_recursion_depth, diagnostics());
  unit->accept(&visitor);
  return !visitor.reached_max_depth();
}

void Parser::check_indentation_stack_depth() {
  if (!encountered_stack_overflow_ &&
      indentation_stack_.size() > Flags::max_recursion_depth) {
    ASSERT(made_progress(indentation_stack_));
    diagnostics()->report_error(current_range_safe(),
                                "Maximal recursion depth exceeded %d\n",
                                Flags::max_recursion_depth);
    encountered_stack_overflow_ = true;
    // Move to the end of the file to stop scanning it.
    scanner_->advance_to(source_->size());
  }
}

void Parser::start_multiline_construct(IndentationStack::Kind kind) {
  start_multiline_construct(kind, current_indentation());
}

void Parser::start_multiline_construct(IndentationStack::Kind kind, int indentation) {
  check_indentation_stack_depth();
  indentation_stack_.push(indentation, kind, current_range_safe());
}

void Parser::delimit_with(Token::Kind token) {
  ASSERT(current_token_if_delimiter() == token);

  // Reset the indentation of the construct, since the delimiter may be at any depth.
  // For example:
  //   if foo
  //       and bar:
  //     gee 1 2
  //
  // In other words: the individual delimited sections should not depend on
  // each other WRT indentation.
  int construct_indentation = indentation_stack_.top_indentation();
  if (current_token() == Token::DEDENT &&
      indentation_after_dedent() == construct_indentation) {
    // Allow delimiters to be at the same level as the construct.
    consume();
  }
  ASSERT(current_token() == token);
  consume();
  if (current_token() == Token::DEDENT &&
      indentation_after_dedent() > construct_indentation) {
    // Allow the line after the delimiter to indent less than the delimiter, but
    // not less than the construct.
    //
    // ```
    // x :=
    //   foo
    //     ?
    //   bar
    //     :
    //   gee
    consume();
  }
}

bool Parser::skip_to_body(Token::Kind delimiter) {
  while (true) {
    // This could be written in the condition of the `while`, but I found it so much harder
    // to read.
    if (at_newline() && current_indentation() < indentation_stack_.top_indentation() + 4) break;
    if (current_token() == Token::DEDENT) break;
    if (current_token() == delimiter) break;
    consume();
  }
  return optional(delimiter);
}

void Parser::skip_to_dedent() {
  ASSERT(!indentation_stack_.is_empty());
  while (current_token() != Token::DEDENT ||
         current_state().scanner_state.indentation > indentation_stack_.top_indentation()) {
    ASSERT(current_token() != Token::EOS);
    consume();
  }
}

void Parser::skip_to_end_of_multiline_construct() {
  // TODO(florian): take delimiters into account.
  skip_to_dedent();
}

void Parser::end_multiline_construct(IndentationStack::Kind kind,
                                     bool must_finish_with_dedent) {
  ASSERT(indentation_stack_.top_kind() == kind);
  if (must_finish_with_dedent && current_token() != Token::DEDENT && current_token() != Token::EOS) {
    report_error("Not at dedent");
    skip_to_dedent();
  }
  int construct_indentation = indentation_stack_.pop();
  if (current_token() == Token::DEDENT) {
    int next_indentation = peek_state().scanner_state.indentation;
    if (indentation_stack_.is_empty() || indentation_stack_.top_indentation() < next_indentation) {
      consume();
      if (next_indentation > construct_indentation) {
        FATAL("Dedent while indentation is still higher");
      }
    }
  }
}

void Parser::switch_multiline_construct(IndentationStack::Kind from,
                                        IndentationStack::Kind to) {
  ASSERT(indentation_stack_.top_kind() == from);
  int indentation = indentation_stack_.pop();
  indentation_stack_.push(indentation, to, current_range_safe());
}

void Parser::start_delimited(IndentationStack::Kind kind, Token::Kind start_token, Token::Kind end_token) {
  indentation_stack_.push(current_state().scanner_state.indentation, kind, end_token, current_range());
  ASSERT(current_token() == start_token);
  consume();
}

bool Parser::end_delimited(IndentationStack::Kind kind,
                           Token::Kind end_token,
                           bool try_to_recover,
                           bool report_error_on_missing_delimiter) {
  ASSERT(indentation_stack_.top_end_token() == end_token);
  if (current_token() == Token::DEDENT &&
      current_token_if_delimiter() == end_token) {
    // Allow to end delimited sections at the same level as they started:
    //
    // foo := [
    //   1,
    //   2,
    // ]
    consume();
  }

  bool encountered_error = false;

  if (current_token() != end_token) {
    auto start_range = indentation_stack_.top_start_range();
    encountered_error = true;
    if (report_error_on_missing_delimiter && !encountered_stack_overflow_) {
      report_error(start_range.extend(current_range().from()),
                  "Missing closing '%s'", Token::symbol(end_token).c_str());
    }
    // Try to find the token on the same line.
    if (try_to_recover) {
      while (true) {
        auto token = current_token();
        if (token == end_token || is_eol(token)) {
          break;
        }
        consume();
      }
    }
  }

  if (current_token() == end_token) {
    end_multiline_construct(kind);
    consume();
  } else {
    // We just reported the error a few lines earlier.
    ASSERT(diagnostics()->encountered_error());
    if (try_to_recover) skip_to_dedent();
    end_multiline_construct(kind);
  }
  return encountered_error;
}

void Parser::peek_state(int n, Parser::State* parser_state) {
  bool at_newline = false;
  auto scanner_state = scanner_state_queue_.get(n);
  Token::Kind token = scanner_state.token();

  // Switch the token to a DEDENT, if it's a EOS/NEWLINE, and the indentation
  // warrants the switch.
  switch (token) {
    case Token::EOS: {
      if (indentation_stack_.is_empty()) {
        // Just consume the EOS token and thus terminate the parsing.
        break;
      }
      // Fall through to Newline token.
      [[fallthrough]];
    }
    case Token::NEWLINE: {
      if (indentation_stack_.is_empty()) {
        // No multiline construct. Just deal with the next token.
        break;
      }

      auto& next_state = scanner_state_queue_.get(n + 1);
      int old_indentation = scanner_state.indentation;

      if (next_state.indentation > old_indentation) {
        // Increasing the indentation is ok.
        break;
      } else if (next_state.indentation == old_indentation &&
                 indentation_stack_.top_indentation() < old_indentation) {
        // Still indented.
        break;
      } else {
        // A dedent. Close the current multiline-construct.
        token = Token::DEDENT;
        break;
      }
    }
    default:
      auto& previous_state = scanner_state_queue_.get(n - 1);
      at_newline = previous_state.token() == Token::NEWLINE;
      break;
  }

  *parser_state = {
    .scanner_state = scanner_state,
    .token = token,
    .at_newline = at_newline,
  };
}

Import* Parser::parse_import() {
  ASSERT(current_token() == Token::IMPORT);
  start_multiline_construct(IndentationStack::IMPORT);
  auto range = current_range();
  consume();
  Import* result = null;
  int dot_outs = 0;
  bool is_relative = false;
  ListBuilder<Identifier*> identifiers;
  if (current_token() == Token::PERIOD || current_token() == Token::SLICE) {
    is_relative = true;
    // Start with -1, since the first token is just an indication that the import
    // is relative.
    dot_outs = -1;
    // Dot-outs are only allowed in the beginning of the import.
    while (current_token() == Token::PERIOD || current_token() == Token::SLICE) {
      dot_outs++;
      if (current_token() == Token::SLICE) dot_outs++;
      consume();
    }
  }
  bool missing_identifier = false;
  do {
    if (current_token() != Token::IDENTIFIER) {
      missing_identifier = true;
      break;
    }
    identifiers.add(parse_identifier());
  } while (optional(Token::PERIOD));

  if (missing_identifier) {
    if (is_eol(current_token())) {
      report_error(eol_range(previous_range(), current_range()),
                   "Incomplete import clause");
    } else {
      report_error("Unexpected token. Missing identifier for import");
    }
    skip_to_end_of_multiline_construct();
    // Make the import relative, so we don't need the prefix.
    result = NEW_NODE(Import(true, 0, List<ast::Identifier*>(), null, List<ast::Identifier*>(), false),
                      range);
  } else {
    Identifier* prefix = null;
    List<Identifier*> show_identifiers;
    bool show_all = false;

    if (current_token() == Token::AS) {
      auto as_range = current_range();
      consume();
      if (current_token() == Token::IDENTIFIER) {
        prefix = parse_identifier();
      } else {
        report_error(as_range, "'as' must be followed by identifier");
        prefix = NEW_NODE(Identifier(Symbol::invalid()), as_range);
        skip_to_end_of_multiline_construct();
      }
    } else if (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::show) {
      auto show_range = current_range();
      consume();
      ListBuilder<Identifier*> builder;
      if (current_token() == Token::IDENTIFIER) {
        do {
          builder.add(parse_identifier());
        } while (current_token() == Token::IDENTIFIER);
        show_identifiers = builder.build();
      } else if (current_token() == Token::MUL) {
        consume();
        show_all = true;
      } else {
        show_all = true;  // While there is an error, just assume all of them are visible.
        report_error(show_range, "'show' must be followed by '*' or identifiers");
        skip_to_end_of_multiline_construct();
      }
    }
    result = NEW_NODE(Import(is_relative, dot_outs, identifiers.build(), prefix, show_identifiers, show_all),
                      range);
  }
  end_multiline_construct(IndentationStack::IMPORT, true);
  return result;
}

Export* Parser::parse_export() {
  ASSERT(current_token() == Token::EXPORT);
  start_multiline_construct(IndentationStack::EXPORT);
  auto range = current_range();
  consume();

  Export* result;
  if (current_token() == Token::MUL) {
    consume();
    result = NEW_NODE(Export(true), range);
  } else if (current_token() != Token::IDENTIFIER) {
    if (is_eol(current_token())) {
      report_error(eol_range(previous_range(), current_range()),
                   "Incomplete export clause");
    } else {
      report_error("Expected export identifier");
    }
    skip_to_end_of_multiline_construct();
    result = NEW_NODE(Export(List<Identifier*>()), range);
  } else {
    ListBuilder<Identifier*> identifiers;
    do {
      identifiers.add(parse_identifier());
    } while (current_token() == Token::IDENTIFIER);
    result = NEW_NODE(Export(identifiers.build()), range);
  }
  end_multiline_construct(IndentationStack::EXPORT, true);
  return result;
}

static bool is_operator_token(Token::Kind token) {
  switch (token) {
    case Token::EQ:
    case Token::LT:
    case Token::LTE:
    case Token::GTE:
    case Token::GT:
    case Token::ADD:
    case Token::SUB:
    case Token::MUL:
    case Token::DIV:
    case Token::MOD:
    case Token::BIT_NOT:
    case Token::BIT_AND:
    case Token::BIT_OR:
    case Token::BIT_XOR:
    case Token::BIT_SHR:
    case Token::BIT_USHR:
    case Token::BIT_SHL:
    case Token::LBRACK:
      return true;
    default:
      return false;
  }
}

Declaration* Parser::parse_declaration(bool is_abstract) {
  start_multiline_construct(IndentationStack::DECLARATION_SIGNATURE);

  bool is_static = false;
  bool is_setter = false;
  Expression* name = null;
  // We don't require the caller to consume the `abstract` keyword.
  // If the boolean isn't set yet, we check ourselves here.
  if (!is_abstract && current_token() == Token::ABSTRACT) {
    consume();
    is_abstract = true;
  }
  if (current_token() == Token::STATIC) {
    consume();
    is_static = true;
  }
  auto declaration_range = current_range();
  if (current_token() == Token::IDENTIFIER) {
    name = parse_identifier();
  } else {
    if (is_eol(current_token())) {
      declaration_range = eol_range(previous_range(), current_range());
    }
    if (is_eol(current_token()) || current_token() == Token::COLON) {
      report_error(declaration_range, "Expected name of declaration");
      name = NEW_NODE(Identifier(Symbol::invalid()), declaration_range);
    } else {
      report_error(declaration_range, "Invalid name for declaration");
      auto invalid_token = current_token();
      auto range = current_range();
      consume();
      name = NEW_NODE(Identifier(Token::symbol(invalid_token)), range);
    }
  }

  if (name->as_Identifier()->data() == Symbols::op) {
    auto token = current_token();
    auto token_range = current_range();
    if (is_operator_token(token)) {
      auto token = current_token();
      auto name_range = declaration_range.extend(current_range());
      if (token != Token::LBRACK) {
        consume();
        name = NEW_NODE(Identifier(Token::symbol(token)), name_range);
      } else {
        ASSERT(token == Token::LBRACK);
        consume();
        if (current_token() == Token::SLICE) {
          // The slice operator: [..]
          if (!is_current_token_attached()) {
            report_error("Can't have space between '[' and '..'");
          }
          consume();
          if (current_token() != Token::RBRACK) {
            report_error(token_range, "Missing closing ']'");
            // Use the `[` as name, and consume everything that is attached.
            while (is_current_token_attached()) {
              // Consume the attached tokens, as if they were part of the name.
              // Hopefully, this reduces the number of follow-up errors.
              consume();
            }
            name = NEW_NODE(Identifier(Token::symbol(token)), name_range);
          } else {
            if (!is_current_token_attached()) {
              report_error("Can't have space between '..' and ']'");
            }
            name_range = name_range.extend(current_range());
            consume();
            name = NEW_NODE(Identifier(Symbols::index_slice), name_range);
          }
        } else if (current_token() != Token::RBRACK) {
          report_error(token_range, "Missing closing ']'");
          // Use the `[` as name, and consume everything that is attached.
          while (is_current_token_attached()) {
            // Consume the attached tokens, as if they were part of the name.
            // Hopefully, this reduces the number of follow-up errors.
            consume();
          }
          name = NEW_NODE(Identifier(Token::symbol(token)), name_range);
        } else {
          // Either `[]` or `[]=`.
          if (!is_current_token_attached()) {
            report_error("Can't have space between '[' and ']'");
          }
          name_range = name_range.extend(current_range());
          consume();
          if (current_token() == Token::ASSIGN) {
            if (!is_current_token_attached()) {
              report_error("Can't have space between ']' and '='");
            }
            name_range = name_range.extend(current_range());
            consume();
            name = NEW_NODE(Identifier(Symbols::index_put), name_range);
          } else {
            name = NEW_NODE(Identifier(Symbols::index), name_range);
          }
        }
      }
      declaration_range = declaration_range.extend(name_range);
    } else {
      report_error("Invalid operator name");
    }
  } else if (current_token() == Token::ASSIGN && is_current_token_attached()) {
    declaration_range = declaration_range.extend(current_range());
    consume();
    is_setter = true;
  } else if (current_token() == Token::DIV ||
             current_token() == Token::DEFINE ||
             current_token() == Token::DEFINE_FINAL ||
             current_token() == Token::ASSIGN) {  // In this case the '=' is not attached and reported as error.
    // A field/global.
    bool has_initializer = true;
    Expression* field_type = null;
    if (current_token() == Token::DIV) field_type = parse_type(true);
    bool is_final = false;
    if (current_token() == Token::DEFINE || current_token() == Token::ASSIGN) {
      if (current_token() == Token::ASSIGN) {
        report_error("Unexpected token '='. Did you mean ':='?");
      }
      consume();
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
    } else if (current_token() == Token::DEFINE_FINAL) {
      is_final = true;
      consume();
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
    } else if (field_type != null) {
      // A declaration with type doesn't need an initializer anymore.
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
      has_initializer = false;
      is_final = true;
    } else {
      report_error("Missing ':=' or '::=' for field.");
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
    }
    Expression* initializer = null;
    if (has_initializer) {
      if (current_token() == Token::CONDITIONAL) {
        initializer = NEW_NODE(LiteralUndefined(), current_range());
        consume();
      } else {
        initializer = parse_expression(true);
      }
    }
    end_multiline_construct(IndentationStack::DECLARATION, true);
    return NEW_NODE(Field(name->as_Identifier(), field_type, initializer,
                          is_static, is_abstract, is_final),
                    declaration_range);
  } else if (current_token() == Token::PERIOD && is_current_token_attached()) {
    auto period_range = current_range();
    // Must be a named constructor.
    consume();
    if (!is_current_token_attached() || current_token() != Token::IDENTIFIER) {
      // TODO(florian): Ideally we should check whether the identifier before is
      // the period is the class name and give indications, that named constructors
      // must be attached.
      // Assume that the dot is spurious.
      report_error(declaration_range.extend(period_range), "Invalid member name");
    } else {
      auto constructor_name = parse_identifier();
      name = NEW_NODE(Dot(name, constructor_name), declaration_range.extend(constructor_name->range()));
    }
  }
  auto return_type_parameters = parse_parameters(true);
  Expression* return_type = null;
  if (return_type_parameters.first != null) {
    return_type = return_type_parameters.first;
  }
  auto parameters = return_type_parameters.second;

  Sequence* body;
  if (current_token() == Token::COLON) {
    consume();
    switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
    // Interface members and abstract methods are not allowed to have bodies.
    // We report errors for bodies later.
    body = parse_sequence();
  } else if (current_token() == Token::DEDENT) {
    switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
    body = null;
  } else {
    if (at_newline()) {
      report_error("Signatures and bodies must be separated by a `:`");
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);
      body = parse_sequence();
    } else {
      report_error("Unexpected token: %s", Token::symbol(current_token()).c_str());
      while (!(at_newline() && (current_indentation() < indentation_stack_.top_indentation() + 4)) &&
             current_token() != Token::DEDENT &&
             current_token() != Token::COLON &&
             current_token() != Token::DEFINE &&
             current_token() != Token::DEFINE_FINAL) {
        consume();
      }
      switch_multiline_construct(IndentationStack::DECLARATION_SIGNATURE, IndentationStack::DECLARATION);

      if (current_token() == Token::DEDENT) {
        body = null;
      } else if (current_token() == Token::COLON ||
                 current_token() == Token::DEFINE ||
                 current_token() == Token::DEFINE_FINAL) {
        consume();
        body = parse_sequence();
      } else {
        ASSERT(at_newline());
        body = parse_sequence();
      }
    }
  }
  end_multiline_construct(IndentationStack::DECLARATION, true);
  return NEW_NODE(Method(name, return_type, is_setter, is_static, is_abstract, parameters, body), declaration_range);
}

Class* Parser::parse_class_interface_or_monitor(bool is_abstract) {
  ASSERT(current_token() == Token::CLASS ||
         (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::interface_)||
         (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::monitor));

  ListBuilder<Expression*> interfaces;
  ListBuilder<Declaration*> members;

  start_multiline_construct(IndentationStack::CLASS);   // Classes/monitors go over multiple lines.

  bool is_monitor = false;
  bool is_interface = false;
  if (current_token() == Token::IDENTIFIER) {
    is_monitor = current_token_data() == Symbols::monitor;
    is_interface = current_token_data() == Symbols::interface_;
    if (is_abstract) {
      report_error("%s can't be abstract", is_interface ? "Interfaces" : "Monitors");
      is_abstract = false;
    }
    consume();
  } else {
    ASSERT(current_token() == Token::CLASS);
    consume();
  }

  int member_indentation = -1;

  Identifier* name;
  Expression* super = null;
  if (current_token() != Token::IDENTIFIER) {
    const char* kind_name = "class";
    if (is_monitor) kind_name = "monitor";
    if (is_interface) kind_name = "interface";
    if (is_eol(current_token())) {
      report_error(eol_range(previous_range(), current_range()),
                   "Expected %s name", kind_name);
    } else {
      report_error("Expected %s name", kind_name);
    }
    name = NEW_NODE(Identifier(Symbol::invalid()), current_range());
    // Skip to the body.
    if (!skip_to_body(Token::COLON)) {
      member_indentation = 2;  // Assume that members are now intented by 2.
    }
  } else {
    name = parse_identifier();
    bool requires_super = false;
    if (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::extends) {
      consume();
      requires_super = true;
    }
    if (current_token() == Token::IDENTIFIER && current_token_data() != Symbols::implements) {
      super = parse_type(false);
    }
    if (current_token() == Token::IDENTIFIER && current_token_data() == Symbols::implements) {
      if (super == null && requires_super) {
        report_error("Missing super class");
        // We reported an error. No need for a super class anymore.
        requires_super = false;
      }
      consume();
      do {
        interfaces.add(parse_type(false));
      } while (current_token() == Token::IDENTIFIER);
    }

    if (super == null && requires_super) {
      report_error("Missing super class");
    }

    if (current_token() == Token::COLON) {
      consume();
    } else {
      report_error("Missing colon to end class signature");
      member_indentation = 2;  // Assume that members are now intented by 2.
    }
  }

  while (current_token() != Token::DEDENT) {
    if (member_indentation == -1) {
      if (at_newline()) {
        member_indentation = current_indentation();
      }
    } else if (current_indentation() != member_indentation) {
      report_error("Members must have the same indentation");
    }
    members.add(parse_declaration(false));
  }
  end_multiline_construct(IndentationStack::CLASS, true);
  return NEW_NODE(Class(name,
                        super,
                        interfaces.build(),
                        members.build(),
                        is_abstract,
                        is_monitor,
                        is_interface),
                  name->range());
}

Expression* Parser::parse_block_or_lambda(int indentation) {
  ASSERT(current_token() == Token::COLON || current_token() == Token::DOUBLE_COLON);
  auto range = current_range();

  start_multiline_construct(IndentationStack::BLOCK, indentation);
  bool lifo;
  if (current_token() == Token::COLON) {
    consume();
    lifo = true;
  } else {
    ASSERT(current_token() == Token::DOUBLE_COLON);
    consume();
    lifo = false;
  }

  Sequence* body;
  bool has_parameters = false;
  auto parameters = parse_block_parameters(&has_parameters);
  body = parse_sequence();

  range = range.extend(current_range().from());
  end_multiline_construct(IndentationStack::BLOCK);
  if (lifo) {
    return NEW_NODE(Block(body, parameters), range);
  } else {
    return NEW_NODE(Lambda(body, parameters), range);
  }
}

Sequence* Parser::parse_sequence() {
  auto range = current_range();

  // In theory we don't need the multiline construct, but it allows for better
  // error recovery.
  int outer_indentation = indentation_stack_.top_indentation();
  start_multiline_construct(IndentationStack::Kind::SEQUENCE);
  ListBuilder<Expression*> expressions;
  int expression_indent = -1;
  bool can_be_at_newline = at_newline();
  bool needs_to_be_at_newline = false;
  while (true) {
    // A sequence continues as long as the indentation is "correct".
    if (current_token() == Token::DEDENT &&
        expression_indent >= 0 &&
        current_indentation() > outer_indentation) {
      consume();
    }

    if (current_token() == Token::DEDENT) break;

    if (is_delimiter(current_token(), true, true)) {
      if (!consumer_exists(current_token(), -1)) {
        report_error("Unexpected delimiter");
        skip_to_dedent();
        continue;
      }
      break;
    }

    if (current_token() == Token::SEMICOLON) {
      consume();
      needs_to_be_at_newline = false;
      continue;
    }

    if (at_newline() && !can_be_at_newline) {
      break;
    }

    if (at_newline()) {
      if (expression_indent == -1) {
        expression_indent = current_indentation();
      } else if (expression_indent != current_indentation()) {
        report_error("All expressions in a sequence must be indented the same way");
      }
    } else if (needs_to_be_at_newline) {
      if (current_token() == Token::COLON) {
        // A colon followed by a newline is as if the colon was on the next
        // line.
        auto next_token = peek_token();
        if (is_eol(next_token)) break;
      }
      // For example, when there is something after a break:
      //    ```
      //       while true:
      //         break 499
      //    ```
      //
      // We could accept the `499` as a new expression, but that would be confusing,
      // giving the impression that `499` was an argument to `break`.
      // Report an error.
      report_error("Missing semicolon or missing newline");
    }

    expressions.add(parse_expression_or_definition(true));
    needs_to_be_at_newline = true;
  }
  end_multiline_construct(IndentationStack::Kind::SEQUENCE);
  return NEW_NODE(Sequence(expressions.build()), range);
}

Expression* Parser::parse_expression_or_definition(bool allow_colon) {
  if (current_token() == Token::IDENTIFIER) {
    ParserPeeker peeker(this);
    peeker.consume();  // The identifier.
    if (peeker.current_token() == Token::DIV) {
      peeker.consume();
      bool at_type = peek_type(&peeker);
      if (!at_type) return parse_expression(allow_colon);
    }
    auto token = peeker.current_token();
    if (token == Token::DEFINE || token == Token::DEFINE_FINAL) {
      return parse_definition(allow_colon);
    }
  }
  return parse_expression(allow_colon);
}

Expression* Parser::parse_expression(bool allow_colon) {
  auto range = current_range();
  if (current_token() == Token::IF) {
    return parse_if();
  } else if (current_token() == Token::WHILE) {
    return parse_while();
  } else if (current_token() == Token::FOR) {
    return parse_for();
  } else if (current_token() == Token::TRY) {
    return parse_try_finally();
  } else if (current_token() == Token::RETURN) {
    consume();
    if (is_current_token_attached() && current_token() == Token::PERIOD &&
        is_next_token_attached() && peek_token() == Token::IDENTIFIER) {
      Identifier* label = null;
      consume(); // The `.`.
      label = parse_identifier();
      diagnostics()->report_warning(range,
                                    "'return.label' is deprecated. Use 'continue.label' instead");
      if (!is_delimiter(current_token(), allow_colon, false)) {
        return NEW_NODE(BreakContinue(false, parse_expression(allow_colon), label), range);
      } else {
        return NEW_NODE(BreakContinue(false, null, label), range);
      }
    } else {
      if (!is_delimiter(current_token(), allow_colon, false)) {
        return NEW_NODE(Return(parse_expression(allow_colon)), range);
      } else {
        return NEW_NODE(Return(null), range);
      }
    }
  } else if (current_token() == Token::BREAK || current_token() == Token::CONTINUE) {
    return parse_break_continue(allow_colon);
  } else if (current_token() == Token::PRIMITIVE) {
    return parse_call(allow_colon);
  } else {
    return parse_conditional(allow_colon);
  }
}

Expression* Parser::parse_definition(bool allow_colon) {
  ASSERT(current_token() == Token::IDENTIFIER);
  auto name = parse_identifier();
  auto token = current_token();
  ast::Expression* type = null;
  if (token == Token::DIV) {
    type = parse_type(true);
    token = current_token();
  }
  // We know that there must be a `:=` or `::=` somewhere soon,
  //   as we would have otherwise not be called.
  bool reported_error = type != null && type->is_Error();
  while (token != Token::DEFINE && token != Token::DEFINE_FINAL) {
    // Ignore the rest of the presumed type, and skip forward to the
    //  define-tokens.
    if (!reported_error) {
      report_error("Unexpected token while parsing definition");
      reported_error = true;
    }
    consume();
    token = current_token();
    if (token == Token::EOS) FATAL("Unexpected end of file");
  }
  auto range = current_range();
  consume();
  Expression* value;
  if (current_token() == Token::CONDITIONAL) {
    value = NEW_NODE(LiteralUndefined(), current_range());
    consume();
  } else {
    value = parse_expression(allow_colon);
  }
  return NEW_NODE(DeclarationLocal(token, name, type, value), range);
}

namespace {  // anonymous
struct LogicalEntry {
  Expression* node;
  Token::Kind kind;
  Source::Range range;
};
}  // namespace anonymous

Expression* Parser::parse_logical_spelled(bool allow_colon) {
  start_multiline_construct(IndentationStack::LOGICAL);

  Expression* result = parse_not_spelled(allow_colon);
  if (current_token() != Token::LOGICAL_OR &&
      current_token() != Token::LOGICAL_AND) {
    end_multiline_construct(IndentationStack::LOGICAL);
    return result;
  }

  std::vector<LogicalEntry> operands;
  operands.push_back({
    .node = result,
    .kind = Token::INVALID,
    .range = Source::Range::invalid(),
  });
  while (current_token() == Token::LOGICAL_OR ||
         current_token() == Token::LOGICAL_AND) {
    auto token = current_token();
    auto range = current_range();
    // Start by collecting the entries. We will join them in
    // the next loop.
    consume();
    operands.push_back({
      .node = parse_not_spelled(allow_colon),
      .kind = token,
      .range = range,
    });
  }
  for (int j = 0; j < 2; j++) {
    // Do the 'and's first.
    auto token = j == 0 ? Token::LOGICAL_AND : Token::LOGICAL_OR;
    // Logical operations are right-associative.
    for (int i = operands.size() - 1; i > 0; i--) {
      auto current = operands[i];
      if (current.kind != token) continue;
      // We know that there must be a left node, as there is always
      // the stack[0] entry left.
      int left_index = i - 1;
      // Skip over merged 'and's (but not the first node).
      while (left_index > 0 && operands[left_index].kind == Token::INVALID) {
        left_index--;
      }
      auto left = operands[left_index];
      operands[left_index] = {
        .node = NEW_NODE(Binary(token, left.node, current.node),
                         current.range),
        .kind = left.kind,
        .range = left.range,
      };
      operands[i] = {
        .node = null,
        .kind = Token::INVALID,
        .range = Source::Range::invalid(),
      };
    }
  }
  end_multiline_construct(IndentationStack::LOGICAL);
  return operands[0].node;
}

Expression* Parser::parse_not_spelled(bool allow_colon) {
  ASSERT(indentation_stack_.top_kind() == IndentationStack::LOGICAL);
  if (current_token() == Token::NOT) {
    std::vector<Source::Range> not_ranges;
    while (current_token() == Token::NOT) {
      not_ranges.push_back(current_range());
      consume();
    }
    auto left = parse_call(allow_colon);
    for (int i = not_ranges.size(); i > 0; i--) {
      left = NEW_NODE(Unary(Token::NOT, true, left), not_ranges[i - 1]);
    }
    return left;
  } else {
    return parse_call(allow_colon);
  }
}

Expression* Parser::parse_argument(bool allow_colon, bool full_expression) {
  auto range = current_range();
  Identifier* name = null;
  bool is_boolean = false;
  bool inverted = false;
  if (current_token() == Token::DECREMENT && is_next_token_attached() && peek_token() == Token::IDENTIFIER) {
    consume();
    name = parse_identifier();
    if (name->data() == Symbols::no && is_current_token_attached() &&
        current_token() == Token::SUB && is_next_token_attached() &&
        peek_token() == Token::IDENTIFIER) {
      // --no-foo
      inverted = true;
      consume();  // Token::SUB.
      name = parse_identifier();
    }
    if (current_token() != Token::ASSIGN) {
      is_boolean = true;
    } else {
      if (inverted) {
        report_error("Can't have boolean flag with '='");
      }
      consume();
    }
  }
  Expression* expression = null;
  if (!is_boolean) {
    if (full_expression) {
      expression = parse_expression(allow_colon);
    } else {
      expression = parse_precedence(PRECEDENCE_ASSIGNMENT, allow_colon);
    }
  }
  if (name == null) return expression;
  return NEW_NODE(NamedArgument(name, inverted, expression), range);
}

Expression* Parser::parse_call(bool allow_colon) {
  start_multiline_construct(IndentationStack::CALL);
  auto range = current_range();
  Expression* target;
  bool is_call_primitive = false;
  if (current_token() == Token::AZZERT) {
    consume();
    target = NEW_NODE(Identifier(Token::symbol(Token::AZZERT)), range);
  } else {
    is_call_primitive = current_token() == Token::PRIMITIVE;
    target = parse_precedence(PRECEDENCE_ASSIGNMENT, allow_colon, is_call_primitive);
  }

  ListBuilder<Expression*> arguments;

  // Once an argument started at a `newline`, all further arguments must start at
  // new lines too.
  // This means that the following is illegal:
  //  foo
  //     if foo: 499 else: break 42
  //
  // The only exception is a `:` (or `::`) followed by a new line.
  bool must_be_at_newline = false;
  int arguments_indentation = -1;
  while (true) {
    if (is_call_delimiter(current_token(), allow_colon)) {
      break;
    } else if (at_newline()) {
      if (arguments_indentation == -1) arguments_indentation = current_indentation();
      if (arguments_indentation != current_indentation()) {
        report_error("All arguments must have the same indentation.");
      }
      // Given that there is no dedent, we know that this expression is still
      // at the same level and is an argument to the call.
      arguments.add(parse_argument(allow_colon, true));
      // From now on, all arguments must be on new lines.
      must_be_at_newline = true;
    } else if ((current_token() == Token::COLON && allow_colon)  ||
               current_token() == Token::DOUBLE_COLON) {
      auto token = current_token();
      if (token == Token::COLON && !allowed_to_consume(token)) {
        break;
      } else if (token == Token::DOUBLE_COLON && !allowed_to_consume(token)) {
        break;
      }
      int call_indentation = indentation_stack_.top_indentation();
      // Check whether there is a dedent after the ':' or after its parameters.
      // The dedent's depth determines whether the block is part of this call or not.
      bool at_dedent = false;
      int next_indentation = -1;
      ParserPeeker peeker(this);
      peeker.consume();  // The ':'.
      if (peeker.current_token() == Token::BIT_OR) {
        peeker.consume();
        // Skip over the parameters. They don't really count for indentation purposes.
        while (peeker.current_token() == Token::IDENTIFIER) {
          if (!peek_block_parameter(&peeker)) {
            goto peeking_done;
          }
        }
        if (peeker.current_token() != Token::BIT_OR) goto peeking_done;
        peeker.consume();
      }
      if (peeker.current_token() == Token::DEDENT) {
        at_dedent = true;
        peeker.consume();
        ASSERT(peeker.current_state().at_newline ||
               peeker.current_state().scanner_state.token() == Token::EOS);
        next_indentation = peeker.current_state().scanner_state.indentation;
      }
      peeking_done:
      if (!at_dedent) {
        arguments.add(parse_block_or_lambda(call_indentation));
      } else {
        if (!consumer_exists(token, next_indentation)) {
          report_error("Empty %s are not allowed",
                       token == Token::COLON ? "blocks" : "lambdas");
          arguments.add(parse_block_or_lambda(call_indentation));
          continue;
        }
        break;
      }
    } else if (!must_be_at_newline) {
      arguments.add(parse_argument(allow_colon, false));
    } else {
      // For example:
      //
      // ```
      // foo x y:
      // main:
      //   while true:
      //     foo
      //       break 499
      // ```
      report_error("Arguments must be separated by newlines");
      arguments.add(parse_argument(allow_colon, false));
    }
  }

  end_multiline_construct(IndentationStack::CALL);
  if (arguments.length() == 0 && !is_call_primitive) return target;
  return NEW_NODE(Call(target, arguments.build(), is_call_primitive), range);
}

Expression* Parser::parse_if() {
  ASSERT(current_token() == Token::IF);
  auto range = current_range();
  start_multiline_construct(IndentationStack::IF_CONDITION);
  consume();
  Expression* condition;
  if (current_token_if_delimiter() == Token::COLON) {
    // Could be a block in condition location, but that's unlikely. We prefer to
    // assume that the condition is not present.
    report_error("Missing condition");
    condition = NEW_NODE(Error, current_range());
  } else {
    condition = parse_expression_or_definition(true);
  }
  if (!optional_delimiter(Token::COLON)) {
    report_error(range, "Missing colon for 'if' condition");
    // If we are at a new line, we will make it dependent on the indentation on whether they
    // are part of the `if`.
    // Examples:
    // ```
    // if break
    //   part_of_body
    // ```
    // This scenario is extremely rare, as most often the next lines would be interpreted
    // as arguments to the condition expression.
    // Otherwise we switch to the end of the construct, which means that the subsequent
    // attempts to read a sequence will fail (because of a dedent).
    if (!at_newline()) skip_to_end_of_multiline_construct();
  }
  switch_multiline_construct(IndentationStack::IF_CONDITION, IndentationStack::IF_BODY);
  Expression* yes = parse_sequence();
  Expression* no = null;
  if (current_token() == Token::DEDENT) {
    if (peek_token() == Token::ELSE &&
        indentation_stack_.top_indentation() == current_indentation() &&
        indentation_stack_.is_outmost(IndentationStack::IF_BODY)) {
      consume();
    }
  }
  if (current_token() == Token::ELSE) {
    auto else_range = Source::Range(current_range().to(), current_range().to());
    consume();
    if (current_token() == Token::IF) {
      end_multiline_construct(IndentationStack::IF_BODY);
      no = parse_if();
    } else {
      if (!optional_delimiter(Token::COLON)) {
        // Just try to read the else block.
        // If it's correctly indented it will work.
        report_error(else_range, "Missing colon for 'else'");
      }
      no = parse_sequence();
      end_multiline_construct(IndentationStack::IF_BODY);
    }
  } else {
    end_multiline_construct(IndentationStack::IF_BODY);
  }
  return NEW_NODE(If(condition, yes, no), range);
}

Expression* Parser::parse_while() {
  ASSERT(current_token() == Token::WHILE);
  auto range = current_range();
  start_multiline_construct(IndentationStack::WHILE_CONDITION);
  consume();
  Expression* condition;
  if (current_token_if_delimiter() == Token::COLON) {
    // Could be a block in condition location, but that's unlikely. We prefer to
    // assume that the condition is not present.
    report_error("Missing condition");
    condition = NEW_NODE(Error, current_range());
  } else {
    condition = parse_expression_or_definition(true);
  }
  if (!optional_delimiter(Token::COLON)) {
    report_error(range, "Missing colon for loop condition");
    // Just try to read the body.
  }
  switch_multiline_construct(IndentationStack::WHILE_CONDITION,
                             IndentationStack::WHILE_BODY);
  Expression* body = parse_sequence();
  end_multiline_construct(IndentationStack::WHILE_BODY);
  return NEW_NODE(While(condition, body), range);
}

Expression* Parser::parse_for() {
  ASSERT(current_token() == Token::FOR);
  auto range = current_range();
  auto error_range = range;
  start_multiline_construct(IndentationStack::FOR_INIT);
  consume();
  Expression* initializer = null;
  Expression* condition = null;
  Expression* update = null;

  if (current_token_if_delimiter() != Token::SEMICOLON) {
    error_range = current_range();
    initializer = parse_expression_or_definition(true);
  }

  if (!optional_delimiter(Token::SEMICOLON)) {
    report_error(error_range, "Missing semicolon");
    condition = NEW_NODE(Error, current_range());
    update = NEW_NODE(Error, current_range());
    skip_to_body(Token::COLON);
    goto parse_body;
  }

  switch_multiline_construct(IndentationStack::FOR_INIT,
                             IndentationStack::FOR_CONDITION);

  if (current_token_if_delimiter() != Token::SEMICOLON) {
    error_range = current_range();
    condition = parse_expression(true);
  }

  if (!optional_delimiter(Token::SEMICOLON)) {
    report_error(error_range, "Missing semicolon");
    update = NEW_NODE(Error, current_range());
    skip_to_body(Token::COLON);
    goto parse_body;
  }

  switch_multiline_construct(IndentationStack::FOR_CONDITION,
                             IndentationStack::FOR_UPDATE);
  // Could be a block in update location, but that's unlikely. We prefer to
  // assume that the update is not present.
  if (current_token_if_delimiter() != Token::COLON) {
    error_range = current_range();
    update = parse_expression(true);
  }
  if (!optional_delimiter(Token::COLON)) {
    report_error(error_range, "Missing colon");
    skip_to_body(Token::COLON);
  }

  parse_body:
  ASSERT(indentation_stack_.top_kind() == IndentationStack::FOR_UPDATE ||
         diagnostics()->encountered_error());
  switch_multiline_construct(indentation_stack_.top_kind(),
                             IndentationStack::FOR_BODY);
  Expression* body = parse_sequence();
  end_multiline_construct(IndentationStack::FOR_BODY);
  return NEW_NODE(For(initializer, condition, update, body), range);
}

Expression* Parser::parse_try_finally() {
  ASSERT(current_token() == Token::TRY);
  auto range = current_range();
  auto error_range = range;
  start_multiline_construct(IndentationStack::TRY);
  consume();
  bool encountered_error = false;
  if (current_token() == Token::COLON) {
    consume();
  } else {
    report_error(Source::Range(error_range.to(), error_range.to()), "Missing colon after 'try'");

    encountered_error = true;
  }
  error_range = current_range();
  Sequence* body = parse_sequence();
  if (current_token() == Token::DEDENT) {
    if (peek_token() == Token::FINALLY &&
        indentation_stack_.top_indentation() == current_indentation() &&
        indentation_stack_.is_outmost(IndentationStack::TRY)) {
      consume();
    }
  }
  List<Parameter*> handler_parameters;
  if (current_token() == Token::FINALLY) {
    error_range = current_range();
    consume();
    if (current_token() == Token::COLON) {
      delimit_with(Token::COLON);
    } else {
      report_error(Source::Range(error_range.to(), error_range.to()), "Missing colon after finally");
    }
    bool has_parameters;
    handler_parameters = parse_block_parameters(&has_parameters);
  } else if (!encountered_error) {
    report_error("Missing 'finally' block");
  }
  Sequence* handler = parse_sequence();
  end_multiline_construct(IndentationStack::TRY);
  return NEW_NODE(TryFinally(body, handler_parameters, handler), range);
}

Expression* Parser::parse_precedence(Precedence precedence,
                                     bool allow_colon,
                                     bool is_call_primitive) {
  Expression* expression = null;
  if (is_call_primitive) {
    auto token = current_token();
    ASSERT(token == Token::PRIMITIVE);
    expression = NEW_NODE(Identifier(Token::symbol(token)), current_range());
    consume();
  } else {
    expression = parse_unary(allow_colon);
  }

  Token::Kind kind = current_token();
  Precedence next = Token::precedence(kind);
  auto range = current_range();
  for (int level = next; level >= precedence; --level) {
    while (next == level) {
      if (level == PRECEDENCE_POSTFIX) {
        if (!is_current_token_attached()) {
          // Postfix operands must be attached.
          // This is necessary for multiple reasons:
          // A `[` is the index-operator when attached, but a list-literal when not.
          // Similarly, a `.` is a dot-access when attached, but could be the start
          // of a field-storing parameter otherwise.
          goto done;
        }
        expression = parse_postfix_rest(expression);
      } else if (kind == Token::SUB) {
        bool is_attached_to_previous = is_current_token_attached();
        bool is_attached_to_next = is_next_token_attached();
        if (!is_attached_to_previous && is_attached_to_next) {
          // A prefix minus.
          goto done;
        }
        if (is_attached_to_previous || is_attached_to_next) {
          diagnostics()->report_warning(range.extend(current_range()),
                                        "Minus operator must be surrounded by spaces");
        }
        consume();
        Expression* right = at_newline()
            ? parse_expression(allow_colon)
            : parse_precedence(static_cast<Precedence>(level + 1), allow_colon);
        expression = NEW_NODE(Binary(kind, expression, right), range);
      } else {
        consume();
        // If the operator is a declaration, we allow the `?` undefined literal on
        //   the RHS.
        // If the operator is an assignment, we parse a complete expression.
        // Otherwise, we recurse at the next higher precedence level.
        Expression* right;
        if ((kind == Token::DEFINE || kind == Token::DEFINE_FINAL) &&
            current_token() == Token::CONDITIONAL) {
          right = NEW_NODE(LiteralUndefined(), current_range());
          consume();
        } else if (at_newline()) {
          right = parse_expression(allow_colon);
        } else if (level == PRECEDENCE_ASSIGNMENT) {
          IndentationStack::Kind old_kind = indentation_stack_.top_kind();
          // Switch temporarily to `ASSIGNMENT`.
          // This way, blocks that follow are not consumed by the assignment, but
          // by the right-hand-side of the expression:
          //
          //   foo = bar: it
          // should be parsed as:
          //   foo = (bar: it)
          // and not as:
          //   (foo = bar): it
          switch_multiline_construct(old_kind, IndentationStack::ASSIGNMENT);
          right = parse_expression(allow_colon);
          switch_multiline_construct(IndentationStack::ASSIGNMENT, old_kind);
        } else {
          // `is` followed by `not` that is not on a new line, is merged to one
          // `is not` token.
          if (kind == Token::IS && current_token() == Token::NOT) {
            consume();
            kind = Token::IS_NOT;
          }
          right = parse_precedence(static_cast<Precedence>(level + 1), allow_colon);
        }
        expression = NEW_NODE(Binary(kind, expression, right), range);
      }
      kind = current_token();
      next = Token::precedence(kind);
      range = current_range();
    }
  }

  done:
  return expression;
}

Expression* Parser::parse_postfix_index(Expression* head, bool* encountered_error) {
  auto range = current_range();
  Expression* result = null;
  start_delimited(IndentationStack::DELIMITED, Token::LBRACK, Token::RBRACK);
  if (current_token_if_delimiter() == Token::RBRACK) {
    report_error("Missing argument for indexing operator");
    result = NEW_NODE(Index(head, List<ast::Expression*>()), range);
  } else {
    Expression* first_argument = null;
    if (current_token() != Token::SLICE) {
      first_argument = parse_expression(true);
    }
    if (current_token() == Token::SLICE) {
      consume();
      Expression* second_argument = null;
      if (current_token_if_delimiter() != Token::RBRACK) {
        second_argument = parse_expression(true);
      }
      result = NEW_NODE(IndexSlice(head, first_argument, second_argument), range);
    } else {
      ListBuilder<Expression*> arguments;
      arguments.add(first_argument);
      while (optional_delimiter(Token::COMMA)) {
        if (current_token_if_delimiter() == Token::RBRACK) break;
        arguments.add(parse_expression(true));
      }
      result = NEW_NODE(Index(head, arguments.build()), range);
    }
  }
  *encountered_error = end_delimited(IndentationStack::DELIMITED, Token::RBRACK);
  return result;
}

Expression* Parser::parse_postfix_rest(Expression* head) {
  Token::Kind kind = current_token();
  auto range = current_range();
  ASSERT(Token::precedence(kind) == PRECEDENCE_POSTFIX || kind == Token::PERIOD);
  if (kind == Token::PERIOD) {
    consume();
    Identifier* name;
    if (current_token() != Token::IDENTIFIER) {
      if (is_eol(current_token())) {
        report_error(eol_range(previous_range(), current_range()),
                     "Incomplete expression");
      } else {
        report_error("Expected identifier");
      }
      name = NEW_NODE(Identifier(Symbol::invalid()), current_range());
    } else {
      name = parse_identifier();
    }
    return NEW_NODE(Dot(head, name), range);
  } else if (kind == Token::LBRACK) {
    bool had_errors;  // Ignored.
    return parse_postfix_index(head, &had_errors);
  } else {
    ASSERT(kind == Token::INCREMENT || kind == Token::DECREMENT);
    consume();
    return NEW_NODE(Unary(kind, false, head), range);
  }
}

Expression* Parser::parse_break_continue(bool allow_colon) {
  auto range = current_range();
  bool is_break = current_token() == Token::BREAK;
  consume();
  Identifier* label = null;
  if (is_current_token_attached() && current_token() == Token::PERIOD &&
      is_next_token_attached() && peek_token() == Token::IDENTIFIER) {
    consume(); // The `.`.
    label = parse_identifier();
  }
  if (label == null || is_delimiter(current_token(), allow_colon, false)) {
    return NEW_NODE(BreakContinue(is_break, null, label), range);
  } else {
    return NEW_NODE(BreakContinue(is_break, parse_expression(allow_colon), label), range);
  }
}

Expression* Parser::parse_conditional(bool allow_colon) {
  start_multiline_construct(IndentationStack::CONDITIONAL);
  auto result = parse_logical_spelled(allow_colon);
  while (current_token() == Token::CONDITIONAL) {
    result = parse_conditional_rest(result, allow_colon);
  }
  end_multiline_construct(IndentationStack::CONDITIONAL);
  return result;
}

Expression* Parser::parse_conditional_rest(Expression* head, bool allow_colon) {
  ASSERT(current_token() == Token::CONDITIONAL);
  ASSERT(indentation_stack_.top_kind() == IndentationStack::CONDITIONAL);
  auto range = current_range();
  delimit_with(Token::CONDITIONAL);
  switch_multiline_construct(IndentationStack::CONDITIONAL,
                             IndentationStack::CONDITIONAL_THEN);
  Expression* yes = parse_expression(allow_colon);
  Expression* no = null;
  if (!optional_delimiter(Token::COLON)) {
    report_error("Missing ':' in conditional expression");
    if (current_token() == Token::DEDENT) {
      // Don't even try to read the 'no' part.
      no = NEW_NODE(Error(), range);
    }
  }
  switch_multiline_construct(IndentationStack::CONDITIONAL_THEN,
                             IndentationStack::CONDITIONAL_ELSE);
  if (no == null) no = parse_expression(allow_colon);
  switch_multiline_construct(IndentationStack::CONDITIONAL_ELSE,
                             IndentationStack::CONDITIONAL);
  return NEW_NODE(If(head, yes, no), range);
}

Expression* Parser::parse_unary(bool allow_colon) {
  Token::Kind kind = current_token();
  switch (kind) {
    case Token::SUB:
    case Token::INCREMENT:
    case Token::DECREMENT:
    case Token::BIT_NOT: {
      auto range = current_range();
      consume();
      if (!is_current_token_attached()) {
        report_error(range.extend(current_range()),
                     "Can't have space between '%s' and the operand",
                     Token::symbol(kind).c_str());
      }
      if (kind == Token::DECREMENT) {
        diagnostics()->report_warning(range.extend(current_range()),
                                      "Prefix decrement is deprecated");
      }
      if (kind == Token::SUB &&
          (current_token() == Token::INTEGER || current_token() == Token::DOUBLE)) {
        Expression* expression = parse_primary(allow_colon);
        if (expression->is_LiteralInteger()) {
          expression->as_LiteralInteger()->set_is_negated(true);
          expression->set_range(range.extend(expression->range()));
          return expression;
        } else {
          ASSERT(expression->is_LiteralFloat());
          expression->as_LiteralFloat()->set_is_negated(true);
          expression->set_range(range.extend(expression->range()));
          return expression;
        }
      }
      Expression* expression = parse_precedence(PRECEDENCE_POSTFIX, allow_colon);
      return NEW_NODE(Unary(kind, true, expression), range);
    }
    case Token::NOT: {
      report_error("'not' must be parenthesized when used at this location");
      auto range = current_range();
      consume();
      Expression* expression = parse_unary(allow_colon);
      return NEW_NODE(Unary(Token::NOT, true, expression), range);
    }
    default: {
      return parse_primary(allow_colon);
    }
  }
}

Expression* Parser::parse_primary(bool allow_colon) {
  auto range = current_range();
  if (allow_colon && current_token() == Token::COLON) {
    return parse_block_or_lambda(current_indentation());
  } else if (current_token() == Token::DOUBLE_COLON) {
    return parse_block_or_lambda(current_indentation());
  } else if (current_token() == Token::LPAREN) {
    if (is_current_token_attached() && previous_token() == Token::IDENTIFIER) {
      diagnostics()->report_warning(current_range(),
                                    "Parenthesis should not be attached. Attempted call?");
    }
    start_delimited(IndentationStack::DELIMITED, Token::LPAREN, Token::RPAREN);
    Expression* expression = parse_expression(true);
    end_delimited(IndentationStack::DELIMITED, Token::RPAREN);
    return NEW_NODE(Parenthesis(expression), range);
  } else if (current_token() == Token::IDENTIFIER) {
    return parse_identifier();
  } else if (current_token() == Token::INTEGER) {
    Expression* expression = NEW_NODE(LiteralInteger(current_token_data()), range);
    consume();
    return expression;
  } else if (current_token() == Token::DOUBLE) {
    Expression* expression = NEW_NODE(LiteralFloat(current_token_data()), range);
    consume();
    return expression;
  } else if (current_token() == Token::STRING || current_token() == Token::STRING_MULTI_LINE) {
    return parse_string();
  } else if (current_token() == Token::STRING_PART || current_token() == Token::STRING_PART_MULTI_LINE) {
    return parse_string_interpolate();
  } else if (current_token() == Token::CHARACTER) {
    Expression* expression = NEW_NODE(LiteralCharacter(current_token_data()), range);
    consume();
    return expression;
  } else if (optional(Token::TRUE)) {
    return NEW_NODE(LiteralBoolean(true), range);
  } else if (optional(Token::FALSE)) {
    return NEW_NODE(LiteralBoolean(false), range);
  } else if (optional(Token::NULL_))  {
    return NEW_NODE(LiteralNull(), range);
  } else if (current_token() == Token::LBRACK) {
    return parse_list();
  } else if (current_token() == Token::LSHARP_BRACK) {
    return parse_byte_array();
  } else if (current_token() == Token::LBRACE) {
    return parse_map_or_set();
  } else if (is_eol(current_token())) {
    auto range = eol_range(previous_range(), current_range());
    report_error(range, "Incomplete expression");
    skip_to_dedent();
    return NEW_NODE(Error(), range);
  } else {
    report_error(range, "Unexpected %s", Token::symbol(current_token()).c_str());
    skip_to_dedent();
    return NEW_NODE(Error(), range);
  }
}

Identifier* Parser::parse_identifier() {
  ASSERT(current_token() == Token::IDENTIFIER);
  auto range = current_range();
  Symbol data = current_token_data();
  bool is_lsp_selection = current_state().scanner_state.is_lsp_selection();
  consume();
  if (is_lsp_selection) {
    return NEW_NODE(LspSelection(data), range);
  } else {
    return NEW_NODE(Identifier(data), range);
  }
}

ToitdocReference* Parser::parse_toitdoc_identifier_reference(int* end_offset) {
  bool encountered_error = false;
  ast::Expression* target = null;
  auto node_range = current_range();
  bool is_operator = false;
  while (true) {
    auto token = current_token();  // Scan the identifier.
    *end_offset = current_state().scanner_state.to;

    if (token == Token::ILLEGAL) {
      ASSERT(target == null);  // Otherwise we would have exited the loop below.
      // The only way this can happen, is if the character after the '.' was
      // an LSP_SELECTION_MARKER that didn't turn out to be a selection.
      report_error("Error while parsing identifier");
      encountered_error = true;
      break;
    }

    is_operator = is_operator_token(current_token());
    if (token != Token::IDENTIFIER && !is_operator) {
      ASSERT(target == null);  // Otherwise we would have exited the loop below.
      report_error("Expected identifier or operator as toitdoc target");
      encountered_error = true;
      break;
    }

    Identifier* id = null;
    if (is_operator) {
      auto token = current_token();
      auto operator_range = current_range();
      consume();
      if (token != Token::LBRACK) {
        id = NEW_NODE(Identifier(Token::symbol(token)), operator_range);
      } else {
        ASSERT(token == Token::LBRACK);
        if (current_token() != Token::RBRACK) {
          report_error(operator_range, "Missing closing ']'");
          id = NEW_NODE(Identifier(Token::symbol(token)), operator_range);
        } else {
          // Either `[]` or `[]=`.
          if (!is_current_token_attached()) report_error("Can't have space between '[' and ']'");
          operator_range = operator_range.extend(current_range());
          *end_offset = current_state().scanner_state.to;
          consume();
          if (current_token() == Token::ASSIGN) {
            if (!is_current_token_attached()) {
              report_error("Can't have space between ']' and '='");
            }
            operator_range = operator_range.extend(current_range());
            *end_offset = current_state().scanner_state.to;
            consume();
            id = NEW_NODE(Identifier(Symbols::index_put), operator_range);
          } else {
            id = NEW_NODE(Identifier(Symbols::index), operator_range);
          }
        }
      }
    } else {
      id = parse_identifier();
    }
    if (target == null) {
      target = id;
    } else {
      auto dot_range = target->range().extend(id->range());
      target = _new ast::Dot(target, id->as_Identifier());
      target->set_range(dot_range);
    }
    if (is_operator) break;
    if (!is_current_token_attached()) break;
    if (current_token() != Token::PERIOD) break;
    if (!is_next_token_attached()) break;
    if (peek_token() != Token::IDENTIFIER && !is_operator_token(peek_token())) break;
    consume(); // Consume the period.
  }

  bool is_setter = false;
  if (encountered_error) {
    // The error wins over anything we already parsed.
    target = NEW_NODE(Error(), current_range());
  } else if (!is_operator && is_current_token_attached() && current_token() == Token::ASSIGN) {
    // Found a setter.
    node_range = node_range.extend(current_range());
    *end_offset = current_state().scanner_state.to;
    consume();
    is_setter = true;
  }
  // If this is a setter, then the range is already extended to more than the target range,
  //   and the `extend` here won't have any effect.
  node_range = node_range.extend(target->range());
  return NEW_NODE(ToitdocReference(target, is_setter), node_range);
}

ToitdocReference* Parser::parse_toitdoc_signature_reference(int* end_offset) {
  auto open_range = current_range();

  ASSERT(current_token() == Token::LPAREN);
  consume();

  bool encountered_error = false;

  bool is_first = true;
  ast::Expression* target = null;
  bool is_target_setter = false;
  ListBuilder<ast::Parameter*> parameters;
  while (true) {
    if (is_eol(current_token()) && is_first) {
      report_error(eol_range(previous_range(), current_range()),
                  "Incomplete toitdoc reference");
      encountered_error = true;
      break;
    }
    if (current_token() == Token::ILLEGAL) {
      report_error(eol_range(previous_range(), current_range()),
                  "Illegal token while parsing toitdoc reference");
      encountered_error = true;
      break;
    }
    if (is_first) {
      is_first = false;
      auto parsed = parse_toitdoc_identifier_reference(end_offset);
      target = parsed->target();
      is_target_setter = parsed->is_setter();
      if (parsed->is_error()) {
        encountered_error = true;
        break;
      }
      continue;
    }

    if (current_token() == Token::RPAREN) break;

    auto range_start = current_range();

    bool is_block = false;
    if (current_token() == Token::LBRACK) {
      is_block = true;
      consume();
    }

    bool is_named = false;
    if (current_token() == Token::DECREMENT) {
      consume();
      is_named = true;
      // If the next token isn't attached, but isn't an identifier, then we will have a
      // different error later.
      if (!is_current_token_attached() && current_token() == Token::IDENTIFIER) {
        report_error("Can't have space between '--' and the parameter name");
        encountered_error = true;
        break;
      }
    }

    if (current_token() != Token::IDENTIFIER) {
      if (is_named || is_block) {
        report_error("Missing parameter name");
        encountered_error = true;
      } else {
        report_error("Missing parameter name or closing ')'");
        // If there is nothing following, we assume the user hasn't finished writing the
        // comment yet.
        encountered_error = current_token() != Token::EOS;
      }
      break;
    }
    auto name = parse_identifier();

    if (is_block) {
      if (current_token() != Token::RBRACK) {
        report_error("Missing ']' for block parameter");
        encountered_error = true;
        break;
      }
      consume();
    }
    parameters.add(NEW_NODE(Parameter(name, null, null, is_named, false, is_block),
                            range_start.extend(current_range())));
  }

  // Either we are at the closing parenthesis, or we are at an error token.
  // In both cases, we consider the current token to be part of the reference.
  *end_offset = current_state().scanner_state.to;

  if (target == null || encountered_error) {
    target = NEW_NODE(Error(), current_range());
  }
  return NEW_NODE(ToitdocReference(target, is_target_setter, parameters.build()),
                  open_range.extend(current_range()));
}

Expression* Parser::parse_list() {
  auto range = current_range();
  start_delimited(IndentationStack::LITERAL, Token::LBRACK, Token::RBRACK);
  ListBuilder<Expression*> elements;
  do {
    if (current_token_if_delimiter() == Token::RBRACK) break;
    elements.add(parse_expression(true));
  } while (optional_delimiter(Token::COMMA));
  end_delimited(IndentationStack::LITERAL, Token::RBRACK);
  return NEW_NODE(LiteralList(elements.build()), range);
}

Expression* Parser::parse_byte_array() {
  auto range = current_range();
  start_delimited(IndentationStack::LITERAL, Token::LSHARP_BRACK, Token::RBRACK);
  ListBuilder<Expression*> elements;
  do {
    // Speed up parsing of large byte array literals by recognizing a common
    // case here without going through the whole machinery.  Worth about a 25%
    // reduction in runtime.
    auto token = current_state().token;
    if (token == Token::INTEGER && peek_token() == Token::COMMA) {
      Expression* expression = NEW_NODE(LiteralInteger(current_token_data()), current_range());
      consume();
      elements.add(expression);
    } else if (token == Token::CHARACTER && peek_token() == Token::COMMA) {
      Expression* expression = NEW_NODE(LiteralCharacter(current_token_data()), current_range());
      consume();
      elements.add(expression);
    } else {
      if (current_token_if_delimiter() == Token::RBRACK) break;
      elements.add(parse_expression(true));
    }
  } while (optional_delimiter(Token::COMMA));
  end_delimited(IndentationStack::LITERAL, Token::RBRACK);
  return NEW_NODE(LiteralByteArray(elements.build()), range);
}

void Parser::discard_buffered_scanner_states() {
  // We encountered an error while trying to parse the interpolated expression.
  // Potentially some states have been buffered, which would now interfere with
  // scanning the rest of the string.
  // We simply discard all states as part of the error.
  // Potentially, we discard too much (even closing quotes), but it's hard
  // to recover, and this only happens in error cases.
  //
  // Example:
  //   log "$(499  // Because of the dedent, the compiler won't find a closing parenthesis.
  //   /* " // */
  // The closing ")" is missing, but it would be reasonable to read the second
  // quote as a closing one:
  //   log "$(
  //   /* "
  // However, because of the already peeked token, the scanner already read the
  // `/* " // */` as a comment, and we will now also report an error because of
  // the missing quote.
  if (current_state_.is_valid()) {
    consume();
    ASSERT(!current_state_.is_valid());
  }
  // Use up all scanner states that have been buffered. We might be unlucky
  // and consume tokens that should be in the string, but there isn't a good
  // way to know which part is string, and which isn't.
  scanner_state_queue_.discard_buffered();
}

Expression* Parser::parse_string_interpolate() {
  ASSERT(current_token() == Token::STRING_PART || current_token() == Token::STRING_PART_MULTI_LINE);
  auto start = current_range();
  ListBuilder<LiteralString*> parts;
  ListBuilder<LiteralString*> formats;
  ListBuilder<Expression*> expressions;

  bool is_multiline = current_token() == Token::STRING_PART_MULTI_LINE;
  bool last_interpolated_was_identifier = false;
  auto last_identifier_range = Source::Range::invalid();
  auto check_minus_after_identifier = [&](Symbol current_data) {
    if (last_interpolated_was_identifier &&
        current_data.c_str()[0] == '-' &&
        is_identifier_part(current_data.c_str()[1])) {
      diagnostics()->report_warning(last_identifier_range,
                                    "Interpolated identifiers followed by '-' must be parenthesized");
    }
  };
  Token::Kind end_token = is_multiline ? Token::STRING_END_MULTI_LINE : Token::STRING_END;
  Token::Kind kind;
  auto range = start;
  do {
    Symbol current_data = current_token_data();
    check_minus_after_identifier(current_data);
    parts.add(NEW_NODE(LiteralString(current_data, is_multiline), range));
    consume();
    last_interpolated_was_identifier = false;
    scan_interpolated_part();
    // We just passed $.
    LiteralString* format = null;
    bool was_parenthesized = false;
    ast::Expression* expression;
    if (current_token() == Token::LPAREN) {
      start_delimited(IndentationStack::DELIMITED, Token::LPAREN, Token::RPAREN);
      if (current_token() == Token::MOD) {
        consume();
        scan_string_format_part();
        ASSERT(current_token() == Token::STRING);
        format = NEW_NODE(LiteralString(current_token_data(), false),
                          range);
        consume();
      }
      expression = parse_expression(true);
      was_parenthesized = true;
      bool try_to_recover_flag = false;
      bool encountered_error = end_delimited(IndentationStack::DELIMITED, Token::RPAREN, try_to_recover_flag);
      if (encountered_error) discard_buffered_scanner_states();
    } else if (current_token() == Token::IDENTIFIER) {
      expression = parse_identifier();
      last_interpolated_was_identifier = true;
      last_identifier_range = expression->range();
    } else {
      if (current_token() == Token::EOS || current_token() == Token::DEDENT) {
        report_error("Incomplete string interpolation");
      } else {
        report_error("Illegal identifier");
      }
      expression = NEW_NODE(LiteralString(current_token_data(), is_multiline),
                            current_range());
      discard_buffered_scanner_states();
    }

    formats.add(format);

    if (!was_parenthesized) {
      while (true) {
        if (scanner_peek() == '[') {
          last_interpolated_was_identifier = false;
          bool encountered_error;
          expression = parse_postfix_index(expression, &encountered_error);
          if (encountered_error) {
            discard_buffered_scanner_states();
            break;  // Don't try to parse more postfix expressions.
          }
          continue; // Try for another postfix.
        } else if (scanner_look_ahead(0) == '.' &&
                   Scanner::is_identifier_start(scanner_look_ahead(1))) {
          ASSERT(current_token() == Token::PERIOD);
          // Ensure the current state is valid, so we can consume it.
          current_token();
          consume();
          scan_interpolated_part();
          if (current_token() == Token::IDENTIFIER && is_current_token_attached()) {
            Identifier* name = parse_identifier();
            expression = NEW_NODE(Dot(expression, name), range);
            last_interpolated_was_identifier = true;
            last_identifier_range = range;
            continue;  // Try for another postfix.
          } else {
            report_error("Non-identifier member name");
            discard_buffered_scanner_states();
          }
        }
        break;
      }
    }

    expressions.add(expression);
    scan_string_part(is_multiline);
    kind = current_state().scanner_state.token();
    range = current_range();
  } while (kind != end_token);

  Symbol current_data  = current_token_data();
  check_minus_after_identifier(current_data);
  parts.add(NEW_NODE(LiteralString(current_data, is_multiline), range));
  consume();
  return NEW_NODE(LiteralStringInterpolation(parts.build(), formats.build(), expressions.build()), start);
}

Expression* Parser::parse_map_or_set() {
  auto range = current_range();
  start_delimited(IndentationStack::LITERAL, Token::LBRACE, Token::RBRACE);

  if (optional_delimiter(Token::COLON)) {
    end_delimited(IndentationStack::LITERAL, Token::RBRACE);
    return NEW_NODE(LiteralMap(List<Expression*>(), List<Expression*>()), range);
  } else if (current_token_if_delimiter() == Token::RBRACE) {
    end_delimited(IndentationStack::LITERAL, Token::RBRACE);
    return NEW_NODE(LiteralSet(List<Expression*>()), range);
  }

  Expression* first = parse_expression(false);
  if (current_token() == Token::COLON) {
    ListBuilder<Expression*> keys;
    ListBuilder<Expression*> values;
    keys.add(first);
    consume();
    values.add(parse_expression(true));
    while (optional_delimiter(Token::COMMA)) {
      if (current_token_if_delimiter() == Token::RBRACE) break;
      keys.add(parse_expression(false));
      bool has_colon = false;
      if (current_token() == Token::COLON) {
        has_colon = true;
        consume();
      } else {
        report_error("Missing ':' to separate map key and value");
      }
      Expression* value;
      if (has_colon || current_token() != Token::DEDENT) {
        value = parse_expression(true);
      } else {
        value = NEW_NODE(Error, current_range());
      }
      values.add(value);
    }
    end_delimited(IndentationStack::LITERAL, Token::RBRACE);
    return NEW_NODE(LiteralMap(keys.build(), values.build()), range);
  } else {
    ListBuilder<Expression*> elements;
    elements.add(first);
    while (optional_delimiter(Token::COMMA)) {
      if (current_token_if_delimiter() == Token::RBRACE) break;
      // TODO(florian): in theory we could allow colons in set expressions.
      elements.add(parse_expression(false));
    }
    end_delimited(IndentationStack::LITERAL, Token::RBRACE);
    return NEW_NODE(LiteralSet(elements.build()), range);
  }
}

bool Parser::peek_type(ParserPeeker* peeker) {
  bool expects_identifier = true;

  while (true) {
    auto token = peeker->current_token();
    if (expects_identifier) {
      if (token == Token::IDENTIFIER) {
        peeker->consume();
        expects_identifier = false;
        continue;
      }
      return false;
    }
    if (token == Token::PERIOD) {
      peeker->consume();
      expects_identifier = true;
      continue;
    }
    if (token == Token::CONDITIONAL) {
      peeker->consume();
      return true;
    }
    return true;
  }
}

Expression* Parser::parse_type(bool is_type_annotation) {
  if (is_type_annotation) {
    ASSERT(current_token() == Token::DIV || current_token() == Token::RARROW);
    if (current_token() == Token::DIV) {
      consume();
    } else {
      // Return type: ->
      ASSERT(current_token() == Token::RARROW);
      consume();
    }
  }
  auto start_range = current_range();
  Expression* type = null;
  bool encountered_pseudo_keyword = false;
  while (true) {
    if (current_token() != Token::IDENTIFIER) {
      report_error("Unexpected token while parsing type");
      auto bad_type_range = start_range.extend(current_range().from());
      if (type != null) return type;
      return NEW_NODE(Error, bad_type_range);
    }
    auto id = parse_identifier();
    if (id->data() == Symbols::implements ||
        id->data() == Symbols::extends) {
      report_error(id->range(), "Unexpected token in type: '%s'", id->data().c_str());
      encountered_pseudo_keyword = true;
    }
    if (type == null) {
      type = id;
    } else {
      type = NEW_NODE(Dot(type, id), id->range());
    }
    if (is_current_token_attached() && current_token() == Token::PERIOD) {
      consume();
    } else {
      break;
    }
  };
  auto type_range = type->range();
  bool is_nullable = false;
  if (is_type_annotation && is_current_token_attached()) {
    if (current_token() == Token::CONDITIONAL) {
      type_range = type_range.extend(current_range());
      consume();
      is_nullable = true;
    }
  }
  if (encountered_pseudo_keyword && type == null) {
    auto last_identifier = type->is_Dot() ? type->as_Dot()->name() : type;
    auto bad_type_range = start_range.extend(last_identifier->range());
    return NEW_NODE(Error, bad_type_range);
  }
  if (is_nullable) {
    return NEW_NODE(Nullable(type), type_range);
  }
  return type;
}

bool Parser::peek_block_parameter(ParserPeeker* peeker) {
  // Block parameters don't have default values, named parameters, and can't be named.
  auto token = peeker->current_token();
  if (token != Token::IDENTIFIER) return false;
  peeker->consume();
  if (peeker->current_token() == Token::DIV) {
    peeker->consume();
    if (!peek_type(peeker)) return false;
  }
  return true;
}

std::pair<Expression*, List<Parameter*>> Parser::parse_parameters(bool allow_return_type) {
  Expression* return_type = null;
  ListBuilder<Parameter*> parameters;
  auto declaration_indentation = indentation_stack_.top_indentation();
  bool reported_unusual_indentation = false;
  while (true) {
    auto range = current_range();
    bool unusual_indentation = at_newline() && current_indentation() < declaration_indentation + 4;
    bool is_field_storing = false;
    bool is_block = false;
    bool is_bracket_block = false;
    bool is_named = false;
    Identifier* name = null;
    Expression* default_value = null;
    if (current_token() == Token::LBRACK) {
      consume();
      is_bracket_block = true;
    }
    if (current_token() == Token::DECREMENT) {
      consume();
      if (current_token() == Token::IDENTIFIER ||
          current_token() == Token::PERIOD) {
        if (!is_current_token_attached()) {
          report_error("Can't have space between '--' and the parameter name");
        }
        is_named = true;
      } else {
        report_error("Missing parameter name");
      }
    }
    if (is_bracket_block) {
      is_block = true;
      bool bad_name = false;
      if (current_token() == Token::IDENTIFIER) {
        name = parse_identifier();
      } else {
        if (current_token() == Token::ASSIGN || current_token() == Token::RBRACK) {
          report_error("Missing parameter name");
        } else {
          report_error("Invalid parameter name");
        }
        bad_name = true;
      }
      if (current_token() == Token::ASSIGN) {
        consume();
        default_value = parse_precedence(PRECEDENCE_POSTFIX, true);
      }
      if (current_token() != Token::RBRACK) {
        report_error("Missing ']' for block parameter");
        while (current_token() != Token::RBRACK &&
               current_token() != Token::DEDENT &&
               current_token() != Token::COLON) {
          consume();
        }
      }
      if (current_token() == Token::RBRACK) consume();
      // Don't pollute the rest of the compiler with parameter names that are invalid
      //   and drop the parameter so far.
      if (bad_name) continue;
    } else if (current_token() == Token::IDENTIFIER || current_token() == Token::PERIOD) {
      if (current_token() == Token::IDENTIFIER) {
        name = parse_identifier();
        if (name->data() == Symbols::this_) {
          if (current_token() != Token::PERIOD) {
            // No need to report an error here: this will happen later, when we
            //   complain, that 'this' isn't a valid parameter name.
            is_field_storing = false;
          } else {
            if (!is_current_token_attached()) {
              // Report error, but continue.
              report_error("Can't have space between 'this' and '.'");
            }
            consume();
            if (current_token() == Token::IDENTIFIER) {
              if (!is_current_token_attached()) {
                // Report error, but continue.
                report_error("Can't have space between '.' and the field name");
              }
              is_field_storing = true;
              name = parse_identifier();
            } else {
              // No need to report an error.
              // The name is still set to 'this', which will yield an
              //   error later.
              ASSERT(name->data() == Symbols::this_);
              is_field_storing = false;
            }
          }
        }
      } else {
        ASSERT(current_token() == Token::PERIOD);
        consume();
        is_field_storing = true;
        if (current_token() == Token::IDENTIFIER) {
          if (!is_current_token_attached()) {
            // Report error, but continue.
            report_error("Can't have space between '.' and the field name");
          }
          is_field_storing = true;
          name = parse_identifier();
        } else {
          report_error("Missing parameter name");
          // Don't pollute the rest of the compiler with parameter names that are invalid
          //   and drop the parameter so far.
          continue;
        }
      }
    } else if (current_token() == Token::RARROW && allow_return_type) {
      // The return-type.
      if (return_type != null) {
        report_error("Return type is declared multiple times");
      }
      return_type = parse_type(true);
      continue;
    } else {
      break;
    }
    Expression* type = null;
    if (current_token() == Token::DIV) {
      type = parse_type(true);
    }
    // The default_value can only be non-null if we encountered it inside the
    // brackets. In that case we will report an error during resolution.
    ASSERT(default_value == null || is_block);
    if (current_token() == Token::ASSIGN) {
      consume();
      default_value = parse_precedence(PRECEDENCE_POSTFIX, true);
    }
    if (unusual_indentation && !reported_unusual_indentation) {
      ASSERT(range.is_valid());
      diagnostics()->report_warning(range, "Unusual indentation for parameter");
      reported_unusual_indentation = true;
    }
    ASSERT(name != null);
    parameters.add(NEW_NODE(Parameter(name, type, default_value, is_named, is_field_storing, is_block),
                            range.extend(name->range())));
  }
  return std::make_pair(return_type, parameters.build());
}

List<Parameter*> Parser::parse_block_parameters(bool* present) {
  *present = false;
  if (current_token() != Token::BIT_OR) return List<Parameter*>();
  start_delimited(IndentationStack::DELIMITED, Token::BIT_OR, Token::BIT_OR);
  *present = true;
  auto result = parse_parameters(false);
  if (current_token() != Token::BIT_OR && !is_eol(current_token())) {
    report_error("Invalid parameter name");
    bool try_to_recover = true;
    bool report_error_on_missing = false;
    end_delimited(IndentationStack::DELIMITED,
                  Token::BIT_OR,
                  try_to_recover,
                  report_error_on_missing);
  } else {
    end_delimited(IndentationStack::DELIMITED, Token::BIT_OR);
  }
  return result.second;
}

Expression* Parser::parse_string() {
  ASSERT(current_token() == Token::STRING || current_token() == Token::STRING_MULTI_LINE);
  bool is_multiline = current_token() == Token::STRING_MULTI_LINE;
  auto range = current_range();
  LiteralString* result = NEW_NODE(LiteralString(current_token_data(), is_multiline),
                                   range);
  consume();
  return result;
}

Source::Range Parser::current_range() {
  auto& state = current_state();
  if (state.token == Token::NEWLINE || state.token == Token::DEDENT || state.token == Token::EOS) {
    int shortened_to = std::min(state.scanner_state.to, state.scanner_state.from + 1);
    if (source_->text()[shortened_to] == '\n' && source_->text()[shortened_to - 1] == '\r') {
      shortened_to++;
    }
    return source_->range(state.scanner_state.from, shortened_to);
  }
  return source_->range(state.scanner_state.from, state.scanner_state.to);
}

Source::Range Parser::current_range_safe() {
  if (current_state_.is_valid() || scanner_state_queue_.buffered_count() > 0) {
    return current_range();
  }
  return scanner_->current_range();
}

Source::Range Parser::previous_range() {
  auto& previous_state = scanner_state_queue_.get(-1);
  return source_->range(previous_state.from, previous_state.to);
}

Token::Kind Parser::previous_token() {
  auto& previous_state = scanner_state_queue_.get(-1);
  return previous_state.token();
}

bool Parser::optional(Token::Kind kind) {
  if (current_token() != kind) return false;
  consume();
  return true;
}

bool Parser::optional_delimiter(Token::Kind kind) {
  if (current_token() == kind) {
    delimit_with(kind);
    return true;
  }
  if (current_token() == Token::DEDENT &&
      current_indentation() == indentation_stack_.top_indentation() &&
      peek_token() == kind) {
    delimit_with(kind);
    return true;
  }
  return false;
}

} // namespace toit::compiler
} // namespace toit
