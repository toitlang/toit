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

#include <map>
#include <string>

#include "migration_type.h"

#include "ast.h"
#include "comments.h"
#include "diagnostic.h"
#include "symbol_canonicalizer.h"

namespace toit {
namespace compiler {

namespace {  // anonymous

static const char* const TYPE_MARKER = "__TYPE-MIGRATION__";

// Reuses the scanner's identifier-start rule. Unlike the scanner we allow '-'
// anywhere, since we only scan our own annotation comments.
static bool is_identifier_part(int c) {
  return Scanner::is_identifier_start(c) || is_decimal_digit(c) || c == '-';
}

static bool matches(const uint8* text, int pos, int to, const char* str) {
  int len = strlen(str);
  if (pos + len > to) return false;
  return memcmp(text + pos, str, len) == 0;
}

// We author the annotation comments ourselves, so trimming spaces is enough.
static std::string trim_spaces(const std::string& str) {
  auto start = str.find_first_not_of(' ');
  auto end = str.find_last_not_of(' ');
  if (start == std::string::npos) return "";
  return str.substr(start, end - start + 1);
}

struct ParsedAnnotation {
  Symbol name = Symbol::invalid();
  Source::Range name_range = Source::Range::invalid();
  ast::MigrationType* migration_type = null;
  bool is_used = false;

  bool is_valid() const { return migration_type != null; }
};

class MigrationTypeManager : public CommentsManager {
 public:
  MigrationTypeManager(List<Scanner::Comment> comments,
                        Source* source,
                        SymbolCanonicalizer* symbols,
                        Diagnostics* diagnostics)
      : CommentsManager(comments, source)
      , symbols_(symbols)
      , diagnostics_(diagnostics) {}

  /// Finds and parses all `// __TYPE-MIGRATION__` comments.
  void collect() {
    for (int i = 0; i < comments_.length(); i++) {
      auto comment = comments_[i];
      if (comment.is_multiline() || comment.is_toitdoc()) continue;
      auto text = source_->text();
      int from = source_->offset_in_source(comment.range().from());
      int to = source_->offset_in_source(comment.range().to());
      ASSERT(matches(text, from, to, "//"));
      int pos = skip_spaces(text, from + 2, to);
      if (!matches(text, pos, to, TYPE_MARKER)) continue;
      pos += strlen(TYPE_MARKER);
      // Require a space after the marker, so we don't pick up unrelated
      // comments like '__TYPE-MIGRATION__S'.
      if (pos < to && text[pos] != ' ') continue;
      parsed_[i] = parse_annotation(text, pos, to, comment.range());
    }
  }

  bool has_annotations() const { return !parsed_.empty(); }

  /// Attaches the annotations of the comment block in front of [method] to
  /// the method's parameters.
  void attach_to(ast::Method* method) {
    int closest = find_closest_before(method);
    if (closest < 0) return;
    if (!is_attached(comments_[closest].range(), method->full_range())) return;
    int first = closest;
    while (first > 0 && is_attached(first - 1, first)) first--;

    auto parameters = method->parameters();
    // Run through the comments and attach each annotation to its parameter,
    // accumulating per parameter (in declaration order) and reporting the ones
    // that don't have a matching target.
    std::map<ast::Parameter*, ListBuilder<ast::MigrationType*>> per_parameter;
    for (int i = first; i <= closest; i++) {
      auto probe = parsed_.find(i);
      if (probe == parsed_.end()) continue;
      auto& parsed = probe->second;
      if (!parsed.is_valid()) continue;
      parsed.is_used = true;

      ast::Parameter* target = null;
      for (auto parameter : parameters) {
        if (parameter->name()->data() == parsed.name) {
          target = parameter;
          break;
        }
      }
      if (target == null) {
        diagnostics_->report_error(parsed.name_range,
                                   "No parameter '%s' for type-migration annotation",
                                   parsed.name.c_str());
      } else if (target->is_block()) {
        diagnostics_->report_error(parsed.name_range,
                                   "Can't use a type-migration annotation on a block parameter");
      } else {
        per_parameter[target].add(parsed.migration_type);
      }
    }

    for (auto& entry : per_parameter) {
      entry.first->set_migration_types(entry.second.build());
    }
  }

  /// Reports all `// __TYPE-MIGRATION__` comments that weren't attached to any method.
  void report_unattached() {
    for (auto& entry : parsed_) {
      auto& parsed = entry.second;
      if (!parsed.is_valid() || parsed.is_used) continue;
      diagnostics_->report_error(comments_[entry.first].range(),
                                 "Type-migration annotation isn't attached to a method declaration");
    }
  }

 private:
  SymbolCanonicalizer* symbols_;
  Diagnostics* diagnostics_;
  std::map<int, ParsedAnnotation> parsed_;

  static int skip_spaces(const uint8* text, int pos, int to) {
    while (pos < to && text[pos] == ' ') pos++;
    return pos;
  }

  int scan_identifier(const uint8* text, int pos, int to) {
    if (pos < to && Scanner::is_identifier_start(text[pos])) {
      while (pos < to && is_identifier_part(text[pos])) pos++;
    }
    return pos;
  }

  /// Parses `<name>: <type>[. Deprecated[. <message>]]`.
  /// The [pos] must be just after the `__TYPE-MIGRATION__` marker.
  ParsedAnnotation parse_annotation(const uint8* text, int pos, int to, Source::Range comment_range) {
    ParsedAnnotation result;
    pos = skip_spaces(text, pos, to);

    int name_start = pos;
    pos = scan_identifier(text, pos, to);
    auto name_range = source_->range(name_start, pos);
    if (pos == name_start) {
      diagnostics_->report_error(name_range, "Expected a parameter name in type-migration annotation");
      return result;
    }
    auto name_ts = symbols_->canonicalize_identifier(text + name_start, text + pos);
    if (name_ts.kind != Token::IDENTIFIER) {
      diagnostics_->report_error(name_range, "Invalid parameter name in type-migration annotation");
      return result;
    }
    result.name = name_ts.symbol;
    result.name_range = name_range;

    pos = skip_spaces(text, pos, to);
    if (pos >= to || text[pos] != ':') {
      diagnostics_->report_error(source_->range(pos, pos),
                                 "Expected ':' in type-migration annotation");
      return result;
    }
    pos = skip_spaces(text, pos + 1, to);

    auto type = parse_type(text, &pos, to);
    if (type == null) return result;

    // An optional '.' separates the type from the deprecation clause.
    pos = skip_spaces(text, pos, to);
    if (pos < to && text[pos] == '.') pos = skip_spaces(text, pos + 1, to);

    bool is_deprecated = false;
    auto deprecation_message = Symbol::invalid();
    if (pos < to) {
      if (matches(text, pos, to, "Deprecated") &&
          (pos + 10 == to ||
           text[pos + 10] == '.' || text[pos + 10] == ':' || text[pos + 10] == ' ')) {
        is_deprecated = true;
        pos += strlen("Deprecated");
        if (pos < to && (text[pos] == '.' || text[pos] == ':')) pos++;
        std::string message(char_cast(text + pos), to - pos);
        message = trim_spaces(message);
        // Remove a trailing '.' if it exists.
        if (!message.empty() && message.back() == '.') message.pop_back();
        // If the message is not empty, add a '. ' to the beginning. This way
        // it can be attached to the warning string without any checks.
        if (!message.empty()) message = ". " + message;
        deprecation_message = Symbol::synthetic(message);
      } else {
        diagnostics_->report_error(source_->range(pos, to),
                                   "Unexpected text in type-migration annotation");
        return result;
      }
    }

    result.migration_type = _new ast::MigrationType(type,
                                                    is_deprecated,
                                                    deprecation_message,
                                                    comment_range);
    return result;
  }

  /// Parses a type: a (potentially prefixed) identifier with an optional '?'.
  /// Returns null (after reporting an error) if the type is malformed.
  ast::Expression* parse_type(const uint8* text, int* pos_ptr, int to) {
    int pos = *pos_ptr;
    int start = pos;
    ast::Expression* result = null;
    while (true) {
      int segment_start = pos;
      pos = scan_identifier(text, pos, to);
      auto segment_range = source_->range(segment_start, pos);
      if (pos == segment_start) {
        diagnostics_->report_error(segment_range, "Expected a type in type-migration annotation");
        return null;
      }
      auto ts = symbols_->canonicalize_identifier(text + segment_start, text + pos);
      if (ts.kind != Token::IDENTIFIER) {
        diagnostics_->report_error(segment_range, "Invalid type in type-migration annotation");
        return null;
      }
      auto id = _new ast::Identifier(ts.symbol);
      id->set_range(segment_range);
      if (result == null) {
        result = id;
      } else {
        auto dot = _new ast::Dot(result, id);
        dot->set_range(source_->range(start, pos));
        result = dot;
      }
      if (pos + 1 < to && text[pos] == '.' && Scanner::is_identifier_start(text[pos + 1])) {
        pos++;
        continue;
      }
      break;
    }
    if (pos < to && text[pos] == '?') {
      pos++;
      auto nullable = _new ast::Nullable(result);
      nullable->set_range(source_->range(start, pos));
      result = nullable;
    }
    *pos_ptr = pos;
    return result;
  }
};

}  // anonymous namespace.

void attach_migration_types(ast::Unit* unit,
                            List<Scanner::Comment> comments,
                            Source* source,
                            SymbolCanonicalizer* symbols,
                            Diagnostics* diagnostics) {
  if (comments.is_empty()) return;
  MigrationTypeManager manager(comments, source, symbols, diagnostics);
  manager.collect();
  if (!manager.has_annotations()) return;

  for (auto declaration : unit->declarations()) {
    if (declaration->is_Method()) {
      manager.attach_to(declaration->as_Method());
    } else if (declaration->is_Class()) {
      for (auto member : declaration->as_Class()->members()) {
        if (member->is_Method()) manager.attach_to(member->as_Method());
      }
    }
  }
  manager.report_unattached();
}

} // namespace toit::compiler
} // namespace toit
