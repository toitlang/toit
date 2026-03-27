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

  The $entries list contains maps with "name", "path", and "sub_libraries" keys.
  */
  static format-library-list entries/List -> string:
    lines := ["# Available Libraries"]
    if entries.is-empty:
      lines.add ""
      lines.add "No libraries found."
      return lines.join "\n"

    entries.do: | entry/Map |
      name := entry["name"]
      sub-libraries := entry["sub_libraries"]
      lines.add ""
      lines.add "## $name"
      if sub-libraries is List and not (sub-libraries as List).is-empty:
        lines.add "Sub-libraries: $((sub-libraries as List).join ", ")"

    return lines.join "\n"

  /**
  Formats search results as Markdown.

  The $search-result map has "results" (list of match maps with "name",
    "kind", "library", "summary" keys) and "total" (total match count).
  The $query is shown in the heading.
  */
  static format-search-results search-result/Map --query/string -> string:
    results := search-result["results"] as List
    total := search-result["total"] as int
    lines := ["# Search Results for \"$query\""]
    if results.is-empty:
      lines.add ""
      lines.add "No results found."
      return lines.join "\n"

    lines.add ""
    lines.add "Showing $(results.size) of $total results."
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
    signature := format-signature_ (element.get "parameters")
    header := signature != "" ? "# $kind $name $signature" : "# $kind $name"
    lines := [header]

    toitdoc := element.get "toitdoc"
    doc := format-toitdoc toitdoc
    if doc != "":
      lines.add ""
      lines.add doc

    overloads := element.get "overloads"
    if overloads is List and (overloads as List).size > 1:
      lines.add ""
      lines.add "## Overloads"
      (overloads as List).do: | overload/Map |
        overload-sig := format-signature_ (overload.get "parameters")
        lines.add ""
        lines.add "### $name $overload-sig"
        overload-doc := format-toitdoc (overload.get "toitdoc")
        if overload-doc != "":
          lines.add ""
          lines.add overload-doc

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
        member-sig := format-signature_ (member.get "parameters")
        lines.add ""
        if member-sig != "":
          lines.add "### $member-name $member-sig ($member-kind)"
        else:
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
  Formats a parameter list into a Toit-style signature string.

  Returns an empty string if $params is null or empty.
  */
  static format-signature_ params -> string:
    if params is not List: return ""
    param-list := params as List
    if param-list.is-empty: return ""
    parts := []
    param-list.do: | param |
      if param is not Map: continue.do
      p := param as Map
      name := p["name"]
      is-named := p.get "is_named"
      is-block := p.get "is_block"
      type-str := format-type_ (p.get "type")
      if is-block == true:
        parts.add "[--$name]"
      else if is-named == true:
        if type-str != "":
          parts.add "--$name/$type-str"
        else:
          parts.add "--$name"
      else:
        if type-str != "":
          parts.add "$name/$type-str"
        else:
          parts.add name
    return parts.join " "

  /** Formats a type JSON map into a type name string. */
  static format-type_ type -> string:
    if type is not Map: return ""
    t := type as Map
    if (t.get "is_any") == true: return "any"
    if (t.get "is_none") == true: return "none"
    ref := t.get "reference"
    if ref is Map: return (ref as Map).get "name" --if-absent=: ""
    return ""

  /** Renders a list of expressions into a single string. */
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
