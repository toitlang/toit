// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include <string>

#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_source.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/sources.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"
#include "format-test-support.h"

namespace toit {
namespace compiler {

static int comment_containing(const FormatSource& source, const char* needle) {
  for (const auto& comment : source.comments()) {
    if (comment.text.find(needle) != std::string::npos) return comment.id;
  }
  return -1;
}

static int line_containing(const FormatSource& source, const char* needle) {
  for (int i = 0; i < static_cast<int>(source.lines().size()); i++) {
    const FormatLine& line = source.lines()[i];
    if (source.text(line.from, line.content_to).find(needle) !=
        std::string::npos) {
      return i;
    }
  }
  return -1;
}

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s---\nActual:\n---\n%s---\n",
          expected, actual.c_str());
  exit(1);
}

static void test_format_source(Source* source,
                               List<Scanner::Comment> comments) {
  FormatSource facts(source, comments);

  int frozen_line = line_containing(facts, "value := 1");
  ASSERT(frozen_line >= 0);
  ASSERT(facts.lines()[frozen_line].is_frozen());
  expect("    value := 1  // Keep   every byte.\n",
         facts.reindent_line(frozen_line, 4));

  int own_line_id = comment_containing(facts, "on its own line");
  ASSERT(own_line_id >= 0);
  ASSERT(!facts.comments()[own_line_id].follows_code);
  ASSERT(!facts.lines()[facts.comments()[own_line_id].start_line].is_frozen());

  int attached_id = comment_containing(facts, "Attached");
  ASSERT(attached_id >= 0);
  ASSERT(facts.comments()[attached_id].follows_code);
  ASSERT(facts.comments()[attached_id].spans_lines);
  expect("/* Attached\n                 alignment. */",
         facts.shift_multiline_comment(
             attached_id, facts.comments()[attached_id].start_column + 2));

  int standalone_id = comment_containing(facts, "Standalone");
  ASSERT(standalone_id >= 0);
  ASSERT(!facts.comments()[standalone_id].follows_code);
  expect("/* Standalone\n       block. */",
         facts.shift_multiline_comment(
             standalone_id,
             facts.comments()[standalone_id].start_column + 2));

  FormatCommentState state(&facts);
  std::string own_line;
  const FormatComment& own_line_comment = facts.comments()[own_line_id];
  bool rendered = state.render_own_line(
      own_line_comment.from, own_line_comment.to, 2, &own_line);
  ASSERT(rendered);
  expect("    // This comment is on its own line.", own_line);
  ASSERT(state.consumed(own_line_id));

  const FormatComment& standalone = facts.comments()[standalone_id];
  rendered = state.render_own_line(
      standalone.from, standalone.to, 2, &own_line);
  ASSERT(rendered);
  expect("    /* Standalone\n       block. */", own_line);
  ASSERT(state.consumed(standalone_id));

  expect("    value := 1  // Keep   every byte.",
         state.render_verbatim(frozen_line, frozen_line, 4));
  ASSERT(state.consumed(facts.lines()[frozen_line].trailing_line_comment));
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);

  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::NullDiagnostics diagnostics(&sources);
  auto loaded = sources.load_file(
      argv[1], toit::compiler::Package::invalid());
  ASSERT(loaded.status ==
         toit::compiler::SourceManager::LoadResult::OK);
  toit::compiler::SymbolCanonicalizer symbols;
  toit::compiler::Scanner scanner(loaded.source, &symbols, &diagnostics);
  while (scanner.next().token() != toit::compiler::Token::EOS) {}
  toit::compiler::test_format_source(
      loaded.source, scanner.comments());
  return 0;
}
