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
import encoding.json
import host.directory
import host.file
import host.pipe
import io
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

  loader := :: | source/string name/any path/any |
    // Use the path as project root for packages if provided,
    //   otherwise fall back to the default project root.
    effective-root := path is string ? (path as string) : project-root
    lock-file-cache := lock-file-caches.get effective-root
        --init=: LockFileCache effective-root
    generate-docs_ source name path
        --toit=toit
        --sdk-path=sdk-path
        --project-root=effective-root
        --cache=cache
        --lock-file-cache=lock-file-cache

  reader := io.Reader.adapt pipe.stdin
  writer := io.Writer.adapt pipe.stdout
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
generate-docs_ source/string name/any path/any
    --toit/string --sdk-path/string --project-root/string
    --cache/DocCache --lock-file-cache/LockFileCache -> Map:
  // Check cache for SDK and packages.
  cache-key/string? := null
  cache-project-root/string? := null
  if source == "sdk":
    cache-key = DocCache.sdk-key --version=system.vm-sdk-version
  else if source == "package" and name is string:
    version := lock-file-cache.resolve-version --url=(name as string)
    if version:
      cache-key = DocCache.package-key --id=(name as string) --version=version
      cache-project-root = project-root

  if cache-key:
    cache.put --key=cache-key --project-root=cache-project-root:
      generate-toitdoc_ source name path
          --toit=toit
          --sdk-path=sdk-path
          --project-root=project-root
          --lock-file-cache=lock-file-cache
    cached := cache.get --key=cache-key --project-root=cache-project-root
    if cached: return cached

  return generate-toitdoc_ source name path
      --toit=toit
      --sdk-path=sdk-path
      --project-root=project-root
      --lock-file-cache=lock-file-cache

/**
Runs `toit doc build` to generate toitdoc JSON for the given source.
*/
generate-toitdoc_ source/string name/any path/any
    --toit/string --sdk-path/string --project-root/string
    --lock-file-cache/LockFileCache -> Map:
  tmp-dir := directory.mkdtemp "/tmp/toitdoc-mcp-"
  try:
    output := "$tmp-dir/toitdoc.json"
    args := [toit, "doc", "build", "-o", output]

    if source == "sdk":
      args.add-all ["--sdk", "--exclude-pkgs"]
    else if source == "package":
      pkg-path := lock-file-cache.resolve-path --url=(name as string)
      args.add-all ["--package", "--exclude-sdk", "--exclude-pkgs", pkg-path]
    else if source == "project":
      project-path := path ? (path as string) : project-root
      args.add-all ["--exclude-sdk", "--exclude-pkgs", project-path]
    else:
      throw "Unknown source: $source"

    pipe.run-program args
    content := file.read-contents output
    return json.decode content
  finally:
    directory.rmdir --recursive tmp-dir
