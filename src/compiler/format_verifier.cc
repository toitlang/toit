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

#include "format_verifier.h"

#include <stdio.h>
#include <string>
#include <utility>
#include <vector>

#include "ast_equivalence.h"
#include "diagnostic.h"
#include "parser.h"
#include "scanner.h"
#include "sources.h"
#include "symbol_canonicalizer.h"

namespace toit {
namespace compiler {

namespace {

struct CommentFingerprint {
  std::string text;
  bool has_code_before_on_line;

  bool operator==(const CommentFingerprint& other) const {
    return text == other.text
        && has_code_before_on_line == other.has_code_before_on_line;
  }
};

std::vector<CommentFingerprint> comment_fingerprints(Scanner* scanner,
                                                     Source* source) {
  std::vector<CommentFingerprint> result;
  for (auto comment : scanner->comments()) {
    if (!comment.is_valid()) continue;
    int from = source->offset_in_source(comment.range().from());
    int to = source->offset_in_source(comment.range().to());
    std::string text(char_cast(source->text()) + from, to - from);
    std::string normalized;
    bool at_line_start = false;
    for (char c : text) {
      if (at_line_start && (c == ' ' || c == '\t')) continue;
      at_line_start = c == '\n';
      normalized.push_back(c);
    }
    bool has_code_before_on_line = false;
    for (int i = from - 1;
         i >= 0 && source->text()[i] != '\n';
         i--) {
      if (source->text()[i] != ' ' && source->text()[i] != '\t') {
        has_code_before_on_line = true;
        break;
      }
    }
    result.push_back({std::move(normalized), has_code_before_on_line});
  }
  return result;
}

void print_excerpt(const char* label, Source* source, ast::Node* node) {
  if (node == null) {
    fprintf(stderr, "  %s: <missing node>\n", label);
    return;
  }
  int from = source->offset_in_source(node->full_range().from());
  int to = source->offset_in_source(node->full_range().to());
  int length = to - from;
  if (length > 200) length = 200;
  fprintf(stderr, "  %s %s (offset %d): %.*s\n",
          label, node->node_type(), from, length,
          char_cast(source->text()) + from);
}

} // namespace

bool verify_formatted_output(SourceManager* source_manager,
                             Source* original_source,
                             Scanner* original_scanner,
                             ast::Unit* original_unit,
                             const uint8* formatted,
                             int formatted_size,
                             const char* out_path) {
  Source* formatted_source = source_manager->load_from_memory(
      std::string(original_source->absolute_path()) + "<formatted>",
      formatted,
      formatted_size);
  bool show_package_warnings;
  bool print_diagnostics_on_stdout;
  AnalysisDiagnostics diagnostics(source_manager,
                                  show_package_warnings=false,
                                  print_diagnostics_on_stdout=false);
  SymbolCanonicalizer symbols;
  Scanner scanner(formatted_source, &symbols, &diagnostics);
  Parser parser(formatted_source, &scanner, &diagnostics);
  ast::Unit* formatted_unit = parser.parse_unit();
  if (diagnostics.encountered_error()) {
    fprintf(stderr,
            "toit format: formatter produced output with parse errors; "
            "refusing to write %s\n",
            out_path);
    return false;
  }

  ast::Node* mismatch_original = null;
  ast::Node* mismatch_formatted = null;
  if (!ast_equivalent(original_unit,
                      formatted_unit,
                      &mismatch_original,
                      &mismatch_formatted)) {
    fprintf(stderr,
            "toit format: formatter changed meaning; refusing to write %s\n",
            out_path);
    print_excerpt("original ", original_source, mismatch_original);
    print_excerpt("formatted", formatted_source, mismatch_formatted);
    return false;
  }

  // Preserve comment text and whether each comment follows code on its line.
  // Interior indentation of line-spanning comments belongs to the formatter,
  // so the comparison normalizes leading whitespace on interior lines.
  auto original_comments =
      comment_fingerprints(original_scanner, original_source);
  auto formatted_comments = comment_fingerprints(&scanner, formatted_source);
  if (original_comments == formatted_comments) return true;

  fprintf(stderr,
          "toit format: formatter dropped or changed a comment; "
          "refusing to write %s\n",
          out_path);
  size_t common = 0;
  while (common < original_comments.size()
         && common < formatted_comments.size()
         && original_comments[common] == formatted_comments[common]) {
    common++;
  }
  if (common < original_comments.size()) {
    fprintf(stderr, "  original : %s (%s)\n",
            original_comments[common].text.c_str(),
            original_comments[common].has_code_before_on_line
                ? "end-of-line"
                : "own-line");
  }
  if (common < formatted_comments.size()) {
    fprintf(stderr, "  formatted: %s (%s)\n",
            formatted_comments[common].text.c_str(),
            formatted_comments[common].has_code_before_on_line
                ? "end-of-line"
                : "own-line");
  }
  return false;
}

} // namespace toit::compiler
} // namespace toit
