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

#include "../top.h"

#include <utility>

#include "list.h"
#include "sources.h"
#include "symbol.h"
#include "token.h"

namespace toit {
namespace compiler {

class ScannerStateQueue;

const int TAB_WIDTH = 8;

// Lsp Selection support:
// The LSP_SELECTION_MARKER is generally an invalid character in Toit source code.
// We use it to inform the scanner that the identifier at this position should be
// marked as LSP-selection (and should also not be interpreted as other token).
//
// The scanner uses the callback to check whether a LSP_SELECTION_MARKER character at a
// specific location acts as a marker or is just an illegal character.
// If the callback returns false, then it's illegal. Otherwise the callback should
// replace the marker with the original character and return true.
const int LSP_SELECTION_MARKER = 1;

class LspSource : public Source {
 public:
  LspSource(Source* wrapped, int offset)
      : _wrapped(wrapped)
      , _text_with_marker(null)
      , _lsp_offset(offset) {
    _text_with_marker = unvoid_cast<uint8*>(malloc(_wrapped->size() + 2));
    strncpy(char_cast(_text_with_marker),
            char_cast(_wrapped->text()),
            offset);
    _text_with_marker[offset] = LSP_SELECTION_MARKER;
    strncpy(char_cast(&_text_with_marker[offset + 1]),
            char_cast(&_wrapped->text()[offset]),
            _wrapped->size() - offset + 1);
    ASSERT(_text_with_marker[_wrapped->size() + 1] == '\0');
  }

  ~LspSource() {
    free(_text_with_marker);
  }

  bool is_lsp_marker_at(int offset) {
    return offset == _lsp_offset;
  }

  bool is_valid() { return true; }
  const char* absolute_path() const { return _wrapped->absolute_path(); }
  std::string package_id() const { return _wrapped->package_id(); }
  std::string error_path() const { return _wrapped->error_path(); }
  const uint8* text() const { return _text_with_marker; }
  Range range(int from, int to) const {
    if (from > _lsp_offset) from--;
    if (to > _lsp_offset) to--;
    return _wrapped->range(from, to);
  }
  int size() const { return _wrapped->size() + 1; }
  int offset_in_source(Position position) const {
    int wrapped_offset = _wrapped->offset_in_source(position);
    if (wrapped_offset >= _lsp_offset) return wrapped_offset + 1;
    return wrapped_offset;
  }

  void text_range_without_marker(int from, int to, const uint8** text_from, const uint8** text_to) {
    if (from > _lsp_offset) from--;
    if (to > _lsp_offset) to--;
    *text_from = &_wrapped->text()[from];
    *text_to = &_wrapped->text()[to];
  }

 private:
  Source* _wrapped;
  uint8* _text_with_marker;
  int _lsp_offset;
};

static inline bool is_newline(int c) {
  ASSERT(c >= 0);
  return c == '\r' || c == '\n';
}

static inline bool is_whitespace_not_newline(int c) {
  ASSERT(c >= 0);
  return  (c == ' ') || (c == '\t');
}

static inline bool is_letter(int c) {
  ASSERT(c >= 0);
  return (('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z'));
}

static inline bool is_decimal_digit(int c) {
  ASSERT(c >= 0);
  return ('0' <= c) && (c <= '9');
}

static inline bool is_hex_digit(int c) {
  ASSERT(c >= 0);
  return is_decimal_digit(c) ||
      (('A' <= c) && (c <= 'F')) ||
      (('a' <= c) && (c <= 'f'));
}

static inline bool is_binary_digit(int c) {
  ASSERT(c >= 0);
  return c == '0' || c == '1';
}

static inline bool is_identifier_start(int c) {
  ASSERT(c >= 0);
  return c == LSP_SELECTION_MARKER || is_letter(c) || (c == '_');
}

static inline bool is_identifier_part(int c) {
  ASSERT(c >= 0);
  return c == LSP_SELECTION_MARKER || is_letter(c) || is_decimal_digit(c) || (c == '_');
}

class Diagnostics;
class SymbolCanonicalizer;

class Scanner {
 public:
  class Comment {
   public:
    Comment(bool is_multiline,
            bool is_toit_doc,
            Source::Range range)
        : _is_multiline(is_multiline)
        , _is_toitdoc(is_toit_doc)
        , _range(range) { }

    bool is_multiline() const { return _is_multiline; }
    bool is_toitdoc() const { return _is_toitdoc; }
    Source::Range range() const { return _range; }

    bool is_valid() const { return _range.is_valid(); }

    static Comment invalid() {
      return Comment(true, false, Source::Range::invalid());
    }

   private:
    bool _is_multiline;
    bool _is_toitdoc;
    Source::Range _range;

    friend class ListBuilder<Comment>;
    Comment() : _range(Source::Range::invalid()) { }
  };


  struct State {
    int from;           // The start of the token.
    int to;             // The end of the token.
    Symbol data;        // The data associated with this token.
    int16 indentation;    // The indentation of the token.
    // Encodes the token and the boolean values `is_attached` and `is_lsp_selection`.
    int16 _token_bools;

    static int16 encode_token_bools(Token::Kind token,
                                    bool is_attached,
                                    bool is_lsp_selection) {
      return token << 2 |
          (is_attached ? IS_ATTACHED_BIT : 0) |
          (is_lsp_selection ? IS_LSP_SELECTION_BIT : 0);
    }

    static State invalid() {
      return {
        .from = 0,
        .to = 0,
        .data = Symbol::invalid(),
        .indentation = -1, // -1 means the state is invalid.
        ._token_bools = encode_token_bools(Token::DEDENT,
                                           false,
                                           false),
      };
    }

    bool is_valid() const { return indentation != -1; }

    void mark_invalid() {
      indentation = -1;
    }

    // The current token.
    Token::Kind token() const { return static_cast<Token::Kind>(_token_bools >> 2); }
    // Whether there were any non-indentation spaces in front of this token.
    bool is_attached() const { return (_token_bools & IS_ATTACHED_BIT) != 0; }
    // Whether the current identifier token is the LSP-selection. (See [LSP_SELECTION_MARKER]).
    // Only relevant, when the token is of kind Token::IDENTIFIER.
    bool is_lsp_selection() const { return (_token_bools & IS_LSP_SELECTION_BIT) != 0; }

    std::pair<int, int> range() const { return std::make_pair(from, to); }

   private:
    static constexpr int const IS_ATTACHED_BIT = 1;
    static constexpr int const IS_LSP_SELECTION_BIT = 2;
  };

  Scanner(Source* source, SymbolCanonicalizer* symbols, Diagnostics* diagnostics)
      : _input(source->text())
      , _source(source)
      , _lsp_selection_is_identifier(false)
      , _symbols(symbols)
      , _diagnostics(diagnostics) { }

  Scanner(Source* source,
          bool lsp_selection_is_identifier,
          SymbolCanonicalizer* symbols,
          Diagnostics* diagnostics)
      : _input(source->text())
      , _source(source)
      , _lsp_selection_is_identifier(lsp_selection_is_identifier)
      , _symbols(symbols)
      , _diagnostics(diagnostics) { }

  void skip_hash_bang_line();

  void advance_to(int offset) {
    _index = offset;
  }

  State next();
  // Same as `next` but splits identifiers at `$`.
  State next_interpolated_part();
  State next_string_part(bool is_multiline_string);
  State next_string_format_part();

  List<Comment> comments();

  Source* source() const { return _source; }
  SymbolCanonicalizer* symbol_canonicalizer() const { return _symbols; }

  static bool is_identifier_start(int c);

  Source::Range current_range() const {
    if (_index == _source->size()) {
      return _source->range(_index - 1, _index);
    } else {
      return _source->range(_index, _index + 1);
    }
  }

 private:
  int peek() { return look_ahead(0); }
  int look_ahead(int n = 1) {
    ASSERT(_index + n >= 0 && _index + n <= _source->size());
    return _input[_index + n];
  }
  bool at_eos() const { return _index >= _source->size(); }
  bool at_skippable_whitespace(int peek) {
    return is_whitespace_not_newline(peek) || at_escaped_newline(peek);
  }
  bool at_escaped_newline() { return at_escaped_newline(peek()); }
  bool at_escaped_newline(int peek) {
    return peek == '\\' && (look_ahead() == '\n' || look_ahead() == '\r');
  }

  friend class ScannerStateQueue;

 private:
  Symbol _data = Symbol::invalid();
  bool _is_lsp_selection = false;

  const uint8* _input;
  Source* _source;

  // Whether LSP-selections should be treated as identifier tokens.
  // For completions we assume that keywords are just "incomplete" identifiers, whereas
  // for goto-definitions we want to handle keywords as keywords.
  // For example: `if for@` should still propose a completion and treat the `for` as an identifier
  //  (potentially completing to "former").
  bool _lsp_selection_is_identifier;

  SymbolCanonicalizer* _symbols;
  Diagnostics* _diagnostics;

  int _indentation = 0;

  int _index = 0;

  int _begin = -1;
  int _last = -1;

  ListBuilder<Comment> _comments;

  int advance() {
    // Never advance past the EOS.
    if (_index < _source->size()) _index++;
    int result = _input[_index];
    // Advance over the '\n' as well.
    if (result == '\n' && _input[_index - 1] == '\r' && _index < _source->size()) {
      _index++;
      result = _input[_index];
    }
    ASSERT(result >= 0);
    return result;
  }

  Symbol preserve_syntax(int begin, int end);

  State create_state(Token::Kind token);
  Token::Kind next_token();

  Token::Kind scan_single(Token::Kind kind) { ++_index; return kind; }

  Token::Kind scan_newline(int peek);
  Token::Kind scan_character(int peek);
  Token::Kind scan_string(int peek);
  Token::Kind scan_number(int peek);
  Token::Kind scan_identifier(int peek);
  Token::Kind scan_illegal(int peek);

  void capture_single_line_comment(int peek);
  void capture_multi_line_comment(int peek);

  void skip_skippable_whitespace(int peek);

  // Error reporting helpers.
  void report_error(int from, int to, const char* format, ...);
};

} // namespace toit::compiler
} // namespace toit
