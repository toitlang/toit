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

import encoding.json as json-codec
import host.file
import io

import .formatter show DocFormatter
import .server show McpServer
import .store show DocStore

DEFAULT-MAX-RESULTS ::= 10

/**
Creates an MCP server backed by the given $store.

The $loader is an optional lambda for generating documentation on demand.
  It is called as `loader.call source name path` where source is "sdk",
  "package", or "project", name is the package ID, and path is the project
  path. It must return a parsed toitdoc JSON $Map. The loader is responsible
  for caching if desired.
*/
create-mcp-server --store/DocStore --reader/io.Reader --writer/io.Writer
    --loader/Lambda?=null -> McpServer:
  tools := [
    {
      "name": "load_documentation",
      "description": """
        Loads documentation for a Toit source. Must be called before searching.
        Use source="sdk" for the Toit SDK, source="package" with a package ID
        (e.g. "github.com/toitlang/pkg-http") for a package, source="project"
        for the current project's own code, or source="file" with a path to
        load pre-generated toitdoc JSON.""",
      "inputSchema": {
        "type": "object",
        "properties": {
          "source": {
            "type": "string",
            "enum": ["sdk", "package", "project", "file"],
            "description": "The type of documentation to load",
          },
          "name": {
            "type": "string",
            "description": "Package ID (for source=package) or label (for source=file)",
          },
          "path": {
            "type": "string",
            "description": "File path (for source=file), project path (for source=project), or project root containing the package.lock (for source=package, defaults to the server's project root)",
          },
        },
        "required": ["source"],
      },
    },
    {
      "name": "list_sources",
      "description": "Lists all loaded documentation sources with their scope labels.",
      "inputSchema": {
        "type": "object",
        "properties": {:},
      },
    },
    {
      "name": "list_libraries",
      "description": "Lists available Toit libraries with their sub-libraries. Optionally filter by scope.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "scope": {"type": "string", "description": "Restrict to a specific loaded source (e.g. 'sdk', a package ID). Omit to list from all sources."},
        },
      },
    },
    {
      "name": "search_docs",
      "description": "Searches Toit documentation for classes, functions, globals, and methods matching a query. Use get_element to get full documentation for a result. Returns results with a total count.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": {"type": "string", "description": "Search term to match against element names (or documentation if search_docs is true)"},
          "scope": {"type": "string", "description": "Restrict to a specific loaded source. Omit to search all."},
          "max_results": {"type": "integer", "description": "Maximum number of results to return (default: $DEFAULT-MAX-RESULTS)"},
          "offset": {"type": "integer", "description": "Number of results to skip for paging (default: 0)"},
          "exact": {"type": "boolean", "description": "If true, match element names exactly instead of substring match (default: false)"},
          "search_docs": {"type": "boolean", "description": "If true, also search in documentation text (default: false)"},
        },
        "required": ["query"],
      },
    },
    {
      "name": "get_element",
      "description": "Gets full documentation for a specific Toit element. Use the library path from search results. For class members, use dotted notation like 'List.add'.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "library_path": {"type": "string", "description": "Dot-separated library path, e.g. 'core.collections'"},
          "element": {"type": "string", "description": "Element name, e.g. 'List' or 'List.add'"},
          "scope": {"type": "string", "description": "Restrict to a specific loaded source. Omit to search all."},
          "include_inherited": {"type": "boolean", "description": "Include inherited members (default: false)"},
        },
        "required": ["library_path"],
      },
    },
  ]

  tool-handlers := {
    "load_documentation": :: | args/Map |
      handle-load-documentation_ store args --loader=loader,
    "list_sources": :: | args/Map |
      scopes := store.list-scopes
      if scopes.is-empty:
        "No documentation loaded. Use load_documentation to load SDK, package, or project docs."
      else:
        lines := scopes.map: "- $it"
        "Loaded sources:\n$(lines.join "\n")",
    "list_libraries": :: | args/Map |
      scope := args.get "scope"
      DocFormatter.format-library-list (store.list-libraries --scope=scope),
    "search_docs": :: | args/Map |
      query := args["query"] as string
      scope := args.get "scope"
      max-results := args.get "max_results" --if-absent=: DEFAULT-MAX-RESULTS
      offset := args.get "offset" --if-absent=: 0
      exact := (args.get "exact") == true
      search-docs := (args.get "search_docs") == true
      search-result := store.search
          --query=query
          --scope=scope
          --max-results=max-results
          --offset=offset
          --exact=exact
          --search-docs=search-docs
      DocFormatter.format-search-results search-result --query=query,
    "get_element": :: | args/Map |
      library-path := args["library_path"] as string
      element := (args.get "element" --if-absent=: "") as string
      scope := args.get "scope"
      include-inherited := (args.get "include_inherited") == true
      result := store.get-element
          --library-path=library-path
          --element=element
          --scope=scope
          --include-inherited=include-inherited
      if result:
        DocFormatter.format-element result
      else:
        "Element not found: $element in $(library-path)",
  }

  return McpServer --reader=reader --writer=writer --tools=tools --tool-handlers=tool-handlers

/**
Handles a load_documentation tool call.

Loads documentation into the $store based on the source type in $args.
*/
handle-load-documentation_ store/DocStore args/Map --loader/Lambda? -> string:
  source/string := args["source"]
  name/string? := args.get "name"
  path/string? := args.get "path"

  if source == "file":
    if not path: return "Error: 'path' is required for source='file'."
    label := name or path
    content := file.read-contents path
    doc-json := json-codec.decode content
    store.add --scope=label --json=doc-json
    return "Loaded documentation from file: $label"

  if not loader:
    return "Error: Documentation generation is not available in this context."

  scope-label/string := ?
  if source == "sdk":
    scope-label = "sdk"
  else if source == "package":
    if not name: return "Error: 'name' is required for source='package'."
    scope-label = name
  else if source == "project":
    scope-label = "project"
  else:
    return "Error: Unknown source type: $source"

  doc-json := loader.call source name path
  store.add --scope=scope-label --json=doc-json
  return "Loaded $source documentation: $scope-label"
