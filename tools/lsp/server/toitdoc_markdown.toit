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

import .toitdoc-node

class ToitdocMarkdownVisitor implements ToitdocVisitor:
  chunks_ / List ::= []

  build -> string:
    return (chunks_.join "").trim

  visit-Contents node/Contents:
    node.sections.do: it.accept this

  visit-Section node/Section:
    if node.title:
      chunks_.add "### $node.title\n\n"
    node.statements.do: it.accept this

  visit-CodeSection node/CodeSection:
    chunks_.add "```toit\n$node.text\n```\n\n"

  visit-Itemized node/Itemized:
    node.items.do: it.accept this

  visit-Item node/Item:
    chunks_.add "- "
    node.statements.do: it.accept this

  visit-Paragraph node/Paragraph:
    node.expressions.do: it.accept this
    chunks_.add "\n\n"

  visit-Text node/Text:
    chunks_.add node.text

  visit-Code node/Code:
    chunks_.add "`$node.text`"

  visit-Link node/Link:
    chunks_.add "[$node.text]($node.url)"

  visit-ToitdocRef node/ToitdocRef:
    chunks_.add "`$node.text`"
