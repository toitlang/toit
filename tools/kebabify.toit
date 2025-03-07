// Copyright (C) 2023 Toitware ApS.
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
import host.pipe
import host.os
import host.file
import io
import semver
import system
import system show platform

REQUIRED-SDK-VERSION ::= "2.0.0-alpha.95"

main args:
  cmd := build-command
  cmd.run args

build-command --toitc-from-args/Lambda?=null -> cli.Command:
  cmd := cli.Command "kebabify"
      --help="""
        Migrates a project from snake-case to kebab-case.
        """

  jag-paragraph := ""
  toitc-options := []
  if not toitc-from-args:
    jag-paragraph = """

        Uses the Toit SDK that is available through `jag` by default.
        """
    toitc-options = [
      cli.Option "toitc"
          --help="The path to the toit.compile binary.",
    ]
  code-command := cli.Command "code"
      --help="""
        Migrates the given source files from snake-case ("foo_bar") to
        kebab-case ("foo-bar").
        $jag-paragraph"""
      --options=toitc-options + [
        cli.Flag "abort-on-error"
            --help="Abort the migration if a file has errors."
            --default=false
      ]
      --rest=[
        cli.Option "source"
            --help="The source file to migrate."
            --required
            --multi
      ]
      --run=:: migrate it (toitc-from-args ? toitc-from-args.call it : it["toitc"])
  cmd.add code-command

  files-command := cli.Command "files"
      --help="""
        Renames the given source files from snake-case ("foo_bar.toit") to
        kebab-case ("foo-bar.toit").

        If the 'git' flag is set, then the files are renamed using 'git mv'.

        On Posix machines the following command can be used to rename all
        files in a directory:

            find /path/to/directory \\
                -type d \\( -name .packages -o -name .git \\) -prune -o \\
                -type f -name '*.toit' \\
              | xargs kebab-migration files --git
        """
      --options=[
        cli.Flag "git"
            --help="Use 'git mv' to rename the files."
            --default=false
      ]
      --rest=[
        cli.Option "source"
            --help="The source file to migrate."
            --required
            --multi
      ]
      --run=:: rename-files it
  cmd.add files-command

  return cmd

migrate invocation/cli.Invocation toitc/string?:
  sources := invocation["source"]
  abort-on-error := invocation["abort-on-error"]

  ui := invocation.cli.ui

  if not toitc:
    toitc = find-toitc-from-jag --ui=ui

  check-toitc-version toitc --ui=ui

  migration-points := []
  sources.do: | source/string |
    pipe-ends := pipe.OpenPipe false
    stdout := pipe-ends.fd
    pipes := pipe.fork
        true  // Whether to use the path or not.
        pipe.PIPE-INHERITED
        stdout
        pipe.PIPE-INHERITED
        toitc
        [toitc, "-Xmigrate-dash-ids", "--analyze", source]
    child-process := pipes[3]
    reader := io.Reader.adapt pipe-ends
    reader.buffer-all
    out := reader.read-string reader.buffered-size
    pipe-ends.close
    exit-value := pipe.wait-for child-process
    if pipe.exit-signal exit-value:
      throw "Compiler crashed while migrating $source."
    if abort-on-error and (pipe.exit-code exit-value) != 0:
      throw "Compiler reported errors while migrating $source."

    lines := out.split "\n"
    lines.filter --in-place: it != ""
    migration-points.add-all lines

  if migration-points.is-empty: return

  migration-points.sort --in-place
  // Remove redundant migration points.
  point-count := 1
  for i := 1; i < migration-points.size; i++:
    if migration-points[i] == migration-points[i - 1]:
      continue
    migration-points[point-count++] = migration-points[i]
  migration-points.resize point-count

  ui.emit --info "Migrating $point-count locations."
  parsed-points := json.parse "[$(migration-points.join ",")]"

  file-points := {:}
  // The entries are of the form "[file, offset-from, offset-to, replacement]".
  parsed-points.do:
    file := it[0]
    (file-points.get file --init=: []).add it

  file-points.do: | path points |
    content/ByteArray := file.read-contents path

    // No need to sort as all replacements are of the same length and don't overlap.
    points.do: | point |
      from/int := point[1]
      to/int := point[2]
      replacement/string := point[3]
      content.replace from replacement.to-byte-array

    file.write-contents --path=path content

rename-files invocation/cli.Invocation:
  git := invocation["git"]
  sources := invocation["source"]

  sources.do: | path/string |
    new-path := build-kebab-path path
    if new-path == path: continue.do
    if git:
      pipe.backticks "git" "mv" path new-path
    else:
      file.rename path new-path

build-kebab-path path/string -> string:
  last-separator := path.index-of --last "/"
  if platform == system.PLATFORM-WINDOWS:
    last-separator = max last-separator (path.index-of --last "\\")

  if last-separator != -1:
    new-file-path := build-kebab-path path[last-separator + 1..]

    return "$path[..last-separator + 1]$new-file-path"

  bytes := path.to-byte-array
  for i := 1; i < bytes.size - 1; i++:
    // We only change '_' to '-' if it is surrounded by alphanumeric characters.
    c := bytes[i]
    if c != '_': continue
    previous := bytes[i - 1]
    next := bytes[i + 1]
    if previous == '-' or previous == '_': continue
    if next == '-' or next == '_': continue
    bytes[i] = '-'
  return "$(bytes.to-string)"

find-toitc-from-jag --ui/cli.Ui -> string:
  home := ?
  if platform == system.PLATFORM-WINDOWS:
    home = os.env.get "USERPROFILE"
  else:
    home = os.env.get "HOME"
  if not home:
    ui.abort "Could not find home directory."
  exe-extension := platform == system.PLATFORM-WINDOWS ? ".exe" : ""
  return "$home/.cache/jaguar/sdk/bin/toit.compile$exe-extension"

check-toitc-version toitc --ui/cli.Ui:
  version-line := pipe.backticks toitc "--version"
  if not version-line.starts-with "Toit version:":
    ui.abort "Could not get toit.compile version."
  parts := version-line.split ":"
  version-with-v := parts[1].trim
  version := version-with-v[1..]
  if ((semver.compare version REQUIRED-SDK-VERSION) < 0):
    ui.emit --error "The toit.compile version must be at least $REQUIRED-SDK-VERSION."
    ui.emit --error "(Using `$toitc` to invoke toit.compile.)"
    ui.abort
