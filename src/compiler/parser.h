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

#pragma once

#include <utility>

#include "ast.h"
#include "../top.h"
#include "scanner.h"
#include "sources.h"
#include "token.h"

namespace toit {
namespace compiler {

class Diagnostics;
class SymbolCanonicalizer;
class ParserPeeker;

class IndentationStack {
 public:
  enum Kind {
    IMPORT,
    EXPORT,
    DECLARATION,
    DECLARATION_SIGNATURE,
    CLASS,
    BLOCK,
    IF_CONDITION,
    IF_BODY,
    WHILE_CONDITION,
    WHILE_BODY,
    FOR_INIT,
    FOR_CONDITION,
    FOR_UPDATE,
    FOR_BODY,
    CONDITIONAL,
    CONDITIONAL_THEN,
    CONDITIONAL_ELSE,
    LOGICAL,
    CALL,
    ASSIGNMENT,
    DELIMITED,
    LITERAL,
    PRIMITIVE,
    TRY,
    SEQUENCE,
  };

  int top_indentation() const { return data_.back().indentation; }
  Kind top_kind() const { return data_.back().kind; }
  Token::Kind top_end_token() const { return data_.back().end_token; }
  Source::Range top_start_range() const { return data_.back().start_range; }

  int size() const { return data_.size(); }

  void push(int level, Kind kind, Source::Range start_range) {
    push(level, kind, Token::INVALID, start_range);
  }

  void push(int level, Kind kind, Token::Kind end_token, Source::Range start_range) {
    data_.push_back(Entry(level, kind, end_token, start_range));
  }

  void pop(int n) {
    ASSERT(n <= size());
    data_.resize(size() - n);
  }

  int pop() {
    int result = top_indentation();
    data_.pop_back();
    return result;
  }

  bool is_empty() const { return data_.empty(); }

  bool is_outmost(Kind kind) {
    ASSERT(top_kind() == kind);
    int this_indentation = top_indentation();
    for (int i = data_.size() - 2; i >= 0; i--) {
      auto entry = data_[i];
      if (entry.indentation != this_indentation) return true;
      if (entry.kind == kind) return false;
    }
    return true;
  }

  int indentation_at(int index) const { return data_[index].indentation; }
  Kind kind_at(int index) const { return data_[index].kind; }
  Token::Kind end_token_at(int index) const { return data_[index].end_token; }
  Source::Range start_range_at(int index) const { return data_[index].start_range; }


 private:
  struct Entry {
    Entry(int level, Kind kind, Token::Kind end_token, Source::Range start_range)
        : indentation(level), kind(kind), end_token(end_token), start_range(start_range) { }
    Entry()
        : indentation(-1), kind(IMPORT), end_token(Token::INVALID), start_range(Source::Range::invalid()) { }

    int indentation;
    Kind kind;
    Token::Kind end_token;
    Source::Range start_range;
  };

  std::vector<Entry> data_;
};

// A queue that maintains the scanner tokens.
//
// Always keeps one previous scanner state around (initially set to invalid).
class ScannerStateQueue {
 public:
  explicit ScannerStateQueue(Scanner* scanner)
      : scanner_(scanner) {
    const int initial_size = 4;
    auto buffer_memory = malloc(initial_size * sizeof(Scanner::State));
    auto state_buffer = unvoid_cast<Scanner::State*>(buffer_memory);
    states_ = List<Scanner::State>(state_buffer, initial_size);
    states_[previous_index_] = Scanner::State::invalid();
    buffered_count_with_previous_ = 1;
  }

  ScannerStateQueue(const ScannerStateQueue&) = delete;

  ~ScannerStateQueue() {
    free(states_.data());
  }

  void consume() {
    ASSERT(buffered_count_with_previous_ > 1);
    previous_index_ = wrap(previous_index_ + 1);
    buffered_count_with_previous_--;
  }

  void discard_buffered() {
    previous_index_ = wrap(previous_index_ + buffered_count_with_previous_ - 1);
    buffered_count_with_previous_ = 1;  // Always keep the 'previous'.
  }

  void buffer_interpolated_part() {
    ASSERT(buffered_count_with_previous_ == 1);
    buffer(scanner()->next_interpolated_part());
  }

  void buffer_string_part(bool is_multiline) {
    ASSERT(buffered_count_with_previous_ == 1);
    buffer(scanner()->next_string_part(is_multiline));
  }

  void buffer_string_format_part() {
    ASSERT(buffered_count_with_previous_ == 1);
    buffer(scanner()->next_string_format_part());
  }

  // Returns the scanner state at position i.
  //
  // It is legal to ask for `-1` to get the previous state.
  const Scanner::State& get(int i) {
    if (i == -1) return states_[previous_index_];
    while (i >= buffered_count_with_previous_ - 1) {
      buffer(scanner()->next());
    }
    return states_[wrap(previous_index_ + 1 + i)];
  }

  int scanner_look_ahead(int n = 1) {
    ASSERT(buffered_count_with_previous_ == 1);
    return scanner()->look_ahead(n);
  }

  int buffered_count() const {
    return buffered_count_with_previous_ - 1;
  }

 private:
  Scanner* scanner_;
  List<Scanner::State> states_;

  // The index to the 'previous' state. (The one that was most recently consumed).
  // The first "normal" state is at index `wrap(previous_index_ + 1)`.
  int previous_index_ = 0;
  int buffered_count_with_previous_ = 0;  // Includes the 'previous' state.

  Scanner* scanner() { return scanner_; }

  int wrap(int i) {
    ASSERT(Utils::is_power_of_two(states_.length()));
    return i & (states_.length() - 1);
  }

  void buffer(const Scanner::State& state) {
    if (buffered_count_with_previous_ >= states_.length()) {
      // Resize.
      // Rotate the states into the correct place, and then double in size.
      if (previous_index_ != 0) rotate(previous_index_);
      auto old_buffer = states_.data();
      int new_length = states_.length() * 2;
      auto new_buffer = unvoid_cast<Scanner::State*>(
        realloc(old_buffer, new_length * sizeof(Scanner::State)));
      states_ = List<Scanner::State>(new_buffer, new_length);
    }
    states_[wrap(previous_index_ + buffered_count_with_previous_)] = state;
    buffered_count_with_previous_++;
  }

  void rotate(int new_start) {
    // Reverse the two parts. Then reverse them together.
    reverse(0, new_start);
    reverse(new_start, states_.length());
    reverse(0, states_.length());
    previous_index_ = 0;
  }

  // [end] is exclusive.
  void reverse(int start, int end) {
    int from = start;
    int to = end - 1;  // `end` is exclusive.
    while (from < to) {
      auto tmp = states_[from];
      states_[from] = states_[to];
      states_[to] = tmp;
      from++;
      to--;
    }
  }
};

class Parser {
 public:
  Parser(Source* source,
         Scanner* scanner,
         Diagnostics* diagnostics)
      : source_(source)
      , scanner_(scanner)
      , diagnostics_(diagnostics)
      , scanner_state_queue_(scanner)
      , current_state_(State::invalid())
      , peek_state_(State::invalid()) { }

  ast::Unit* parse_unit(Source* override_source = null);

  /// Parses a toitdoc reference.
  ///
  /// Keywords are not recognized and treated as identifiers.
  /// For example `for` will be parsed as an identifier instead of
  ///    as keyword.
  ///
  /// Returns the end-offset (position in the source) of the returned expression.
  ast::ToitdocReference* parse_toitdoc_reference(int* end_offset);

 private:
  friend class ParserPeeker;

  struct State {
    Scanner::State scanner_state;
    // In most cases, the token kind is redundant with the scanner's token.
    // However, we sometimes switch the `NEWLINE` or `EOS` token to `DEDENT`.
    Token::Kind token;
    bool at_newline;

    static State invalid() {
      return {
        .scanner_state = Scanner::State::invalid(),
        .token = Token::DEDENT,
        .at_newline = true,
      };
    }

    bool is_valid() const { return scanner_state.is_valid(); }
    void mark_invalid() { scanner_state.mark_invalid(); }
  };

  Source* source_;
  Scanner* scanner_;
  Diagnostics* diagnostics_;

  bool encountered_stack_overflow_ = false;

  ScannerStateQueue scanner_state_queue_;
  // A cache of the current parser state.
  // The parser state is completely determined by the current scanner state.
  State current_state_;
  // A state we can use when returning from [peek_state]. This avoids copying
  //   the whole state all the time.
  State peek_state_;

  IndentationStack indentation_stack_;

  Scanner* scanner() { return scanner_; }
  Diagnostics* diagnostics() const { return diagnostics_; }

  bool allowed_to_consume(Token::Kind token);
  bool consumer_exists(Token::Kind token, int next_line_indentation);

  void report_error(Source::Range range, const char* format, ...);
  void report_error(const char* format, ...);

  bool check_tree_height(ast::Unit* unit);
  void check_indentation_stack_depth();

  // Start a multiline construct which is used to report a `DEDENT` token
  // when encountering a token that has same or less indentation than the
  // current indentation.
  void start_multiline_construct(IndentationStack::Kind kind);
  // Start a multiline construct which is used to report a `DEDENT` token
  // when encountering a token that has same or less indentation than the
  // given indentation.
  void start_multiline_construct(IndentationStack::Kind kind, int indentation);

  // Must be called when the next token (potentially after a "valid" dedent)
  //  is [token].
  void delimit_with(Token::Kind token);

  // Returns true if the delimiter was found.
  bool skip_to_body(Token::Kind delimiter);
  void skip_to_dedent();
  void skip_to_end_of_multiline_construct();

  void end_multiline_construct(IndentationStack::Kind kind,
                               bool must_finish_with_dedent = false);
  void switch_multiline_construct(IndentationStack::Kind from, IndentationStack::Kind to);

  void start_delimited(IndentationStack::Kind kind, Token::Kind start_token, Token::Kind end_token);
  // Returns whether there was an error when searching for the delimiter.
  // When there is an error (no end_token) and [try_to_recover] is true, then:
  //   * tries to find the end-token a bit later on the same line.
  //   * if still not found, skips to dedent.
  bool end_delimited(IndentationStack::Kind kind,
                     Token::Kind end_token,
                     bool try_to_recover = true,
                     bool report_error_on_missing_delimiter = true);

  int scanner_peek() { return scanner_look_ahead(0); }
  int scanner_look_ahead(int n = 1) {
    ASSERT(!current_state_.is_valid());
    return scanner_state_queue_.scanner_look_ahead(n);
  }


  /// Returns the n'th state after the current one.
  ///
  /// If `n == 0` and the current_state_ is valid, returns it.
  ///
  /// In most cases, `n == 0` is only equivalent to the current state. However,
  ///   current_state() automatically consumes NEWLINE tokens if they don't
  ///   represent `DEDENT`s.
  ///
  /// This function does *not* drop NEWLINEs.
  ///
  /// This function correctly sets the `at_newline` field.
  ///
  /// Since this function peeks into the scanner (and buffers scanner states)
  ///   one must not peek into states where the scanner is switched (as for
  ///   strings/string interpolations).
  ///
  /// NEWLINE/EOS tokens are changed to DEDENT tokens depending on the
  ///   current indentation-stack.
  const State& peek_state(int n = 1) {
    if (current_state_.is_valid() && n == 0) return current_state_;
    peek_state(n, &peek_state_);
    return peek_state_;
  }

  // See peek_state. Instead of returning, fills the given state.
  void peek_state(int n, State* state);

  /// Returns the token after the current token.
  Token::Kind peek_token() { return peek_state().token; }

  /// Returns the current state.
  ///
  /// If necessary initiates a request to the scanner to produce the next token.
  ///
  /// Skips over NEWLINE states, but updates the next state's `at_newline` field
  ///   when it does that.
  const State& current_state() {
    if (!current_state_.is_valid()) {
      peek_state(0, &current_state_);
      if (current_state_.token == Token::NEWLINE) {
        consume();
        peek_state(0, &current_state_);
      }
    }
    return current_state_;
  }

  /// The indentation of the current line.
  ///
  /// All tokens in the same line have the same indentation.
  /// This function does *not* return the indentation of the current token.
  int current_indentation() { return current_state().scanner_state.indentation; }

  /// The indentation of the next token after the dedent.
  int indentation_after_dedent() {
    ASSERT(current_state().token == Token::DEDENT);
    return peek_state(1).scanner_state.indentation;
  }

  /// The range of the current token.
  Source::Range current_range();

  /// The range of the current token.
  /// If the current static is not valid, does *not* invoke the scanner to
  ///   get the next token.
  Source::Range current_range_safe();

  /// The range of the previous token.
  Source::Range previous_range();

  // The previous token.
  Token::Kind previous_token();

  Symbol current_token_data() {
    if (current_state().scanner_state.data.is_valid()) {
      return current_state().scanner_state.data;
    } else {
      return Token::symbol(current_token());
    }
  }

  Token::Kind current_token() {
    return current_state().token;
  }

  /// Returns the current token, if it is used as delimiter.
  /// Delimiters are allowed to be at the same level as the current construct, which
  /// means that this function may sometimes look after a DEDENT token.
  /// If the current_token() is *not* a DEDENT, then the function is equivalent to
  /// `current_token()`.
  Token::Kind current_token_if_delimiter() {
    auto kind = current_token();
    if (kind == Token::DEDENT &&
        current_indentation() == indentation_stack_.top_indentation()) {
      return peek_token();
    }
    return kind;
  }

  bool at_newline() { return current_state().at_newline; }

  /// Whether the current token is directly attached to the previous token.
  ///
  /// The token is attached, if there is no whitespace between itself and the
  /// previous token.
  bool is_current_token_attached() {
    if (current_token() == Token::DEDENT ||
        current_token() == Token::EOS) {
      return false;
    }
    return !at_newline() && current_state().scanner_state.is_attached();
  }

  bool is_next_token_attached() {
    auto next_state = peek_state();
    auto next_token = next_state.token;
    switch (next_token) {
      case Token::NEWLINE:
      case Token::EOS:
      case Token::DEDENT:
        return false;
      default:
        return next_state.scanner_state.is_attached();
    }
  }

  /// Consumes the current state.
  ///
  /// Does *not* automatically get the next state. This is, so that we can switch
  ///   modes in the scanner. Specifically, we need to use a different scanning
  ///   function, when we are parsing string interpolations.
  /// See `current_state()` where we fetch the next state.
  void consume() {
    ASSERT(current_state_.is_valid());
    current_state_.mark_invalid();
    scanner_state_queue_.consume();
  }

  bool optional(Token::Kind kind);
  bool optional_delimiter(Token::Kind kind);

  /// Requests the scanner to continue scanning for an interpolated expression in
  /// a string.
  void scan_interpolated_part() {
    ASSERT(!current_state_.is_valid());
    scanner_state_queue_.buffer_interpolated_part();
  }
  /// Requests the scanner to continue scanning for a string after an
  /// interpolated expression.
  void scan_string_part(bool is_multiline) {
    ASSERT(!current_state_.is_valid());
    scanner_state_queue_.buffer_string_part(is_multiline);
  }
  /// Requests the scanner to continue scanning for an interpolation format in an
  /// interpolated expression.
  void scan_string_format_part() {
    ASSERT(!current_state_.is_valid());
    scanner_state_queue_.buffer_string_format_part();
  }

  ast::Import* parse_import();
  ast::Export* parse_export();
  // Callers are free to consume any `abstract` keyword, but they aren't required to.
  ast::Declaration* parse_declaration(bool is_abstract);

  // Whether the peeker is currently looking at a type. This function must be
  // optimistic (can allow more), but must be reasonable from a user's point of
  // view.
  bool peek_type(ParserPeeker* peeker);
  ast::Expression* parse_type(bool is_type_annotation);
  ast::Class* parse_class_interface_or_monitor(bool is_abstract);

  ast::Sequence* parse_sequence();
  ast::Expression* parse_block_or_lambda(int indentation);

  ast::Expression* parse_expression_or_definition(bool allow_colon);
  ast::Expression* parse_expression(bool allow_colon);
  ast::Expression* parse_definition(bool allow_colon);
  ast::Expression* parse_if();
  ast::Expression* parse_while();
  ast::Expression* parse_for();
  ast::Expression* parse_try_finally();

  ast::Expression* parse_break_continue(bool allow_colon);

  ast::Expression* parse_conditional(bool allow_colon);

  ast::Expression* parse_logical_spelled(bool allow_colon);
  ast::Expression* parse_not_spelled(bool allow_colon);

  ast::Expression* parse_argument(bool allow_colon, bool full_expression);
  ast::Expression* parse_call(bool allow_colon);

  ast::Expression* parse_precedence(Precedence precedence, bool allow_colon, bool is_call_primitive = false);
  ast::Expression* parse_postfix_rest(ast::Expression* head);
  ast::Expression* parse_conditional_rest(ast::Expression* head, bool allow_colon);
  ast::Expression* parse_unary(bool allow_colon);
  ast::Expression* parse_primary(bool allow_colon);

  ast::Identifier* parse_identifier();
  ast::Expression* parse_string();

  ast::ToitdocReference* parse_toitdoc_identifier_reference(int* end_offset);
  ast::ToitdocReference* parse_toitdoc_signature_reference(int* end_offset);

  /// Discards all buffered scanner states (including the current state).
  ///
  /// When a string-interpolation encounters an error, all buffered scanner states
  /// are discarded, so that the scanner can continue parsing the remaining string.
  void discard_buffered_scanner_states();
  ast::Expression* parse_string_interpolate();
  ast::Expression* parse_list();
  ast::Expression* parse_byte_array();
  ast::Expression* parse_map_or_set();

  ast::Expression* parse_postfix_index(ast::Expression* head, bool* encountered_error);
  bool peek_block_parameter(ParserPeeker* peeker);
  std::pair<ast::Expression*, List<ast::Parameter*>> parse_parameters(bool allow_return_type);
  List<ast::Parameter*> parse_block_parameters(bool* present);
};

} // namespace toit::compiler
} // namespace toit
