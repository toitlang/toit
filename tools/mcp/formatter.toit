// Copyright (C) 2026 Toitware ApS.
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

import ..toitdoc.src.builder show
    DocCode
    DocCodeSection
    DocExpression
    DocItem
    DocItemized
    DocLink
    DocParagraph
    DocSection
    DocStatement
    DocText
    DocToitdocRef
    Toitdoc

/**
Converts structured data from DocIndex into clean, readable Markdown.
*/
class DocFormatter:
  /**
  Formats the library list as Markdown.

  The $entries list contains maps with "name", "path", and "modules" keys.
  */
  static format-library-list entries/List -> string:
    lines := ["# Available Libraries"]
    if entries.is-empty:
      lines.add ""
      lines.add "No libraries found."
      return lines.join "\n"

    entries.do: | entry/Map |
      name := entry["name"]
      modules := entry["modules"]
      lines.add ""
      lines.add "## $name"
      if modules is List and not (modules as List).is-empty:
        lines.add "Modules: $((modules as List).join ", ")"

    return lines.join "\n"

  /**
  Formats search results as Markdown.

  The $results list contains maps with "name", "kind", "library", and
    "summary" keys. The $query is shown in the heading.
  */
  static format-search-results results/List --query/string -> string:
    lines := ["# Search Results for \"$query\""]
    if results.is-empty:
      lines.add ""
      lines.add "No results found."
      return lines.join "\n"

    lines.add ""
    results.size.repeat: | i |
      entry := results[i] as Map
      name := entry["name"]
      kind := entry["kind"]
      library := entry["library"]
      summary := entry.get "summary" --if-absent=: ""
      lines.add "$(i + 1). **$name** ($kind) - $library"
      if summary != "":
        lines.add "   $summary"
      lines.add ""

    return (lines.join "\n").trim

  /**
  Formats full element documentation as Markdown.

  The $element map has "name", "kind", "library", "toitdoc", and "members"
    keys.
  */
  static format-element element/Map -> string:
    name := element["name"]
    kind := element["kind"]
    lines := ["# $kind $name"]

    toitdoc := element.get "toitdoc"
    doc := format-toitdoc toitdoc
    if doc != "":
      lines.add ""
      lines.add doc

    members := element.get "members"
    if members is List and not (members as List).is-empty:
      lines.add ""
      if kind == "library":
        lines.add "## Contents"
      else:
        lines.add "## Members"

      (members as List).do: | member/Map |
        member-name := member["name"]
        member-kind := member["kind"]
        lines.add ""
        lines.add "### $member-name ($member-kind)"
        member-doc := format-toitdoc (member.get "toitdoc")
        if member-doc != "":
          lines.add ""
          lines.add member-doc

    return lines.join "\n"

  /**
  Renders toitdoc JSON as Markdown text.

  Returns an empty string if $toitdoc is null or empty.
  */
  static format-toitdoc toitdoc -> string:
    if toitdoc == null: return ""
    if toitdoc is Toitdoc:
      return format-toitdoc_ (toitdoc as Toitdoc)
    parsed := Toitdoc.from-json toitdoc
    if not parsed: return ""
    return format-toitdoc_ parsed

  static format-toitdoc_ toitdoc/Toitdoc -> string:
    lines := []
    toitdoc.sections.do: | section/DocSection |
      if section.title and section.title != "":
        lines.add "## $section.title"
        lines.add ""
      render-statements_ section.statements lines ""
    return (lines.join "\n").trim

  /**
  Renders a list of statements into the $lines list.

  The $prefix is prepended to each line (used for nested itemized lists).
  */
  static render-statements_ statements/List lines/List prefix/string -> none:
    statements.do: | statement/DocStatement |
      if statement is DocParagraph:
        paragraph := statement as DocParagraph
        text := render-expressions_ paragraph.expressions
        lines.add "$prefix$text"
        lines.add ""

      else if statement is DocCodeSection:
        code-section := statement as DocCodeSection
        lines.add "$(prefix)```"
        lines.add code-section.text
        lines.add "$(prefix)```"
        lines.add ""

      else if statement is DocItemized:
        itemized := statement as DocItemized
        itemized.items.do: | item/DocItem |
          item-lines := []
          render-statements_ item.statements item-lines ""
          item-text := (item-lines.join "\n").trim
          lines.add "$(prefix)- $item-text"
        lines.add ""

  /**
  Renders a list of expressions into a single string.
  */
  static render-expressions_ expressions/List -> string:
    parts := []
    expressions.do: | expr/DocExpression |
      if expr is DocText:
        parts.add (expr as DocText).text
      else if expr is DocCode:
        code := expr as DocCode
        parts.add "`$code.text`"
      else if expr is DocLink:
        link := expr as DocLink
        parts.add "[$link.text]($link.url)"
      else if expr is DocToitdocRef:
        ref := expr as DocToitdocRef
        parts.add "`$ref.text`"
    return parts.join ""
