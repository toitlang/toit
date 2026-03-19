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
    if toitdoc is not List: return ""
    sections := toitdoc as List
    if sections.is-empty: return ""

    lines := []
    sections.do: | section |
      if section is not Map: continue.do
      section-map := section as Map
      title := section-map.get "title"
      if title and title != "":
        lines.add "## $title"
        lines.add ""
      statements := section-map.get "statements"
      if statements is List:
        render-statements_ (statements as List) lines ""
    return (lines.join "\n").trim

  /**
  Renders a list of statements into the $lines list.

  The $prefix is prepended to each line (used for nested itemized lists).
  */
  static render-statements_ statements/List lines/List prefix/string -> none:
    statements.do: | statement |
      if statement is not Map: continue.do
      stmt := statement as Map
      object-type := stmt.get "object_type"

      if object-type == "statement_paragraph":
        text := render-expressions_ (stmt.get "expressions")
        lines.add "$prefix$text"
        lines.add ""

      else if object-type == "statement_code_section":
        code := stmt.get "text" --if-absent=: ""
        lines.add "$(prefix)```"
        lines.add "$code"
        lines.add "$(prefix)```"
        lines.add ""

      else if object-type == "statement_itemized":
        items := stmt.get "items"
        if items is List:
          (items as List).do: | item |
            if item is not Map: continue.do
            item-map := item as Map
            item-statements := item-map.get "statements"
            if item-statements is List:
              // Render the first statement inline with the bullet.
              item-lines := []
              render-statements_ (item-statements as List) item-lines ""
              item-text := (item-lines.join "\n").trim
              lines.add "$(prefix)- $item-text"
          lines.add ""

  /**
  Renders a list of expressions into a single string.
  */
  static render-expressions_ expressions -> string:
    if expressions == null: return ""
    if expressions is not List: return ""
    parts := []
    (expressions as List).do: | expr |
      if expr is not Map: continue.do
      expr-map := expr as Map
      object-type := expr-map.get "object_type"
      text := expr-map.get "text" --if-absent=: ""

      if object-type == "expression_text":
        parts.add text
      else if object-type == "expression_code":
        parts.add "`$text`"
      else if object-type == "expression_link":
        url := expr-map.get "url" --if-absent=: ""
        parts.add "[$text]($url)"
      else if object-type == "toitdocref":
        parts.add "`$text`"
      else:
        // Fallback: use text if present.
        if text != "":
          parts.add text

    return parts.join ""
