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

#include <stdarg.h>

#include "scanner.h"

#include "diagnostic.h"
#include "symbol_canonicalizer.h"

namespace toit {
namespace compiler {

bool Scanner::is_identifier_start(int c) {
  return ::toit::compiler::is_identifier_start(c);
}

void Scanner::skip_hash_bang_line() {
  if (_input[0] == '#' && _input[1] == '!') {
    for (int i = 2; true; i++) {
      if (is_newline(_input[i]) || _input[i] == '\0') {
        _index += i;
        break;
      }
    }
  }
}

Symbol Scanner::preserve_syntax(int begin, int end) {
  return Symbol::synthetic(_input + begin, _input + end);
}

Scanner::State Scanner::create_state(Token::Kind token) {
  bool is_attached = (_last - _begin) == 0;
  return {
    .from = _last,
    .to = _index,
    .data = _data,
    .indentation = static_cast<int16>(_indentation),
    ._token_bools = Scanner::State::encode_token_bools(token,
                                                       is_attached,
                                                       _is_lsp_selection),
  };
}

Scanner::State Scanner::next() {
  return create_state(next_token());
}

List<Scanner::Comment> Scanner::comments() {
  return _comments.build();
}

Token::Kind Scanner::next_token() {
  _begin = _index;
  do {
    if (at_eos()) {
      _indentation = 0;
      return Token::EOS;
    }

    int peek = _input[_last = _index];


    switch (peek) {
      case 0:
        return scan_illegal(peek);

      case 1:
        static_assert(LSP_SELECTION_MARKER == 1,
                      "Unexpected LSP selection marker");
        // Assume it's a marker for the target-callback.
        return scan_identifier(peek);

      case 2:
      case 3:
      case 4:
      case 5:
      case 6:
      case 7:
      case 8:
        return scan_illegal(peek);

      case '\t':  // 9
        skip_skippable_whitespace(peek);
        continue;

      case 10:
        return scan_newline(peek);

      case 11:
      case 12:
        return scan_illegal(peek);

      case 13:
        return scan_newline(peek);

      case 14:
      case 15:
      case 16:
      case 17:
      case 18:
      case 19:
      case 20:
      case 21:
      case 22:
      case 23:
      case 24:
      case 25:
      case 26:
      case 27:
      case 28:
      case 29:
      case 30:
      case 31:
        return scan_illegal(peek);

      case ' ':  // 32
        skip_skippable_whitespace(peek);
        continue;

      case '!':  // 33
        peek = advance();
        if (peek == '=') return scan_single(Token::NE);
        report_error(_index - 1, _index, "'!' has been deprecated for 'not'");
        return Token::NOT;

      case '"':  // 34
        return scan_string(peek);

      case '#':  // 35
        if (look_ahead(1) == 'p' &&
            look_ahead(2) == 'r' &&
            look_ahead(3) == 'i' &&
            look_ahead(4) == 'm' &&
            look_ahead(5) == 'i' &&
            look_ahead(6) == 't' &&
            look_ahead(7) == 'i' &&
            look_ahead(8) == 'v' &&
            look_ahead(9) == 'e' &&
            !is_identifier_part(look_ahead(10))) {
          // We use `advance` (instead of just updating the _index field), so we
          // get the checks from that function.
          advance(); // #
          advance(); // p
          advance(); // r
          advance(); // i
          advance(); // m
          advance(); // i
          advance(); // t
          advance(); // i
          advance(); // v
          advance(); // e
          return Token::PRIMITIVE;
        } else if (look_ahead(1) == '[') {
          advance();
          advance();
          return Token::LSHARP_BRACK;
        }
        return scan_illegal(peek);

      case '$':  // 36
        return scan_illegal(peek);

      case '%':  // 37
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_MOD);
        return Token::MOD;

      case '&':  // 38
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_BIT_AND);
        if (peek == '&') {
          report_error(_index - 1, _index + 1, "'&&' has been deprecated for 'and'");
          return scan_single(Token::LOGICAL_AND);
        }
        return Token::BIT_AND;

      case '\'':  // 39
        return scan_character(peek);

      case '(':  // 40
        return scan_single(Token::LPAREN);

      case ')':  // 41
        return scan_single(Token::RPAREN);

      case '*':
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_MUL);
        return Token::MUL;

      case '+':
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_ADD);
        if (peek == '+') return scan_single(Token::INCREMENT);
        return Token::ADD;

      case ',':  // 44
        return scan_single(Token::COMMA);

      case '-':  // 45
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_SUB);
        if (peek == '-') return scan_single(Token::DECREMENT);
        if (peek == '>') return scan_single(Token::RARROW);
        return Token::SUB;

      case '.':  // 46
        if (is_decimal_digit(look_ahead())) return scan_number(peek);
        peek = advance();
        if (peek == '.') return scan_single(Token::SLICE);
        return Token::PERIOD;

      case '/':  // 47
        peek = advance();
        if (peek == '/') {
          capture_single_line_comment(peek);
          continue;
        }
        if (peek == '*') {
          capture_multi_line_comment(peek);
          continue;
        }
        if (peek == '=') return scan_single(Token::ASSIGN_DIV);
        return Token::DIV;

      case '0':  // 48
      case '1':
      case '2':
      case '3':
      case '4':
      case '5':
      case '6':
      case '7':
      case '8':
      case '9':  // 57
        return scan_number(peek);

      case ':':  // 58
        peek = advance();
        if (peek == '=') return scan_single(Token::DEFINE);
        if (peek == ':' && look_ahead() == '=') {
          advance();
          return scan_single(Token::DEFINE_FINAL);
        }
        if (peek == ':') {
          return scan_single(Token::DOUBLE_COLON);
        }
        return Token::COLON;

      case ';':  // 59
        return scan_single(Token::SEMICOLON);

      case '<':  // 60
        peek = advance();
        if (peek == '=') return scan_single(Token::LTE);
        if (peek == '<') {
          peek = advance();
          if (peek == '=') return scan_single(Token::ASSIGN_BIT_SHL);
          return Token::BIT_SHL;
        }
        return Token::LT;

      case '=':  // 61
        peek = advance();
        if (peek == '=') return scan_single(Token::EQ);
        return Token::ASSIGN;

      case '>':  // 62
        peek = advance();
        if (peek == '=') return scan_single(Token::GTE);
        if (peek == '>') {
          peek = advance();
          if (peek == '=') return scan_single(Token::ASSIGN_BIT_SHR);
          if (peek == '>') {
            peek = advance();
            if (peek == '=') return scan_single(Token::ASSIGN_BIT_USHR);
            return Token::BIT_USHR;
          }
          return Token::BIT_SHR;
        }
        return Token::GT;

      case '?':  // 63
        return scan_single(Token::CONDITIONAL);

      case '@':  // 64
        return scan_illegal(peek);

      case 'A':  // 65
      case 'B':
      case 'C':
      case 'D':
      case 'E':
      case 'F':
      case 'G':
      case 'H':
      case 'I':
      case 'J':
      case 'K':
      case 'L':
      case 'M':
      case 'N':
      case 'O':
      case 'P':
      case 'Q':
      case 'R':
      case 'S':
      case 'T':
      case 'U':
      case 'V':
      case 'W':
      case 'X':
      case 'Y':
      case 'Z':  // 90
        return scan_identifier(peek);

      case '[':  // 91
        return scan_single(Token::LBRACK);

      case '\\':  // 92
        if (at_escaped_newline(peek)) {
          skip_skippable_whitespace(peek);
          continue;
        }
        return scan_single(Token::ILLEGAL);

      case ']':  // 93
        return scan_single(Token::RBRACK);

      case '^':  // 94
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_BIT_XOR);
        return Token::BIT_XOR;

      case '_':  // 95
        return scan_identifier(peek);

      case '`':  // 96
        return scan_illegal(peek);

      case 'i':  // 105
        if (look_ahead() == 's' && !is_identifier_part(look_ahead(2))) {
          advance();
          peek = advance();
          if (peek == '!') {
            report_error(_index - 1, _index + 1, "'is!' has been deprecated for 'is not'");
            advance();
            return Token::IS_NOT;
          }
          return Token::IS;
        }
        [[fallthrough]];

      case 'a':  // 97
      case 'b':
      case 'c':
      case 'd':
      case 'e':
      case 'f':
      case 'g':
      case 'h':
      case 'j':
      case 'k':
      case 'l':
      case 'm':
      case 'n':
      case 'o':
      case 'p':
      case 'q':
      case 'r':
      case 's':
      case 't':
      case 'u':
      case 'v':
      case 'w':
      case 'x':
      case 'y':
      case 'z':  // 122
        return scan_identifier(peek);

      case '{': // 123
        return scan_single(Token::LBRACE);

      case '|':  // 124
        peek = advance();
        if (peek == '=') return scan_single(Token::ASSIGN_BIT_OR);
        if (peek == '|') {
          report_error(_index - 1, _index + 1, "'||' has been deprecated for 'or'");
          return scan_single(Token::LOGICAL_OR);
        }
        return Token::BIT_OR;

      case '}':  // 125
        return scan_single(Token::RBRACE);

      case '~':  // 126
        return scan_single(Token::BIT_NOT);

      case 127:
        return scan_illegal(peek);
    }

    return scan_single(Token::ILLEGAL);
  } while (true);

  UNREACHABLE();
  return Token::ILLEGAL;
}

Scanner::State Scanner::next_interpolated_part() {
  _begin = _index;
  int peek = _input[_index];
  if (at_skippable_whitespace(peek)) {
    skip_skippable_whitespace(peek);
  }
  _last = _index;
  peek = _input[_index];
  if (is_identifier_start(peek)) {
    return create_state(scan_identifier(peek));  // Don't allow $.
  } else {
    _index = _begin;
    return next();
  }
}

// Finds a string-format string.
// The scanner does basic checks:
//    [-^]?[0-9.]*\alpha\whitespace
// This is not always a valid format, but should catch some bad errors and then
// make it easier to report errors at the right place.
Scanner::State Scanner::next_string_format_part() {
  _begin = _last = _index;
  int begin = _index;
  if (_input[_index] == '-' || _input[_index] == '^') _index++;
  for (int peek = _input[_index]; true; peek = advance()) {
    if (is_decimal_digit(peek)) continue;
    if (peek == '.') continue;
    if (is_letter(peek)) {
      peek = advance();
      if (at_skippable_whitespace(peek) || at_eos()) {
        _data = preserve_syntax(begin, _index);
        return create_state(Token::STRING);
      }
    }
    report_error(_begin, _index, "Invalid format string");
    advance();
    _data = Symbols::empty_string;
    return create_state(Token::STRING);
  }
}

Scanner::State Scanner::next_string_part(bool is_multiline_string) {
  _begin = _last = _index;
  int begin = _index;
  for (int peek = _input[_index]; true; peek = advance()) {
    if (peek == '"') {
      int index = _index;
      if (is_multiline_string) {
        if (look_ahead() != '"') continue;
        advance();
        if (look_ahead() != '"') continue;
        advance();
        // Allow up to 5 double quotes, for triple quoted strings that end with
        // two double quotes.
        while (_index - index < 4 && look_ahead() == '"') {
          advance();
        }
        index = _index - 2;
        _data = preserve_syntax(begin, index);
        advance();
        return create_state(Token::STRING_END_MULTI_LINE);
      }
      _data = preserve_syntax(begin, index);
      advance();
      return create_state(Token::STRING_END);
    } else if (peek == '\\') {
      advance();
    } else if (peek == '$') {
      _data = preserve_syntax(begin, _index);
      advance();
      auto token = is_multiline_string
          ? Token::STRING_PART_MULTI_LINE
          : Token::STRING_PART;
      return create_state(token);
    } else if (at_eos() || (!is_multiline_string && is_newline(peek))) {
      report_error(begin, _index, "%s", "Unterminated string");
      _data = Symbols::empty_string;
      if (is_multiline_string) {
        return create_state(Token::STRING_END_MULTI_LINE);
      } else {
        return create_state(Token::STRING_END);
      }
    }
  }
}

Token::Kind Scanner::scan_newline(int peek) {
  int indentation;

  do {
    ASSERT(peek == '\n' || peek == '\r');
    if (peek == '\r') {
      peek = advance();
      if (peek == '\r') peek = advance();
    } else {
      peek = advance();
    }

    // Compute indentation level of next line.
    indentation = 0;
    while (peek == ' ' || peek == '\t' || (peek == '/' && look_ahead() == '*')) {
      if (peek == ' ') {
        indentation++;
        peek = advance();
      } else if (peek == '\t') {
        report_error(_index, _index + 1, "Can't have tabs in leading whitespace");
        // Tabs indentation to the next TAB_WIDTH character column.
        indentation += TAB_WIDTH;
        indentation -= indentation % TAB_WIDTH;
        peek = advance();
      } else {
        ASSERT(peek == '/' && look_ahead() == '*');
        peek = advance();
        capture_multi_line_comment(peek);
        peek = _input[_index];
      }
    }

    if (peek == '/' && look_ahead() == '/') {
      advance();
      capture_single_line_comment(peek);
      peek = _input[_index];
    }

    // Continue as long as we're moving through whitespace
    // only lines.
  } while (peek == '\n' || peek == '\r');
  // Ignore all whitespace, if it's at the end of the file.
  _indentation = at_eos() ? 0 : indentation;
  return Token::NEWLINE;
}

Token::Kind Scanner::scan_character(int peek) {
  // Used for both character literal and format in interpolated strings.
  ASSERT(peek == '\'');
  int begin = _index + 1;
  while (true) {
    peek = advance();
    if (peek == '\'') {
      _data = preserve_syntax(begin, _index);
      advance();
      return Token::CHARACTER;
    } else if (peek == '\\') {
      advance();
    } else if (at_eos() || is_newline(peek)) {
      report_error(begin - 1, _index, "%s", "Unterminated character");
      _data = Symbols::one;  // Any character works, but we already have a "1".
      return Token::CHARACTER;
    }
  }
}

Token::Kind Scanner::scan_string(int peek) {
  bool is_multiline_string = false;
  ASSERT(peek == '"');

  int error_pos = _index;
  int begin = _index + 1;

  // Check whether we have a multiline string.
  if (look_ahead() == '"') {
    advance();
    if (look_ahead() == '"') {
      advance();
      begin += 2;
      is_multiline_string = true;
    } else {
      // Just the empty string.
      _data = preserve_syntax(begin, _index);
      advance();
      return Token::STRING;
    }
  }

  while (true) {
    peek = advance();
    if (peek == '"') {
      int index = _index;
      if (is_multiline_string) {
        if (look_ahead() != '"') continue;
        advance();
        if (look_ahead() != '"') continue;
        advance();
        // Allow up to 5 double quotes, for triple quoted strings that end with
        // two double quotes.
        while (_index - index < 4 && look_ahead() == '"') {
          advance();
        }
        index = _index - 2;
        _data = preserve_syntax(begin, index);
        advance();
        return Token::STRING_MULTI_LINE;
      }
      _data = preserve_syntax(begin, index);
      advance();
      return Token::STRING;
    } else if (peek == '\\') {
      advance();
    } else if (peek == '$') {
      _data = preserve_syntax(begin, _index);
      advance();
      return is_multiline_string ? Token::STRING_PART_MULTI_LINE : Token::STRING_PART;
    } else if (at_eos() || (!is_multiline_string && is_newline(peek))) {
      report_error(error_pos, _index, "%s", "Unterminated string");
      _data = preserve_syntax(begin, _index);
      if (is_multiline_string) {
        return Token::STRING_MULTI_LINE;
      } else {
        return Token::STRING;
      }
    }
  }
}

Token::Kind Scanner::scan_number(int peek) {
  Token::Kind result = Token::INTEGER;
  const char* error_message = null;

  int begin = _index;
  ASSERT(is_decimal_digit(peek) || peek == '.');

  int base = 10;
  auto is_valid_digit = &is_decimal_digit;

  if (peek == '0' && (look_ahead() == 'x' || look_ahead() == 'X')) {
    advance();
    peek = advance();
    base = 16;
    is_valid_digit = &is_hex_digit;
  } else if (peek == '0' && (look_ahead() == 'b' || look_ahead() == 'B')) {
    advance();
    peek = advance();
    base = 2;
    is_valid_digit = &is_binary_digit;
  }

  bool has_digits = false;

  while (is_valid_digit(peek)) {
    peek = advance();
    has_digits = true;
    if (peek == '_' && is_valid_digit(look_ahead())) {
      peek = advance();
    }
  }

  // We support decimal and hexadecimal floating point literals:
  //  - 1.5e-17
  //  - 0x7107.abcP+3
  if (base >= 10 && (peek == '.') && is_valid_digit(look_ahead())) {
    peek = advance();  // The '.'
    do {
      peek = advance();
      has_digits = true;
      if (peek == '_' && is_valid_digit(look_ahead())) {
        peek = advance();
      }
    } while (is_valid_digit(peek));
    result = Token::DOUBLE;
  }

  if (!has_digits) {
    error_message = "Invalid number literal";
    goto fail;
  }

  if ((base == 10 && (peek == 'e' || peek == 'E'))||
      (base == 16 && (peek == 'p' || peek == 'P'))) {
    peek = advance();
    if (peek == '+' || peek == '-') {
      peek = advance();
    }
    if (!is_decimal_digit(peek)) {
      error_message = "Invalid floating-point literal";
      goto fail;
    }
    while (is_decimal_digit(peek)) {
      peek = advance();
      if (peek == '_' && is_decimal_digit(look_ahead())) {
        peek = advance();
      }
    }
    result = Token::DOUBLE;
  } else if (base == 16 && result == Token::DOUBLE) {
    error_message = "Hexadecimal floating point numbers must have an exponent";
    goto fail;
  }
  if (peek == '_') {
    error_message = "Invalid number literal";
    goto fail;
  }

  goto done;

  fail:
  ASSERT(error_message != null);
  // Eat all digits that could have been part of the literal.
  while (peek == '_' || is_hex_digit(peek) ||
         (peek == '.' && is_hex_digit(look_ahead()))) {
    peek = advance();
  }
  report_error(begin, _index, error_message);

  done:
  _data = _symbols->canonicalize_number(_input + begin, _input + _index);
  return result;
}

Token::Kind Scanner::scan_identifier(int peek) {
  int begin = _index;
  ASSERT(is_identifier_start(peek));

  _is_lsp_selection = false;
  do {
    if (peek == LSP_SELECTION_MARKER) {
      // If we are hitting an LSP-selection marker at a location where it
      // shouldn't be, consider it a non-identifier character.
      //
      // If the bad character wasn't the first character of the identifier, we
      // don't immediately report an error, but return the scanned identifier first.
      // Then the main-loop will try again to read an identifier, at which point we
      // report the error.
      // This `_lsp_selection_callback(_index)` might thus be invoked twice, if
      // it's at a bad location.
      if (!_source->is_lsp_marker_at(_index)) break;
      // If we hit a selection-marker just continue the loop, as if the marker
      // had never been there.
      _is_lsp_selection = true;
    }
    peek = advance();
  } while (is_identifier_part(peek));

  if (!_is_lsp_selection && begin == _index) {
    ASSERT(peek == LSP_SELECTION_MARKER);
    // We were hoping for an lsp selection, but just discovered an illegal character.
    return scan_illegal(peek);
  }

  // If this is the lsp selection, create a copy of the source without the marker.
  uint8* lsp_buffer = null;
  const uint8* from;
  const uint8* to;
  source()->text_range_without_marker(begin, _index, &from, &to);
  // Note that the symbol could be of length 0, if it was the lsp selection.
  auto token_symbol = _symbols->canonicalize_identifier(from, to);
  if (lsp_buffer != null) free(lsp_buffer);
  _data = token_symbol.symbol;
  if (_is_lsp_selection && _lsp_selection_is_identifier) {
    // Target wins over the stored kind. This means that keywords are also identified
    // as LSP-selections. (Which is what we want, since a completion on `for` should work).
    if (token_symbol.kind != Token::IDENTIFIER) {
      _data = Token::symbol(token_symbol.kind);
    }
    return Token::IDENTIFIER;
  }
  return token_symbol.kind;
}

Token::Kind Scanner::scan_illegal(int peek) {
  return scan_single(Token::ILLEGAL);
}

// Skips over whitespace, but keeps *unescaped newlines*.
void Scanner::skip_skippable_whitespace(int peek) {
  ASSERT(at_skippable_whitespace(peek));
  do {
    if (peek == '\\') {
      ASSERT(at_escaped_newline(peek));
      peek = advance();
      if (peek == '\r') peek = advance();
      if (peek == '\n') peek = advance();
    } else {
      peek = advance();
    }
  } while (at_skippable_whitespace(peek));
}

void Scanner::capture_single_line_comment(int peek) {
  ASSERT(peek == '/');  // At the second '/'.
  peek = advance();
  // The comment should include the '//'.
  int begin = _index - 2;

  bool is_toitdoc = peek == '/';

  while (!at_eos() && !is_newline(peek)) {
    peek = advance();
  }

  _comments.add(Comment(false, is_toitdoc, _source->range(begin, _index)));
}

void Scanner::capture_multi_line_comment(int peek) {
  ASSERT(peek == '*');
  peek = advance();
  // The comment should include the '/*'.
  int begin = _index - 2;

  bool is_toitdoc = peek == '*' && look_ahead(1) != '/';

  int nesting_count = 1;
  while (!at_eos()) {
    if (peek == '*') {
      peek = advance();
      if (peek == '/') {
        peek = advance();
        nesting_count--;
        if (nesting_count == 0) break;
      }
    } else if (peek == '/') {
      peek = advance();
      if (peek == '*') {
        peek = advance();
        nesting_count++;
      }
    } else if (peek == '\\') {
      peek = advance();
      if (!at_eos()) {
        peek = advance();
      }
    } else {
      // Just skip to the next one.
      peek = advance();
    }
  }

  if (nesting_count != 0) {
    report_error(begin, _index, "%s", "Unterminated multi-line comment");
  }

  _comments.add(Comment(true, is_toitdoc, _source->range(begin, _index)));
}

void Scanner::report_error(int from, int to, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  _diagnostics->report_error(_source->range(from, to), format, arguments);
  va_end(arguments);
}

} // namespace toit::compiler
} // namespace toit
