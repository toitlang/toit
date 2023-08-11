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
import reader show BufferedReader
import semver

REQUIRED_SDK_VERSION ::= "2.0.0-alpha.95"

main args:
  cmd := cli.Command "root"
      --long_help="""
        Migrates a project from snake-case to kebab-case.
        """

  code_command := cli.Command "code"
      --long_help="""
        Migrates the given source files from snake-case ("foo_bar") to
        kebab-case ("foo-bar").

        By default uses the Toit SDK that is available through `jag`.
        """
      --options=[
        cli.Option "toitc"
            --short_help="The path to the toit.compile binary.",
        cli.Flag "abort-on-error"
            --short_help="Abort the migration if a file has errors."
            --default=false
      ]
      --rest=[
        cli.Option "source"
            --short_help="The source file to migrate."
            --required
            --multi
      ]
      --run=:: migrate it
  cmd.add code_command

  files_command := cli.Command "files"
      --long_help="""
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
            --short_help="Use 'git mv' to rename the files."
            --default=false
      ]
      --rest=[
        cli.Option "source"
            --short_help="The source file to migrate."
            --required
            --multi
      ]
      --run=:: rename_files it
  cmd.add files_command

  cmd.run args

migrate parsed/cli.Parsed:
  toitc := parsed["toitc"]
  sources := parsed["source"]
  abort_on_error := parsed["abort-on-error"]

  if not toitc:
    toitc = find_toitc_from_jag

  check_toitc_version toitc

  migration_points := []
  sources.do: | source/string |
    pipe_ends := pipe.OpenPipe false
    stdout := pipe_ends.fd
    pipes := pipe.fork
        true  // Whether to use the path or not.
        pipe.PIPE_INHERITED
        stdout
        pipe.PIPE_INHERITED
        toitc
        [toitc, "-Xmigrate-dash-ids", "--analyze", source]
    child_process := pipes[3]
    reader := BufferedReader pipe_ends
    reader.buffer_all
    out := reader.read_string reader.buffered
    exit_value := pipe.wait_for child_process
    if pipe.exit_signal exit_value:
      throw "Compiler crashed while migrating $source."
    if abort_on_error and (pipe.exit_code exit_value) != 0:
      throw "Compiler reported errors while migrating $source."

    lines := out.split "\n"
    lines.filter --in_place: it != ""
    migration_points.add_all lines

  if migration_points.is_empty: return

  migration_points.sort --in_place
  // Remove redundant migration points.
  point_count := 1
  for i := 1; i < migration_points.size; i++:
    if migration_points[i] == migration_points[i - 1]:
      continue
    migration_points[point_count++] = migration_points[i]
  migration_points.resize point_count

  print "Migrating $point_count locations."
  parsed_points := json.parse "[$(migration_points.join ",")]"

  file_points := {:}
  // The entries are of the form "[file, offset-from, offset-to, replacement]".
  parsed_points.do:
    file := it[0]
    (file_points.get file --init=: []).add it

  file_points.do: | path points |
    content/ByteArray := file.read_content path

    // No need to sort as all replacements are of the same length and don't overlap.
    points.do: | point |
      from/int := point[1]
      to/int := point[2]
      replacement/string := point[3]
      content.replace from replacement.to_byte_array

    file.write_content --path=path content

rename_files parsed/cli.Parsed:
  git := parsed["git"]
  sources := parsed["source"]

  sources.do: | path/string |
    new_path := build_kebab_path path
    if new_path == path: continue.do
    if git:
      pipe.backticks "git" "mv" path new_path
    else:
      file.rename path new_path

build_kebab_path path/string -> string:
  last_separator := path.index_of --last "/"
  if platform == PLATFORM_WINDOWS:
    last_separator = max last_separator (path.index_of --last "\\")

  if last_separator != -1:
    new_file_path := build_kebab_path path[last_separator + 1..]

    return "$path[..last_separator + 1]$new_file_path"

  bytes := path.to_byte_array
  for i := 1; i < bytes.size - 1; i++:
    // We only change '_' to '-' if it is surrounded by alphanumeric characters.
    c := bytes[i]
    if c != '_': continue
    previous := bytes[i - 1]
    next := bytes[i + 1]
    if previous == '-' or previous == '_': continue
    if next == '-' or next == '_': continue
    bytes[i] = '-'
  return "$(bytes.to_string)"

find_toitc_from_jag -> string:
  home := ?
  if platform == PLATFORM_WINDOWS:
    home = os.env.get "USERPROFILE"
  else:
    home = os.env.get "HOME"
  if not home:
    print "Could not find home directory."
    exit 1
  exe_extension := platform == PLATFORM_WINDOWS ? ".exe" : ""
  return "$home/.cache/jaguar/sdk/bin/toit.compile$exe_extension"

check_toitc_version toitc:
  version_line := pipe.backticks toitc "--version"
  if not version_line.starts_with "Toit version:":
    print "Could not get toit.compile version."
    exit 1
  parts := version_line.split ":"
  version_with_v := parts[1].trim
  version := version_with_v[1..]
  if ((semver.compare version REQUIRED_SDK_VERSION) < 0):
    print "The toit.compile version must be at least $REQUIRED_SDK_VERSION."
    exit 1
