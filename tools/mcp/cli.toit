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

import cli
import host.directory
import host.pipe
import system

import .cache show DocCache
import .lock-file-cache show LockFileCache
import .mcp show create-mcp-server
import .store show DocStore
import ..toitdoc.toitdoc as toitdoc-module

/**
Builds the CLI command for the MCP server.

The $toit-from-args and $sdk-path-from-args lambdas extract the toit
  executable path and SDK path from a CLI invocation, respectively.
*/
build-command --toit-from-args/Lambda --sdk-path-from-args/Lambda -> cli.Command:
  cmd := cli.Command "mcp"
      --help="""
        Start an MCP server for Toit documentation.

        This command starts an MCP (Model Context Protocol) server that
        provides Toit SDK and package documentation to AI coding assistants.

        The skills at https://github.com/toitlang/ai-instructions use this
        MCP server to provide Toit documentation to AI coding assistants.

        To use with Claude Code, add to .claude/settings.json:
          {
            "mcpServers": {
              "toit-docs": {
                "command": "toit",
                "args": ["tool", "mcp"]
              }
            }
          }

        For other MCP clients (Cursor, etc.), configure similarly with
        the command "toit tool mcp".

        The server communicates over stdin/stdout using JSON-RPC 2.0.
        Generated documentation is cached in ~/.cache/toit/ to avoid
        regeneration.
        """
      --options=[
        cli.Option "project-root"
            --help="Path to the project root. Defaults to the current directory."
            --type="dir",
      ]
      --run=:: | invocation/cli.Invocation |
        run-mcp invocation
            --toit=(toit-from-args.call invocation)
            --sdk-path=(sdk-path-from-args.call invocation)
  return cmd

/**
Runs the MCP server.

Starts with an empty $DocStore and lets the LLM load documentation
  on demand via the load_documentation tool.
*/
run-mcp invocation/cli.Invocation --toit/string --sdk-path/string?:
  project-root := invocation["project-root"]
  if not project-root: project-root = directory.cwd

  sdk-path = toitdoc-module.compute-sdk-path --sdk-path=sdk-path --toit=toit --ui=invocation.cli.ui

  cache := DocCache invocation.cli.cache
  store := DocStore
  lock-file-caches := {:}  // Map from project-root to LockFileCache.

  loader := :: | source/string name/string? path/string? |
    // Use the path as project root for packages if provided,
    //   otherwise fall back to the default project root.
    effective-root := path or project-root
    lock-file-cache := lock-file-caches.get effective-root
        --init=: LockFileCache effective-root
    generate-docs_ source name path
        --toit=toit
        --sdk-path=sdk-path
        --project-root=effective-root
        --cache=cache
        --lock-file-cache=lock-file-cache

  reader := pipe.stdin
  writer := pipe.stdout
  server := create-mcp-server
      --store=store
      --reader=reader
      --writer=writer
      --loader=loader
  server.run

/**
Generates documentation for the given $source type.

Checks the cache first for SDK and package sources.
Returns the parsed toitdoc JSON.
*/
generate-docs_ source/string name/string? path/string?
    --toit/string --sdk-path/string --project-root/string
    --cache/DocCache --lock-file-cache/LockFileCache -> Map:
  // Check cache for SDK and packages.
  cache-key/string? := null
  cache-project-root/string? := null
  if source == "sdk":
    cache-key = DocCache.sdk-key --version=system.vm-sdk-version
  else if source == "package" and name:
    version := lock-file-cache.resolve-version --url=name
    if version:
      cache-key = DocCache.package-key --id=name --version=version
      cache-project-root = project-root

  if cache-key:
    cache.put --key=cache-key --project-root=cache-project-root:
      generate-toitdoc_ source name path
          --toit=toit
          --sdk-path=sdk-path
          --project-root=project-root
          --lock-file-cache=lock-file-cache
    return cache.get --key=cache-key --project-root=cache-project-root

  return generate-toitdoc_ source name path
      --toit=toit
      --sdk-path=sdk-path
      --project-root=project-root
      --lock-file-cache=lock-file-cache

/**
Generates toitdoc JSON for the given source using the toitdoc library directly.
*/
generate-toitdoc_ source/string name/string? path/string?
    --toit/string --sdk-path/string --project-root/string
    --lock-file-cache/LockFileCache -> Map:
  if source == "sdk":
    return toitdoc-module.build-toitdoc
        --toit=toit
        --sdk-path=sdk-path
        --source="$sdk-path/lib/toit/lib"
        --for-sdk
        --exclude-pkgs
  else if source == "package":
    pkg-path := lock-file-cache.resolve-path --url=name
    return toitdoc-module.build-toitdoc
        --toit=toit
        --sdk-path=sdk-path
        --source=pkg-path
        --for-package
        --exclude-sdk
        --exclude-pkgs
  else if source == "project":
    project-path := path or project-root
    return toitdoc-module.build-toitdoc
        --toit=toit
        --sdk-path=sdk-path
        --source=project-path
        --exclude-sdk
        --exclude-pkgs
  else:
    throw "Unknown source: $source"
