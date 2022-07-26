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

  int top_indentation() const { return _data.back().indentation; }
  Kind top_kind() const { return _data.back().kind; }
  Token::Kind top_end_token() const { return _data.back().end_token; }
  Source::Range top_start_range() const { return _data.back().start_range; }

  int size() const { return _data.size(); }

  void push(int level, Kind kind, Source::Range start_range) {
    push(level, kind, Token::INVALID, start_range);
  }

  void push(int level, Kind kind, Token::Kind end_token, Source::Range start_range) {
    _data.push_back(Entry(level, kind, end_token, start_range));
  }

  void pop(int n) {
    ASSERT(n <= size());
    _data.resize(size() - n);
  }

  int pop() {
    int result = top_indentation();
    _data.pop_back();
    return result;
  }

  bool is_empty() const { return _data.empty(); }

  bool is_outmost(Kind kind) {
    ASSERT(top_kind() == kind);
    int this_indentation = top_indentation();
    for (int i = _data.size() - 2; i >= 0; i--) {
      auto entry = _data[i];
      if (entry.indentation != this_indentation) return true;
      if (entry.kind == kind) return false;
    }
    return true;
  }

  int indentation_at(int index) const { return _data[index].indentation; }
  Kind kind_at(int index) const { return _data[index].kind; }
  Token::Kind end_token_at(int index) const { return _data[index].end_token; }
  Source::Range start_range_at(int index) const { return _data[index].start_range; }


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

  std::vector<Entry> _data;
};

// A queue that maintains the scanner tokens.
//
// Always keeps one previous scanner state around (initially set to invalid).
class ScannerStateQueue {
 public:
  explicit ScannerStateQueue(Scanner* scanner)
      : _scanner(scanner) {
    const int initial_size = 4;
    auto buffer_memory = malloc(initial_size * sizeof(Scanner::State));
    auto state_buffer = unvoid_cast<Scanner::State*>(buffer_memory);
    _states = List<Scanner::State>(state_buffer, initial_size);
    _states[_previous_index] = Scanner::State::invalid();
    _buffered_count_with_previous = 1;
  }

  ScannerStateQueue(const ScannerStateQueue&) = delete;

  ~ScannerStateQueue() {
    free(_states.data());
  }

  void consume() {
    ASSERT(_buffered_count_with_previous > 1);
    _previous_index = wrap(_previous_index + 1);
    _buffered_count_with_previous--;
  }

  void discard_buffered() {
    _previous_index = wrap(_previous_index + _buffered_count_with_previous - 1);
    _buffered_count_with_previous = 1;  // Always keep the 'previous'.
  }

  void buffer_interpolated_part() {
    ASSERT(_buffered_count_with_previous == 1);
    buffer(scanner()->next_interpolated_part());
  }

  void buffer_string_part(bool is_multiline) {
    ASSERT(_buffered_count_with_previous == 1);
    buffer(scanner()->next_string_part(is_multiline));
  }

  void buffer_string_format_part() {
    ASSERT(_buffered_count_with_previous == 1);
    buffer(scanner()->next_string_format_part());
  }

  // Returns the scanner state at position i.
  //
  // It is legal to ask for `-1` to get the previous state.
  const Scanner::State& get(int i) {
    if (i == -1) return _states[_previous_index];
    while (i >= _buffered_count_with_previous - 1) {
      buffer(scanner()->next());
    }
    return _states[wrap(_previous_index + 1 + i)];
  }

  int scanner_look_ahead(int n = 1) {
    ASSERT(_buffered_count_with_previous == 1);
    return scanner()->look_ahead(n);
  }

  int buffered_count() const {
    return _buffered_count_with_previous - 1;
  }

 private:
  Scanner* _scanner;
  List<Scanner::State> _states;

  // The index to the 'previous' state. (The one that was most recently consumed).
  // The first "normal" state is at index `wrap(_previous_index + 1)`.
  int _previous_index = 0;
  int _buffered_count_with_previous = 0;  // Includes the 'previous' state.

  Scanner* scanner() { return _scanner; }

  int wrap(int i) {
    ASSERT(Utils::is_power_of_two(_states.length()));
    return i & (_states.length() - 1);
  }

  void buffer(const Scanner::State& state) {
    if (_buffered_count_with_previous >= _states.length()) {
      // Resize.
      // Rotate the states into the correct place, and then double in size.
      if (_previous_index != 0) rotate(_previous_index);
      auto old_buffer = _states.data();
      int new_length = _states.length() * 2;
      auto new_buffer = unvoid_cast<Scanner::State*>(
        realloc(old_buffer, new_length * sizeof(Scanner::State)));
      _states = List<Scanner::State>(new_buffer, new_length);
    }
    _states[wrap(_previous_index + _buffered_count_with_previous)] = state;
    _buffered_count_with_previous++;
  }

  void rotate(int new_start) {
    // Reverse the two parts. Then reverse them together.
    reverse(0, new_start);
    reverse(new_start, _states.length());
    reverse(0, _states.length());
    _previous_index = 0;
  }

  // [end] is exclusive.
  void reverse(int start, int end) {
    int from = start;
    int to = end - 1;  // `end` is exclusive.
    while (from < to) {
      auto tmp = _states[from];
      _states[from] = _states[to];
      _states[to] = tmp;
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
      : _source(source)
      , _scanner(scanner)
      , _diagnostics(diagnostics)
      , _scanner_state_queue(scanner)
      , _current_state(State::invalid())
      , _peek_state(State::invalid()) { }

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

  Source* _source;
  Scanner* _scanner;
  Diagnostics* _diagnostics;

  bool _encountered_stack_overflow = false;

  ScannerStateQueue _scanner_state_queue;
  // A cache of the current parser state.
  // The parser state is completely determined by the current scanner state.
  State _current_state;
  // A state we can use when returning from [peek_state]. This avoids copying
  //   the whole state all the time.
  State _peek_state;

  IndentationStack _indentation_stack;

  Scanner* scanner() { return _scanner; }
  Diagnostics* diagnostics() const { return _diagnostics; }

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
    ASSERT(!_current_state.is_valid());
    return _scanner_state_queue.scanner_look_ahead(n);
  }


  /// Returns the n'th state after the current one.
  ///
  /// If `n == 0` and the _current_state is valid, returns it.
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
    if (_current_state.is_valid() && n == 0) return _current_state;
    peek_state(n, &_peek_state);
    return _peek_state;
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
    if (!_current_state.is_valid()) {
      peek_state(0, &_current_state);
      if (_current_state.token == Token::NEWLINE) {
        consume();
        peek_state(0, &_current_state);
      }
    }
    return _current_state;
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
        current_indentation() == _indentation_stack.top_indentation()) {
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
    ASSERT(_current_state.is_valid());
    _current_state.mark_invalid();
    _scanner_state_queue.consume();
  }

  bool optional(Token::Kind kind);
  bool optional_delimiter(Token::Kind kind);

  /// Requests the scanner to continue scanning for an interpolated expression in
  /// a string.
  void scan_interpolated_part() {
    ASSERT(!_current_state.is_valid());
    _scanner_state_queue.buffer_interpolated_part();
  }
  /// Requests the scanner to continue scanning for a string after an
  /// interpolated expression.
  void scan_string_part(bool is_multiline) {
    ASSERT(!_current_state.is_valid());
    _scanner_state_queue.buffer_string_part(is_multiline);
  }
  /// Requests the scanner to continue scanning for an interpolation format in an
  /// interpolated expression.
  void scan_string_format_part() {
    ASSERT(!_current_state.is_valid());
    _scanner_state_queue.buffer_string_format_part();
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
