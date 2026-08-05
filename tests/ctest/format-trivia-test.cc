// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include <string>

#include "../../src/compiler/diagnostic.h"
#include "../../src/compiler/filesystem_local.h"
#include "../../src/compiler/format_trivia.h"
#include "../../src/compiler/scanner.h"
#include "../../src/compiler/symbol_canonicalizer.h"
#include "../../src/top.h"

namespace toit {
namespace compiler {

static void expect(const char* expected, const std::string& actual) {
  if (actual == expected) return;
  fprintf(stderr, "Expected:\n---\n%s\n---\nActual:\n---\n%s\n---\n", expected,
          actual.c_str());
  exit(1);
}

static std::string rendered(Layout* layout, int width = 100) {
  return render_plan(std::move(select_layout(layout, width)).freeze());
}

static int find(const std::string& text, const char* needle) {
  size_t result = text.find(needle);
  if (result == std::string::npos) exit(1);
  return static_cast<int>(result);
}

static int comment_at(const FormatTrivia& trivia, int offset) {
  for (int id = 0; id < static_cast<int>(trivia.comments().size()); id++) {
    if (trivia.comments()[id].from == offset) return id;
  }
  exit(1);
}

static void test_early_trivia(Source* source, const FormatTrivia& trivia) {
  std::string source_text(reinterpret_cast<const char*>(source->text()),
                          source->size());
  ASSERT(trivia.comments().size() == 6);

  LayoutBuilder layouts;
  TriviaLowering lowering(&trivia, &layouts);

  int header = find(source_text, "sample foo:");
  int line_comment = find(source_text, "// Keep");
  int line_id = comment_at(trivia, line_comment);
  int line_comment_end = trivia.comments()[line_id].to;
  int frozen = lowering.first_line_comment(header, header + 11, true);
  ASSERT(frozen == line_id);
  expect("sample foo:  // Keep   every byte.",
         rendered(lowering.verbatim_region(header, line_comment_end)));

  int type = find(source_text, "\n  foo") + 3;
  int attached_id = comment_at(trivia, type + 3);
  int attached_end = trivia.comments()[attached_id].to;
  Layout* attached =
      lowering.take_inline_suffix(layouts.text("foo"), type + 3, attached_end);
  expect("foo/*<int>*/", rendered(attached));

  int standalone_id = comment_at(trivia, find(source_text, "/* Standalone"));
  Layout* own_line = lowering.take_own_line_block(standalone_id);
  Layout* body = layouts.concat({
      layouts.text("if true:"),
      layouts.indent(2, layouts.concat({
                            layouts.hardline(),
                            own_line,
                            layouts.hardline(),
                            layouts.text("return"),
                        })),
  });
  expect(
      "if true:\n"
      "  /* Standalone\n"
      "     block. */\n"
      "  return",
      rendered(body));

  // The copyright preamble lies outside every formatted unit in this focused
  // test. The three comments exercised above were each consumed once.
  ASSERT(line_id != attached_id && attached_id != standalone_id);
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::throwing_new_allowed = true;
  ASSERT(argc == 2);

  toit::compiler::FilesystemLocal filesystem;
  toit::compiler::SourceManager sources(&filesystem);
  toit::compiler::NullDiagnostics diagnostics(&sources);
  toit::compiler::SourceManager::LoadResult loaded =
      sources.load_file(argv[1], toit::compiler::Package::invalid());
  ASSERT(loaded.status == toit::compiler::SourceManager::LoadResult::OK);

  toit::compiler::SymbolCanonicalizer symbols;
  toit::compiler::Scanner scanner(loaded.source, &symbols, &diagnostics);
  while (scanner.next().token() != toit::compiler::Token::EOS) {
  }
  toit::compiler::FormatTrivia trivia(loaded.source, scanner.comments());
  toit::compiler::test_early_trivia(loaded.source, trivia);
  return 0;
}
