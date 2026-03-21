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
    DocExpression
    DocParagraph
    DocSection
    DocText
    DocToitdocRef
    Toitdoc

/**
Searchable index over toitdoc JSON data.

Parses the JSON produced by the toitdoc builder into a flat list of
  entries that can be searched by name.
*/
class DocIndex:
  /** The parsed top-level JSON map. */
  json_ /Map

  /**
  Flat list of indexed entries.

  Each entry is a map with keys: "name", "kind", "library", "summary",
    "json", and optionally "parent" (for members).
  */
  entries_ /List

  /**
  Builds an index from parsed toitdoc JSON (a $Map, the top-level object).

  Walks all libraries, modules, and their elements to build a flat
    searchable index.
  */
  constructor json/Map:
    json_ = json
    entries_ = []
    libraries := json.get "libraries"
    if libraries:
      libraries.do: | name/string library/Map |
        index-library_ library (library.get "path" --if-absent=: [name])

  /**
  Returns a list of all libraries with their top-level summary.

  Each entry is a map with "name", "path", and "modules" keys.
  */
  list-libraries -> List:
    result := []
    libraries := json_.get "libraries"
    if libraries:
      libraries.do: | _ library/Map |
        collect-libraries_ library result
    return result

  /**
  Searches for elements matching the $query string.

  Performs a case-insensitive substring match on element names.
  Returns up to $max-results matches. Each match is a map with
    "name", "kind", "library", and "summary" keys.
  */
  search --query/string --max-results/int=10 -> List:
    lower-query := query.to-ascii-lower
    result := []
    entries_.do: | entry/Map |
      if result.size >= max-results: return result
      name := entry["name"]
      if (name.to-ascii-lower.contains lower-query):
        result.add {
          "name": name,
          "kind": entry["kind"],
          "library": entry["library"],
          "summary": entry["summary"],
        }
    return result

  /**
  Retrieves full documentation for a specific element.

  The $library-path is dot-separated, e.g. "core.collections".
  The $element is the element name, optionally dot-separated for members,
    e.g. "List" or "List.add".
  If $include-inherited is true, inherited members are included.
  Returns null if not found.
  */
  get-element --library-path/string --element/string="" --include-inherited/bool=false -> Map?:
    library := find-library_ library-path
    if not library: return null

    // If no element specified, return library info.
    if element == "":
      modules := library.get "modules"
      module-names := []
      if modules:
        modules.do: | name/string _ | module-names.add name
      return {
        "name": library["name"],
        "kind": "library",
        "library": library-path,
        "toitdoc": null,
        "members": module-names.map: | name | {"name": name, "kind": "module"},
      }

    // Split element on "." to handle member access.
    parts := element.split "."
    element-name := parts[0]
    member-name := parts.size > 1 ? parts[1] : null

    // Search all modules in the library for the element.
    modules := library.get "modules"
    if not modules: return null

    modules.do: | _ module/Map |
      found := find-in-module_ module element-name
      if found:
        if member-name:
          return find-member-in-class_ found member-name --include-inherited=include-inherited
        kind := element-kind_ found
        result := {
          "name": found["name"],
          "kind": kind,
          "library": library-path,
          "toitdoc": found.get "toitdoc",
          "members": [],
        }
        if kind == "class" or kind == "interface" or kind == "mixin":
          result["members"] = collect-class-members_ found --include-inherited=include-inherited
        return result
    return null

  // ----- Private helpers -----

  /**
  Indexes all elements within a single library, recursively processing
    sub-libraries.
  */
  index-library_ library/Map path/List -> none:
    library-path := path.join "."

    // Index modules.
    modules := library.get "modules"
    if modules:
      modules.do: | _ module/Map |
        if module.get "is_private": continue.do
        index-module_ module library-path

    // Recurse into sub-libraries.
    sub-libraries := library.get "libraries"
    if sub-libraries:
      sub-libraries.do: | name/string sub-library/Map |
        sub-path := sub-library.get "path" --if-absent=: path + [name]
        index-library_ sub-library sub-path

  /**
  Indexes all elements within a single module.
  */
  index-module_ module/Map library-path/string -> none:
    INDEX-LIST ::= : | list/List kind/string |
      list.do: | entry/Map |
        if entry.get "is_private": continue.do
        entries_.add {
          "name": entry["name"],
          "kind": kind,
          "library": library-path,
          "summary": extract-summary_ (entry.get "toitdoc"),
          "json": entry,
        }

    // Classes, interfaces, mixins (both direct and exported).
    ["classes", "export_classes"].do: | key |
      list := module.get key
      if list: INDEX-LIST.call list "class"

    ["interfaces", "export_interfaces"].do: | key |
      list := module.get key
      if list: INDEX-LIST.call list "interface"

    ["mixins", "export_mixins"].do: | key |
      list := module.get key
      if list: INDEX-LIST.call list "mixin"

    // Functions.
    ["functions", "export_functions"].do: | key |
      list := module.get key
      if list: INDEX-LIST.call list "function"

    // Globals.
    ["globals", "export_globals"].do: | key |
      list := module.get key
      if list: INDEX-LIST.call list "global"

    // Index class members.
    ["classes", "export_classes", "interfaces", "export_interfaces",
     "mixins", "export_mixins"].do: | key |
      list := module.get key
      if list:
        list.do: | cls/Map |
          if cls.get "is_private": continue.do
          index-class-members_ cls library-path

  /**
  Indexes the members of a class (methods, fields, constructors, etc.).
  */
  index-class-members_ cls/Map library-path/string -> none:
    structure := cls.get "structure"
    if not structure: return
    parent-name := cls["name"]

    MEMBER-KINDS ::= {
      "methods": "method",
      "constructors": "constructor",
      "factories": "constructor",
      "statics": "method",
      "fields": "field",
    }

    MEMBER-KINDS.do: | key/string kind/string |
      list := structure.get key
      if list:
        list.do: | member/Map |
          if member.get "is_private": continue.do
          entries_.add {
            "name": "$parent-name.$(member["name"])",
            "kind": kind,
            "library": library-path,
            "summary": extract-summary_ (member.get "toitdoc"),
            "json": member,
            "parent": parent-name,
          }

  /**
  Collects library entries recursively into the $result list.
  */
  collect-libraries_ library/Map result/List -> none:
    modules := library.get "modules"
    module-names := []
    if modules:
      modules.do: | name/string _ | module-names.add name

    result.add {
      "name": library["name"],
      "path": library.get "path" --if-absent=: [library["name"]],
      "modules": module-names,
    }

    sub-libraries := library.get "libraries"
    if sub-libraries:
      sub-libraries.do: | _ sub-library/Map |
        collect-libraries_ sub-library result

  /**
  Finds a library by dot-separated path.

  Returns null if the library is not found.
  */
  find-library_ library-path/string -> Map?:
    parts := library-path.split "."
    libraries := json_.get "libraries"
    if not libraries: return null

    current := libraries.get parts[0]
    if not current: return null

    for i := 1; i < parts.size; i++:
      sub-libraries := current.get "libraries"
      if not sub-libraries: return null
      current = sub-libraries.get parts[i]
      if not current: return null

    return current

  /**
  Finds a named element (class, function, global, etc.) within a module.

  Returns the JSON map for the element, or null if not found.
  */
  find-in-module_ module/Map name/string -> Map?:
    KEYS ::= [
      "classes", "export_classes",
      "interfaces", "export_interfaces",
      "mixins", "export_mixins",
      "functions", "export_functions",
      "globals", "export_globals",
    ]
    KEYS.do: | key |
      list := module.get key
      if list:
        list.do: | entry/Map |
          if entry["name"] == name: return entry
    return null

  /**
  Finds a member within a class and returns its documentation.

  Returns null if not found.
  */
  find-member-in-class_ cls/Map member-name/string --include-inherited/bool=false -> Map?:
    structure := cls.get "structure"
    if not structure: return null

    MEMBER-KEYS ::= ["methods", "constructors", "factories", "statics", "fields"]
    MEMBER-KEYS.do: | key/string |
      list := structure.get key
      if list:
        list.do: | member/Map |
          if member["name"] == member-name:
            kind := ?
            if key == "fields":
              kind = "field"
            else if key == "constructors" or key == "factories":
              kind = "constructor"
            else:
              kind = "method"
            return {
              "name": "$(cls["name"]).$member-name",
              "kind": kind,
              "library": "",
              "toitdoc": member.get "toitdoc",
              "members": [],
              "parameters": member.get "parameters",
            }
    return null

  /**
  Collects all members of a class into a list of member maps.

  Each member has "name", "kind", "toitdoc", and "parameters" keys.
  */
  collect-class-members_ cls/Map --include-inherited/bool=false -> List:
    result := []
    structure := cls.get "structure"
    if not structure: return result

    add-members := : | list/List kind/string |
      list.do: | member/Map |
        if member.get "is_private": continue.do
        if not include-inherited and (member.get "is_inherited"): continue.do
        entry := {
          "name": member["name"],
          "kind": kind,
          "toitdoc": member.get "toitdoc",
        }
        params := member.get "parameters"
        if params: entry["parameters"] = params
        result.add entry

    methods := structure.get "methods"
    if methods: add-members.call methods "method"

    constructors := structure.get "constructors"
    if constructors: add-members.call constructors "constructor"

    factories := structure.get "factories"
    if factories: add-members.call factories "constructor"

    statics := structure.get "statics"
    if statics: add-members.call statics "method"

    fields := structure.get "fields"
    if fields: add-members.call fields "field"

    return result

  /**
  Determines the kind string for an element JSON map.
  */
  element-kind_ element/Map -> string:
    object-type := element.get "object_type"
    if object-type == "class":
      // Classes, interfaces, and mixins all use object_type "class"
      // but have a "kind" field.
      return element.get "kind" --if-absent=: "class"
    if object-type == "function": return "function"
    if object-type == "global": return "global"
    return object-type or "unknown"

  /**
  Extracts the first paragraph text from a toitdoc JSON structure.

  Returns an empty string if no text is found.
  */
  static extract-summary_ toitdoc -> string:
    parsed := Toitdoc.from-json toitdoc
    if not parsed: return ""

    sections := parsed.sections
    if sections.is-empty: return ""

    first-section := sections[0] as DocSection
    if first-section.statements.is-empty: return ""

    first-statement := first-section.statements[0]
    if first-statement is not DocParagraph: return ""
    paragraph := first-statement as DocParagraph

    // Concatenate all text expressions in the first paragraph.
    parts := []
    paragraph.expressions.do: | expr/DocExpression |
      if expr is DocText:
        parts.add (expr as DocText).text
      else if expr is DocCode:
        parts.add (expr as DocCode).text
      else if expr is DocToitdocRef:
        parts.add (expr as DocToitdocRef).text
    return parts.join ""
