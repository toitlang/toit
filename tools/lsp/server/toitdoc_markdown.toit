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
