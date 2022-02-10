// Copyright (C) 2019 Toitware ApS.
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

#include <string>

#include "scanner.h"
#include "parser.h"
#include "toitdoc_parser.h"

namespace toit {
namespace compiler {

namespace {  // anonymous

/// Wraps an existing diagnostics and modifies all errors to be warnings instead.
class ToitdocDiagnostics : public Diagnostics {
 public:
  explicit ToitdocDiagnostics(Diagnostics* wrapped)
      : Diagnostics(wrapped->source_manager()), _wrapped(wrapped) { }

  bool should_report_missing_main() const { return _wrapped->should_report_missing_main(); }

 protected:
  Severity adjust_severity(Severity severity) {
    if (severity == Severity::error) return Severity::warning;
    return severity;
  }
  void emit(Severity severity, const char* format, va_list& arguments) {
    _wrapped->emit(severity, format, arguments);
  }
  void emit(Severity severity, Source::Range range, const char* format, va_list& arguments) {
    _wrapped->emit(severity, range, format, arguments);
  }

 private:
  Diagnostics* _wrapped;
};

static uint8* memdup(const std::string& text) {
  auto result = unvoid_cast<uint8*>(malloc(text.size() + 1));
  memcpy(result, text.c_str(), text.size() + 1);
  ASSERT(result[text.size()] == '\0');
  return result;
}

/// All the toitdoc text, with a mapping to the underlying source.
class ToitdocSource : public Source {
 public:
  ToitdocSource(Source* source,
                const std::string& text,
                const std::vector<int>& source_line_offsets,
                const std::vector<int>& toitdoc_line_offsets)
      : _source(source)
      // We can't use `strdup` as the text might contain '\0' characters.
      , _text(memdup(text))
      , _size(static_cast<int>(text.size()))
      , _source_line_offsets(source_line_offsets)
      , _toitdoc_line_offsets(toitdoc_line_offsets) { }

  ~ToitdocSource() {
    free(_text);
  }

  const char* absolute_path() const { return _source->absolute_path(); }
  std::string package_id() const { return _source->package_id(); }
  std::string error_path() const { return _source->error_path(); }

  const uint8* text() const { return _text; }

  Range range(int from, int to) const {
    return _source->range(source_offset_at(from), source_offset_at(to));
  }

  int size() const { return _size; }

  // This functionality isn't supported.
  int offset_in_source(Position position) const { UNREACHABLE();  }

  bool is_lsp_marker_at(int offset);

  // The offset must not be on the last line.
  // This is easily guaranteed by making sure that the toitdoc text is
  // terminated with an empty line.
  int source_offset_at(int offset) const;

  void text_range_without_marker(int from, int to, const uint8** text_from, const uint8** text_to) {
    _source->text_range_without_marker(source_offset_at(from),
                                       source_offset_at(to),
                                       text_from,
                                       text_to);
  }

 private:
  Source* _source;
  uint8* _text;
  int _size;
  std::vector<int> _source_line_offsets;
  std::vector<int> _toitdoc_line_offsets;
};

/// Collects the toitdoc text, while maintaining a mapping to the underlying source.
class ToitdocTextBuilder {
 public:
  explicit ToitdocTextBuilder(Source* source, int source_from, int source_to)
      : _source(source)
      , _source_from(source_from)
      , _source_to(source_to) { }

  /// Adds the substring source[source_from...source_to] to the text.
  /// [source_from] is inclusive.
  /// [source_to] is exclusive.
  ///
  /// The range must not include the newline character.
  /// [source_from] is used in the source mapping as the start of the line.
  void add_line(const uint8* source, int source_from, int source_to) {
    add_line(std::string(char_cast(&source[source_from]), source_to - source_from), source_from);
  }

  /// Adds the given str to the text.
  /// The string must not include the newline character.
  /// [source_at] is used as position in the source mapping.
  void add_line(std::string str, int source_at) {
    ASSERT(_source_from <= source_at && source_at <= _source_to);
    // The `source_at` position can only be equal to source_to, if the
    // line is empty.
    ASSERT(source_at != _source_to || str == "");
    ASSERT(str.empty() || str[str.size() - 1] != '\n');
    _source_line_offsets.push_back(source_at);
    _toitdoc_line_offsets.push_back(_text.size());
    _text += str;
    _text += "\n";
  }

  ToitdocSource* build() {
    // Always ensure that we have an entry in the offsets.
    if (_source_line_offsets.empty()) {
      add_line("", _source_from);
    }
    // Drop the last '\n' from the buffer, as it might not exist in
    // the actual source.
    _text.pop_back();
    if (!_text.empty() && _text[_text.size() - 1] == '\r') {
      // On Windows also drop the '\r', so we don't end up in the middle of a \r\n.
      _text.pop_back();
    }
    return _new ToitdocSource(_source, _text, _source_line_offsets, _toitdoc_line_offsets);
  }

 private:
  Source* _source;
  int _source_from;
  int _source_to;
  std::string _text;
  std::vector<int> _source_line_offsets;
  std::vector<int> _toitdoc_line_offsets;
};

/// Parses a given toitdoc, searching for code segments, references, ...
class ToitdocParser {
 public:
  ToitdocParser(ToitdocSource* toitdoc_source,
                SymbolCanonicalizer* symbols,
                Diagnostics* diagnostics)
      : _toitdoc_source(toitdoc_source)
      , _symbols(symbols)
      , _diagnostics(diagnostics) { }

  Toitdoc<ast::Node*> parse();

 private:
  ToitdocSource* _toitdoc_source;
  SymbolCanonicalizer* _symbols;
  Diagnostics* _diagnostics;

  std::vector<ast::Node*> _reference_asts;


  toitdoc::Section* parse_section();
  toitdoc::Statement* parse_statement();
  toitdoc::CodeSection* parse_code_section();
  toitdoc::Itemized* parse_itemized();
  toitdoc::Item* parse_item(int indentation);
  // May return null, if there were only comments.
  toitdoc::Paragraph* parse_paragraph(int indentation_override = -1);
  toitdoc::Code* parse_code();
  toitdoc::Text* parse_string();
  Symbol parse_delimited(int delimiter,
                         bool keep_delimiters_and_escapes,
                         const char* error_message);
  toitdoc::Ref* parse_ref();
  void skip_comment(bool should_report_error = true);

 private:  // Scanning related.
  enum Construct {
    CONTENTS,
    SECTION_TITLE,
    ITEMIZED,
    ITEM_START,
    ITEM,
    PARAGRAPH,
    CODE_SECTION,
    COMMENT,
  };

  class ConstructScope {
   public:
    ConstructScope(ToitdocParser* parser, Construct construct)
        : ConstructScope(parser, construct, parser->_line_indentation) {}

    ConstructScope(ToitdocParser* parser, Construct construct, int indentation)
        : _parser(parser), _construct(construct) {
      parser->push_construct(construct, indentation);
    }

    ~ConstructScope() {
      _parser->pop_construct(_construct);
    }

   private:
    ToitdocParser* _parser;
    Construct _construct;
  };

  std::vector<int> _indentation_stack;
  std::vector<Construct> _construct_stack;

  int _index = 0;
  int _line_indentation = 0;
  bool _is_at_dedent = false;
  /// The next index after a newline.
  /// This variable is set when encountering a '\n'.
  /// We use this to avoid computing the indentation after a newline token
  ///   multiple times.
  /// If this variable is not -1, we can directly jump to this index when advancing.
  int _next_index = -1;
  int _next_indentation = -1;

  void push_construct(Construct construct, int indentation);
  void pop_construct(Construct construct);

  Symbol make_symbol(int from, int to) { return Symbol::synthetic(make_string(from, to)); }
  std::string make_string(int from, int to);

  bool matches(const char* str);
  int peek();
  int look_ahead(int n = 1);
  void advance(int n = 1);
  void advance(const char* str) {
    ASSERT(matches(str));
    advance(strlen(str));
  }

  // Skips over whitespace.
  // Assumes that any spaces that are seen in the beginning are part of the
  // line indentation.
  void skip_initial_whitespace();
  // Skips over whitespace.
  // Uses `peek` which updates the line indentation after every '\n';
  void skip_whitespace();

  // Toitdoc errors are only reported as warnings.
  void report_error(int from, int to, const char* message);
  // Toitdoc errors are only reported as warnings.
  void report_error(Source::Range range, const char* message);
};


/// Manages all existing comments, making it easier to find
///   toitdocs, and associating them with their respective AST nodes.
class CommentsManager {
 public:
  CommentsManager(List<Scanner::Comment> comments,
                  Source* source,
                  SymbolCanonicalizer* symbols,
                  Diagnostics* diagnostics)
      : _comments(comments)
      , _source(source)
      , _symbols(symbols)
      , _diagnostics(diagnostics) {
    ASSERT(is_sorted(comments));
  }

  int find_closest_before(ast::Node* node);
  Toitdoc<ast::Node*> find_for(ast::Node* node);
  bool is_attached(int index1, int index2) {
    return is_attached(_comments[index1].range(), _comments[index2].range(), false);
  }
  bool is_attached(Source::Range previous,
                   Source::Range next,
                   bool allow_modifiers);
  Toitdoc<ast::Node*> make_ast_toitdoc(int index);

 private:
  List<Scanner::Comment> _comments;
  Source* _source;
  SymbolCanonicalizer* _symbols;
  Diagnostics* _diagnostics;

  int _last_index = 0;

  static bool is_sorted(List<Scanner::Comment> comments) {
    for (int i = 1; i < comments.length(); i++) {
      if (!comments[i - 1].range().from().is_before(comments[i].range().from())) {
        return false;
      }
    }
    return true;
  }
};

int ToitdocSource::source_offset_at(int offset) const  {
  ASSERT(!_source_line_offsets.empty());

  if (offset >= _toitdoc_line_offsets.back()) {
    int offset_in_line = offset - _toitdoc_line_offsets.back();
    return _source_line_offsets.back() + offset_in_line;
  }
  // Binary search to find the offset in the toitdoc line offset.
  int start = 0;
  int end = _toitdoc_line_offsets.size() - 1;
  while (true) {
    int mid = start + (end - start) / 2;
    if (_toitdoc_line_offsets[mid] <= offset &&
        offset < _toitdoc_line_offsets[mid + 1]) {
      int offset_in_line = offset - _toitdoc_line_offsets[mid];
      return _source_line_offsets[mid] + offset_in_line;
    }
    if (_toitdoc_line_offsets[mid] > offset) {
      end = mid;
    } else {
      start = mid + 1;
    }
  }
}

bool ToitdocSource::is_lsp_marker_at(int offset) {
  int source_offset = source_offset_at(offset);
  return _source->is_lsp_marker_at(source_offset);
}

static ToitdocSource* extract_multiline_comment_text(Source* source, int from, int to) {
  auto text = source->text();
  ASSERT(text[from] == '/' && text[from + 1] == '*' && text[from + 2] == '*');

  int indentation = 0;
  for (int i = from; i > 0 && text[i - 1] == ' '; i--) {
    indentation++;
  }
  // Trim leading '/**' and trailing '*/'
  from += 3;
  // If the comment is well-formed, we have a trailing `*/`. However, we don't
  // abort compilation if the trailing `*/` is missing.
  if (text[to - 2] == '*' && text[to - 1] == '/') {
    to -= 2;
  }
  ToitdocTextBuilder builder(source, from, to);
  bool is_first_line = true;
  int line_start = from;
  bool at_beginning_of_line = false; // No need to set it for the first line.
  for (int i = from; i < to; i++) {
    if (at_beginning_of_line) {
      at_beginning_of_line = false;
      for (int j = 0; j < indentation; j++) {
        // Skip indentation, unless it contains non-spaces.
        if (text[i] == ' ') {
          line_start++;
          i++;
        } else {
          break;
        }
      }
    }
    if (text[i] == '\n') {
      // Ignore the first enter if it was just after the '/**'.
      if (!is_first_line || i != line_start) {
        builder.add_line(text, line_start, i);
      }
      line_start = i + 1;
      at_beginning_of_line = true;
      is_first_line = false;
    }
  }
  if (is_first_line) {
    // Usually something like: /** foo */.
    // Just trim the whitespace.
    while (line_start < to && text[line_start] == ' ') line_start++;
    while (to > line_start && text[to - 1] == ' ') to--;
    builder.add_line(text, line_start, to);
  } else if (line_start != to) {
    // The last line still contains content.
    builder.add_line(text, line_start, to);
  }

  return builder.build();
}

static ToitdocSource* extract_singleline_comment_text(Source* source, int from, int to) {
  auto text = source->text();
  // Simply remove any leading "/// " or "///".
  bool at_beginning_of_line = true;
  int line_start = -1;

  ToitdocTextBuilder builder(source, from, to);
  // Singleline comments don't finish with '\n'. We increment `i` until it
  // is equal to `to` and just do as if that would be a newline.
  for (int i = from; i <= to; i++) {
    if (at_beginning_of_line) {
      // Skip over whitespace.
      // We know that there must be a '/' at some point.
      while (text[i] == ' ') i++;
      ASSERT(text[i] == '/' && text[i + 1] == '/' && text [i + 2] == '/');
      i += 3;
      if (text[i] == ' ') i++;
      line_start = i;
      at_beginning_of_line = false;
    }
    if (i == to || text[i] == '\n') {
      builder.add_line(text, line_start, i);
      at_beginning_of_line = true;
    }
  }
  ASSERT(at_beginning_of_line);
  return builder.build();
}

Toitdoc<ast::Node*> ToitdocParser::parse() {
  ConstructScope scope(this, CONTENTS, -1);
  ListBuilder<toitdoc::Section*> sections;
  skip_initial_whitespace(); // Skips the whitespace and updates the indentation.
  while (peek() != '\0') {
    sections.add(parse_section());
  }
  auto contents = _new toitdoc::Contents(sections.build());
  return Toitdoc<ast::Node*>(contents,
                             ListBuilder<ast::Node*>::build_from_vector(_reference_asts),
                             _toitdoc_source->range(0, _toitdoc_source->size()));
}

toitdoc::Section* ToitdocParser::parse_section() {
  ASSERT(peek() != ' ' && peek() != '\0');
  ListBuilder<toitdoc::Statement*> statements;

  auto title = Symbol::invalid();
  if (peek() == '#') {
    ConstructScope scope(this, SECTION_TITLE);
    advance();
    // Skip over leading whitespace.
    while (peek() == ' ') advance();
    int begin = _index;
    while (peek() != '\0') advance();
    title = make_symbol(begin, _index);
  }
  skip_whitespace();
  while (peek() != '#' && peek() != '\0') {
    auto statement = parse_statement();
    if (statement != null) statements.add(statement);
    skip_whitespace();
  }
  return _new toitdoc::Section(title, statements.build());
}

toitdoc::Statement* ToitdocParser::parse_statement() {
  ASSERT(peek() != ' ' && peek() != '\0');

  if (matches("```")) {
    return parse_code_section();
  } else if (matches("- ") || matches("* ")) {
    return parse_itemized();
  }
  return parse_paragraph();
}

toitdoc::CodeSection* ToitdocParser::parse_code_section() {
  ConstructScope scope(this, CODE_SECTION);
  advance("```");
  int begin = _index;
  // In theory we could look 3 characters ahead and skip to there if it isn't a '`', but
  // that is difficult to do if we don't want to jump over the terminating '\0'.
  while(peek() != '\0') {
    if (matches("```")) {
      int end = _index;
      advance("```");
      return _new toitdoc::CodeSection(make_symbol(begin, end));
    }
    advance();
  }
  report_error(begin - 3, _index, "Unterminated code section");
  return _new toitdoc::CodeSection(make_symbol(begin, _index));
}

static bool is_eol(int c) {
  return c == '\n' || c == '\0';
}

static bool is_operator_start(int c) {
  switch (c) {
    case '=':
    case '<':
    case '>':
    case '+':
    case '-':
    case '*':
    case '/':
    case '%':
    case '~':
    case '&':
    case '|':
    case '^':
    case '[':
      return true;
    default:
      return false;
  }
}

static bool is_comment_start(int c1, int c2) {
  return c1 == '/' && (c2 == '/' || c2 == '*');
}

toitdoc::Itemized* ToitdocParser::parse_itemized() {
  ConstructScope scope(this, ITEMIZED);
  ASSERT(matches("- ") || matches("* "));
  int indentation = _line_indentation;
  ListBuilder<toitdoc::Item*> items;

  do {
    items.add(parse_item(indentation));
    skip_whitespace();
  } while (matches("- ") || matches("* "));
  return _new toitdoc::Itemized(items.build());
}

toitdoc::Item* ToitdocParser::parse_item(int indentation) {
  ASSERT(matches("- ") || matches("* "));
  advance(2);

  ListBuilder<toitdoc::Statement*> statements;

  {
    // If there isn't a newline after the '{-|*} ' we have to handle it
    //   specially, since we need to give the paragraph an indentation.
    // Also, we don't allow code-segments or lists yet.
    // For example:
    //    - - foo  // should not be a list of list.
    //    - ```not a code segment```
    // Once we have a new line, we can use the regular `_line_indentation`.
    ConstructScope scope(this, ITEM_START, indentation);

    skip_whitespace();
    // The first paragraph's indentation starts after the '- '.
    // If there are spaces, then they are ignored.
    auto first_paragraph = parse_paragraph(indentation + 2);
    if (first_paragraph != null) statements.add(first_paragraph);
  }
  ConstructScope scope(this, ITEM, indentation);
  skip_whitespace();
  while (peek() != '\0') {
    auto statement = parse_statement();
    if (statement != null) statements.add(statement);
    skip_whitespace();
  }
  return _new toitdoc::Item(statements.build());
}

toitdoc::Paragraph* ToitdocParser::parse_paragraph(int indentation_override) {
  ConstructScope scope(this,
                       PARAGRAPH,
                       indentation_override >= 0 ? indentation_override : _line_indentation);

  ListBuilder<toitdoc::Expression*> expressions;

  int text_start = _index;
  while (true) {
    bool is_special_char = false;

    int c = peek();

    switch (c) {
      case '\0':
        is_special_char = true;
        break;

      case '`':
        is_special_char = true;
        break;

      case '$':
        // We want to allow $5.2 or even a simple $ in the text.
        // Only if the $ is followed by an identifier we treat it like a ref.
        is_special_char = look_ahead() == '(' ||
            is_identifier_start(look_ahead()) ||
            (is_operator_start(look_ahead()) && !is_comment_start(look_ahead(1), look_ahead(2)));
        break;

      case '"':
        is_special_char = true;
        break;

      case '/':
        is_special_char = look_ahead(1) == '*';
        break;

      case '\\':
        // Ignore the escape if it is at the end of a line.
        if (is_eol(look_ahead(1))) break;
        // TODO(florian): we could remove the '\'' when it's used to escape
        //   something toitdoc. We don't want to transform '\n' into a newline, but
        //   \$ could simply become '$' in the toitdoc.

        // Otherwise just skip the next character.
        advance(2);
        continue;

      case '\'':
        // Unless we are inside a string, a single quote can be used
        // to write a character: 'a'.
        // In that case we want to use it as if it was an escape.

        // Ignore the single quote if it is at the end of a line.
        if (is_eol(look_ahead(1))) break;
        if (look_ahead(1) == '\\') {
          if (is_eol(look_ahead(2))) break;
          if (look_ahead(3) == '\'') {
            // A character in the text. For example: '\n'
            // Skip over the characters and
            advance(3);
            continue;
          }
        } else if (look_ahead(2) == '\'') {
          // A character in the text. For example: '"'.
          advance(2);
          continue;
        }
    }

    if (!is_special_char) {
      advance();
      continue;
    }

    // Extract all the text so far, so we can handle the special char.
    if (text_start != _index) {
      expressions.add(_new toitdoc::Text(make_symbol(text_start, _index)));
    }

    if (c == '\0') break;

    switch (c) {
      // TODO(florian): we probably also want to parse '*' (bold) and/or '/' (emphasize) and lists.
      case '`': expressions.add(parse_code()); break;
      case '"': expressions.add(parse_string()); break;
      case '$': expressions.add(parse_ref()); break;
      case '/':
        // We know that '/' is a special char, and therefore that the next character must be
        // a '*'.
        ASSERT(look_ahead(1) == '*');
        skip_comment();
        break;
      default: UNREACHABLE();
    }

    text_start = _index;
  }

  ASSERT(peek() == '\0');

  // Combine texts if they are next to each other.

  // Start by counting how many expressions we have once we combined the texts.
  int expression_count = 0;
  bool last_was_text = false;
  for (int i = 0; i < expressions.length(); i++) {
    bool is_text = expressions[i]->is_Text();
    if (!last_was_text || !is_text) expression_count++;
    last_was_text = is_text;
  }

  auto combined_expressions = ListBuilder<toitdoc::Expression*>::allocate(expression_count);
  int combined_index = 0;
  // Run through them and combine adjacent texts.
  for (int i = 0; i < expressions.length(); i++) {
    auto expression = expressions[i];
    bool is_text = expression->is_Text();
    if (is_text) {
      int begin = i;
      while (i + 1 < expressions.length() && expressions[i + 1]->is_Text()) {
        i++;
      }
      if (begin != i) {
        std::string buffer;
        for (int j = begin; j <= i; j++) {
          buffer += expressions[j]->as_Text()->text().c_str();
        }
        auto combined_symbol = Symbol::synthetic(buffer);
        expression = _new toitdoc::Text(combined_symbol);
      }
    }
    combined_expressions[combined_index++] = expression;
  }

  if (combined_expressions.is_empty()) return null;
  return _new toitdoc::Paragraph(combined_expressions);
}

toitdoc::Code* ToitdocParser::parse_code() {
  return _new toitdoc::Code(parse_delimited('`',
                                            false,
                                            "Incomplete `code` segment"));
}

toitdoc::Text* ToitdocParser::parse_string() {
  return _new toitdoc::Text(parse_delimited('"',
                                            true,
                                            "Incomplete string"));
}

Symbol ToitdocParser::parse_delimited(int delimiter,
                                      bool keep_delimiters_and_escapes,
                                      const char* error_message) {
  ASSERT(peek() == delimiter);
  int delimited_begin = _index;
  int chunk_start = keep_delimiters_and_escapes ? _index : _index + 1;
  int c;
  std::string buffer;
  do {
    advance();
    c = peek();
    if (c == '\\' &&
        ((look_ahead() == '\\' || look_ahead() == delimiter))) {
      if (keep_delimiters_and_escapes) {
        // Skip over the escaped character.
        advance(2);
      } else {
        buffer += make_string(chunk_start, _index);
        advance();
        chunk_start = _index;
        advance();
      }
    }
  } while (c != delimiter && c != '\0');
  ASSERT(c == delimiter || c == '\0');

  int end_offset;
  if (c != delimiter) {
    report_error(delimited_begin, _index, error_message);
    end_offset = _index;
  } else {
    end_offset = keep_delimiters_and_escapes ? _index + 1 : _index;
    advance();
  }
  buffer += make_string(chunk_start, end_offset);
  return Symbol::synthetic(buffer);
}

toitdoc::Ref* ToitdocParser::parse_ref() {
  ASSERT(peek() == '$');
  int begin = _index + 1;

  bool is_parenthesized = look_ahead(1) == '(';
  NullDiagnostics null_diagnostics(_diagnostics->source_manager());
  // We never want errors from the scanner. This makes it possible to
  // read after the toitdoc-reference part in the scanner.
  // Note that this also means that we won't complain about tabs in
  // signature references (as in `$(foo\n\tbar)`).
  Scanner scanner(_toitdoc_source, _symbols, &null_diagnostics);
  scanner.advance_to(begin);
  Parser parser(_toitdoc_source, &scanner, _diagnostics);
  auto ast_node = parser.parse_toitdoc_reference(&_index);
  int id = _reference_asts.size();
  _reference_asts.push_back(ast_node);
  int end = _index;
  if (is_parenthesized) {
    begin++;
    if (look_ahead(-1) == ')') end--;
  }
  return _new toitdoc::Ref(id, make_symbol(begin, end));
}

void ToitdocParser::skip_comment(bool should_report_error) {
  ConstructScope scope(this, COMMENT);
  ASSERT(look_ahead(0) == '/' && look_ahead(1) == '*');
  int begin = _index;
  advance(2);
  int c;
  do {
    c = peek();
    if (c == '\0') {
      break;
    } else if (c == '\\') {
      if (look_ahead(1) != '\0') {
        advance(2);
      } else {
        advance();
      }
    } else if (c == '*' && look_ahead(1) == '/') {
      advance(2);
      return;
    } else {
      advance();
    }
  } while (true);
  if (should_report_error) {
    report_error(begin, _index, "Unterminated comment");
  }
}

void ToitdocParser::push_construct(Construct construct, int indentation) {
  _indentation_stack.push_back(indentation);
  _construct_stack.push_back(construct);
}

void ToitdocParser::pop_construct(Construct construct) {
  ASSERT(_construct_stack.back() == construct);
  _indentation_stack.pop_back();
  _construct_stack.pop_back();
  // Make the next 'peek' recompute whether we are at the end of the current construct.
  _is_at_dedent = false;
  _next_indentation = -1;
  _next_index = -1;
}

std::string ToitdocParser::make_string(int from, int to) {
  bool squash_spaces = false;
  bool replace_newlines_with_space = false;
  switch (_construct_stack.back()) {
    case CONTENTS:
    case SECTION_TITLE:
    case PARAGRAPH:
      squash_spaces = true;
      replace_newlines_with_space = true;
      break;

    case CODE_SECTION:
      squash_spaces = false;
      replace_newlines_with_space = false;
      break;

    case COMMENT:
    case ITEMIZED:
    case ITEM_START:
    case ITEM:
      UNREACHABLE();
  }

  char* buffer = unvoid_cast<char*>(malloc(to - from + 1));
  int buffer_index = 0;

  auto text = _toitdoc_source->text();
  bool last_was_space = false;
  bool last_was_newline = false;
  for (int i = from; i < to; i++) {
    if (last_was_newline) {
      last_was_newline = false;
      // Skip the indentation.
      for (int j = 0; j < _indentation_stack.back(); j++) {
        // We might run over the allocated 'to', but that shouldn't be a problem.
        if (text[i] != ' ') break;
        i++;
      }
      if (i >= to) break;
    }
    int c = text[i];
    if (c == '\n' && replace_newlines_with_space) c = ' ';
    if (c == ' ' && last_was_space && squash_spaces) continue;

    last_was_newline = c == '\n';
    last_was_space = c == ' ';

    buffer[buffer_index++] = c;
  }
  buffer[buffer_index] = '\0';
  auto result = std::string(buffer);
  free(buffer);
  return result;
}

bool ToitdocParser::matches(const char* str) {
  int i = 0;
  while (str[i] != '\0') {
    if (str[i] != look_ahead(i)) return false;
    i++;
  }
  return true;
}

int ToitdocParser::peek() {
  bool is_single_line = false;    // Single-line construct.
  bool is_delimited = false;      // May violate indentation (but with error message).
  bool allows_empty_line = false; // May have empty lines. (Counter-example: paragraphs).
  bool must_be_indented = false;  // Whether the next lines must be indented or can be at the same level as the construct.

  switch (_construct_stack.back()) {
    case SECTION_TITLE:
    case ITEM_START:
      is_single_line = true;
      is_delimited = false;
      allows_empty_line = false; // Doesn't matter because of `is_single_line`.
      must_be_indented = true;   // Doesn't matter because of `is_single_line`.
      break;

    case CODE_SECTION:
      // Note that we will parse the code section with '\n' replaced as ' ', but
      // the actual make_string doesn't do that.
      is_single_line = false;
      is_delimited = true;
      allows_empty_line = true;
      must_be_indented = false;  // Implied by `is_delimited`.
      break;

    case CONTENTS:
      is_single_line = false;
      is_delimited = false;
      allows_empty_line = true;
      must_be_indented = false;  // Doesn't matter, because contents-indentation is -1.
      break;

    case ITEMIZED:
      is_single_line = false;
      is_delimited = false;
      allows_empty_line = true;
      must_be_indented = false;
      break;

    case ITEM:
      is_single_line = false;
      is_delimited = false;
      allows_empty_line = true;
      must_be_indented = true;
      break;

    case PARAGRAPH:
      is_single_line = false;
      is_delimited = false;
      allows_empty_line = false;
      must_be_indented = true;
      break;

    case COMMENT:
      return _toitdoc_source->text()[_index];
  }

  if (_is_at_dedent) return '\0';
  auto text = _toitdoc_source->text();
  // The toit-doc source is null-terminated, so it's safe to read at out-of bounds.
  ASSERT(_index <= _toitdoc_source->size());
  ASSERT(text[_toitdoc_source->size()] == '\0');
  int c = text[_index];
  if (is_newline(c)) {
    // Note that this branch always returns, and that it never returns '\r' or
    //   '\n' (only ' ' or '\0').
    // Callers thus don't need to worry about '\n', but can simply check for
    //   whitespace by looking for spaces.
    if (is_single_line) return '\0';
    if (_next_index != -1) {
      // We already computed the indentation once and know that we aren't at a dedent.
      return ' ';
    }
    // The source is null-terminated. It's safe to read out of bounds.
    if (c == '\r' && text[_index + 1] == '\n') {
      _next_index = _index + 2;
    } else {
      _next_index = _index + 1;
    }
    _next_indentation = 0;
    bool skipped_over_multiple_lines = false;
    // The only whitespace we care for are spaces.
    // Otherwise we would need to deal with the width of '\t'.
    while (text[_next_index] == ' ' || is_newline(text[_next_index])) {
      if (is_newline(text[_next_index])) {
        skipped_over_multiple_lines = true;
        _next_indentation = 0;
      } else {
        _next_indentation++;
      }
      // The source is null-terminated. It's safe to read out of bounds.
      if (text[_next_index] == '\r' && text[_next_index + 1] == '\n') {
        _next_index += 2;
      } else {
        _next_index++;
      }
    }
    if (skipped_over_multiple_lines && !allows_empty_line) {
      _is_at_dedent = true;
      return '\0';
    }
    if (_next_indentation < _indentation_stack.back()) {
      if (is_delimited) {
        if (_next_indentation < _indentation_stack.back() &&
            text[_next_index] != '\0') {
          _diagnostics->report_error(_toitdoc_source->range(_index, _index + 1),
                                      "Bad indentation");
        }
        return ' ';
      } else {
        _is_at_dedent = true;
        return '\0';
      }
    } else if (_next_indentation == _indentation_stack.back()) {
      if (must_be_indented) {
        _is_at_dedent = true;
        return '\0';
      } else {
        return ' ';
      }
    } else {
      return ' ';
    }
    UNREACHABLE();
  }
  return c;
}

int ToitdocParser::look_ahead(int n) {
  ASSERT(0 <= _index + n && _index + n <= _toitdoc_source->size());
  if (n == 0) return peek();
  return _toitdoc_source->text()[_index + n];
}


void ToitdocParser::advance(int n) {
  for (int i = 0; i < n; i++) {
    int c = peek();
    if (c == '\0') {
      _is_at_dedent = false;
      return;
    }
    if (_next_index >= 0) {
      _index = _next_index;
      _line_indentation = _next_indentation;
      _next_index = -1;
      _next_indentation = -1;
    } else {
      _index++;
    }
  }
}

void ToitdocParser::skip_initial_whitespace() {
  auto text = _toitdoc_source->text();
  int initial_indentation = 0;
  while (text[initial_indentation] == ' ') {
    initial_indentation++;
  }
  _line_indentation = initial_indentation;
  skip_whitespace();
}

void ToitdocParser::skip_whitespace() {
  while (peek() == ' ') advance();
}

void ToitdocParser::report_error(int from, int to, const char* message) {
  report_error(_toitdoc_source->range(from, to), message);
}

void ToitdocParser::report_error(Source::Range range, const char* message) {
  // If the diagnostics is (as expected) a ToitdocDiagnostics, it will change the
  //   error into a warning.
  _diagnostics->report_error(range, message);
}

int CommentsManager::find_closest_before(ast::Node* node) {
  auto node_range = node->range();
  if (node_range.is_before(_comments[0].range())) return -1;
  if (_comments.last().range().is_before(node_range)) return _comments.length() - 1;

  if (_comments[_last_index].range().is_before(node_range) &&
      node_range.is_before(_comments[_last_index + 1].range())) {
    return _last_index;
  }
  int start = 0;
  int end = _comments.length() - 1;
  while (start < end) {
    int mid = start + (end - start) / 2;
    if (_comments[mid].range().is_before(node_range)) {
      if (node_range.is_before(_comments[mid + 1].range())) {
        return mid;
      }
      start = mid + 1;
    } else {
      end = mid;
    }
  }
  return -1;
}

/// When [allow_modifiers] is true, allows modifiers on the line of the
///   [next] range.
/// For simplicity we allow any string as long as it doesn't contain a `:` which
///   would indicate a different declaration: `class A: foo:`
// TODO(florian, 1218): Remove the hack. The declaration range should be correct and
//    include modifiers.
bool CommentsManager::is_attached(Source::Range previous,
                                  Source::Range next,
                                  bool allow_modifiers) {
  // Check that there is one newline, and otherwise only whitespace.
  int start_offset = _source->offset_in_source(previous.to());
  int end_offset = _source->offset_in_source(next.from());
  int i = start_offset;
  auto text = _source->text();
  while (i < end_offset and text[i] == ' ') i++;
  if (i == end_offset) return true;
  if (text[i] == '\r') i++;
  if (i == end_offset) return true;
  if (text[i++] != '\n') return false;
  while (i < end_offset and text[i] == ' ') i++;
  if (i == end_offset) return true;
  if (!allow_modifiers) return false;
  for (; i < end_offset; i++) {
    if (text[i] == '\n') return false;
    if (text[i] == '\r') return false;
    if (text[i] == ':') return false;
  }
  return true;
}


Toitdoc<ast::Node*> CommentsManager::find_for(ast::Node* node) {
  auto not_found = Toitdoc<ast::Node*>::invalid();
  int closest = find_closest_before(node);
  if (closest == -1) return not_found;
  if (!is_attached(_comments[closest].range(), node->range(), true)) return not_found;
  int closest_toit = closest;
  // Walk backward to find the closest toitdoc.
  // Usually it's the first attached comment, but we allow non-toitdocs:
  //
  // Example:
  //     /** Toitdoc ... */
  //     // Some implementation comment.
  //     class SomeClass:
  //
  while (true) {
    if (_comments[closest_toit].is_toitdoc()) break;
    if (closest_toit == 0) return not_found;
    if (!is_attached(closest_toit - 1, closest_toit)) {
      return not_found;
    }
    closest_toit--;
  }
  return make_ast_toitdoc(closest_toit);
}

Toitdoc<ast::Node*> CommentsManager::make_ast_toitdoc(int index) {
  // If the comment is a single line '///' comment, search for comments that
  // precede and succeed it.
  int first_toit = index;
  int last_toit = index;
  if (!_comments[index].is_multiline()) {
    while (first_toit > 0 &&
          !_comments[first_toit - 1].is_multiline() &&
          _comments[first_toit - 1].is_toitdoc() &&
          is_attached(first_toit - 1, first_toit)) {
      first_toit--;
    }
    while (last_toit < _comments.length() - 1 &&
          !_comments[last_toit + 1].is_multiline() &&
          _comments[last_toit + 1].is_toitdoc() &&
          is_attached(last_toit, last_toit + 1)) {
      last_toit++;
    }
  }

  auto range = _comments[first_toit].range().extend(_comments[last_toit].range());
  int from_offset = _source->offset_in_source(range.from());
  int to_offset = _source->offset_in_source(range.to());
  ToitdocSource* collected_text = _comments[first_toit].is_multiline()
      ? extract_multiline_comment_text(_source, from_offset, to_offset)
      : extract_singleline_comment_text(_source, from_offset, to_offset);
  ToitdocParser parser(collected_text, _symbols, _diagnostics);
  return parser.parse();
}

} // namespace anonymous

void attach_toitdoc(ast::Unit* unit,
                    List<Scanner::Comment> scanner_comments,
                    Source* source,
                    SymbolCanonicalizer* symbols,
                    Diagnostics* diagnostics) {
  if (scanner_comments.is_empty()) return;
  ToitdocDiagnostics toitdoc_diagnostics(diagnostics);
  CommentsManager comments_manager(scanner_comments, source, symbols, &toitdoc_diagnostics);

  ast::Node* earliest_declaration = null;
  for (auto declaration : unit->declarations()) {
    if (earliest_declaration == null ||
        declaration->range().is_before(earliest_declaration->range())) {
      earliest_declaration = declaration;
    }

    if (declaration->is_Declaration()) {
      auto toitdoc = comments_manager.find_for(declaration);
      declaration->as_Declaration()->set_toitdoc(toitdoc);
    } else {
      ASSERT(declaration->is_Class());
      auto klass = declaration->as_Class();
      auto toitdoc = comments_manager.find_for(klass);
      klass->set_toitdoc(toitdoc);
      for (auto member : klass->members()) {
        auto member_toitdoc = comments_manager.find_for(member);
        member->set_toitdoc(member_toitdoc);
      }
    }
  }

  for (int i = 0; i < scanner_comments.length(); i++) {
    auto comment = scanner_comments[i];
    if (!comment.is_toitdoc()) continue;
    // First toitdoc comment, as we break at the end of the loop body.
    // Check if the comment is before any declaration and if it's not associated
    //   with any existing declaration.
    bool is_module_comment = false;
    if (earliest_declaration == null) {
      is_module_comment = true;
    } else if (earliest_declaration->range().is_before(comment.range())) {
      // Comment is after the first declaration and thus not a module comment.
      is_module_comment =false;
    } else {
      auto declaration_comment = Toitdoc<ast::Node*>::invalid();
      if (earliest_declaration->is_Declaration()) {
        declaration_comment = earliest_declaration->as_Declaration()->toitdoc();
      } else {
        ASSERT(earliest_declaration->is_Class());
        declaration_comment = earliest_declaration->as_Class()->toitdoc();
      }
      if (declaration_comment.is_valid()) {
        // The range of a comment includes its delimiters, whereas a toitdoc range only
        //   includes the actual text. The beginning of a toitdoc is thus always after
        //   the beginning of its comment. Therefore we have to compare the 'to' of the
        //   comment with the 'from' of the toitdoc. Only if the 'to' is before the 'from'
        //   we can be sure that this is not the same comment.
        is_module_comment = comment.range().to().is_before(declaration_comment.range().from());
      } else {
        is_module_comment = true;
      }
    }
    if (is_module_comment) {
      unit->set_toitdoc(comments_manager.make_ast_toitdoc(i));
    }
    break;
  }
}

} // namespace toit::compiler
} // namespace toit
