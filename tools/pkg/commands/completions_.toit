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
import encoding.yaml
import fs
import host.file
import log

import ..project.specification
import ..registry
import ..registry.description

/**
Completion callbacks for the pkg commands.

Completion callbacks run while the user is waiting for the shell to
  react to a tab-press. Shells don't interrupt slow completion commands,
  so callbacks must be fast, and they must be silent, since stdout is
  reserved for the completion protocol.

Most importantly, callbacks must never go to the network: only registry
  data that is already available locally is used. If no local data is
  available, no candidates are produced.

Any error simply leads to an empty candidate list.
*/

/**
The maximum time a completion callback may take.

If a callback exceeds this limit, the completion is abandoned and no
  candidates are produced. This way a bug in a callback (like an
  accidental network access) blocks the user's prompt for a bounded
  time instead of requiring a ctrl-c.

The limit is generous: loading the description cache of a big registry
  can take more than a second on slow machines, and slow-but-successful
  completions are still better than none.
*/
COMPLETION-TIMEOUT-MS_ ::= 5_000

/**
Runs the $block and returns its result.

Returns an empty list if the block throws or takes longer than
  $COMPLETION-TIMEOUT-MS_.

Silences the default logger: the completion candidates are printed to
  stdout, so any library logging (like the file-lock logging of the
  cache) would corrupt the completion output.
*/
guarded_ [block] -> List:
  log.set-default (log.default.with-level log.FATAL-LEVEL)
  result := []
  catch:
    with-timeout --ms=COMPLETION-TIMEOUT-MS_:
      result = block.call
  return result

/**
Loads the registries for completion purposes.

The registries are never synchronized, and all output is suppressed.
*/
completion-registries_ -> Registries:
  ui := cli.Ui.human --level=cli.Ui.SILENT-LEVEL
  return Registries --ui=ui --no-auto-sync

/**
Returns a map from package URL to the cached $Description with the
  highest version for that URL.

Registries that are not cached locally are skipped: loading them would
  need to go to the network.
*/
cached-latest-descriptions_ registries/Registries -> Map:
  result := {:}
  registries.registries.do --values: | registry/Registry |
    if not registry.is-cached: continue.do
    registry.list-all-descriptions.do: | description/Description |
      existing/Description? := result.get description.url
      if not existing or existing.version < description.version:
        result[description.url] = description
  return result

/**
Returns the URLs of the cached packages that the given $name-or-url
  identifies.

Uses the same matching rules as 'pkg install': a package matches if its
  name is equal to $name-or-url, or if its URL is equal to, or ends
  with "/$name-or-url".
*/
matching-urls_ registries/Registries name-or-url/string -> List:
  result := []
  (cached-latest-descriptions_ registries).do: | url/string description/Description |
    if description.name == name-or-url or url == name-or-url or url.ends-with "/$name-or-url":
      result.add url
  return result

/**
Returns the sorted version strings of all cached descriptions for the
  given $url, highest version first.
*/
cached-versions_ registries/Registries url/string -> List:
  versions := {}
  registries.registries.do --values: | registry/Registry |
    if not registry.is-cached: continue.do
    if registry-versions := registry.retrieve-versions url:
      versions.add-all registry-versions
  sorted := List.from versions
  sorted.sort --in-place
  result := []
  sorted.do --reversed: result.add "$it"
  return result

/**
Returns a single-line variant of the given description $text suitable
  as completion-candidate description.

The completion protocol is line-based and uses tabs as separators, so
  the result must not contain newlines or tabs. Shells show the
  description next to the candidate, so only the beginning is useful.
*/
short-description_ text/string? -> string?:
  if not text: return null
  newline-index := text.index-of "\n"
  if newline-index >= 0: text = text[..newline-index]
  text = text.replace --all "\t" " "
  text = text.trim
  MAX ::= 80
  if text.size > MAX:
    // Don't cut into the middle of a UTF-8 sequence.
    cut := MAX - 3
    while cut > 0 and (text.at --raw cut) & 0b1100_0000 == 0b1000_0000: cut--
    text = "$(text[..cut])..."
  return text.is-empty ? null : text

/**
Completes package names and URLs for commands that take a package
  identifier, like 'pkg install'.

If the prefix already contains a '@', completes the version part
  instead.

If the $skip-if-flag option has been provided on the command line, no
  candidates are produced. This is used by 'pkg install' to fall back
  to the shell's file completion when '--local' was given.
*/
complete-packages context/cli.CompletionContext --skip-if-flag/string?=null -> List:
  return guarded_:
    complete-packages_ context --skip-if-flag=skip-if-flag

complete-packages_ context/cli.CompletionContext --skip-if-flag/string? -> List:
  if skip-if-flag and (context.seen-options.contains skip-if-flag): return []

  registries := completion-registries_

  at-index := context.prefix.index-of "@"
  if at-index >= 0:
    // Complete 'name@version'.
    name := context.prefix[..at-index]
    result := []
    (matching-urls_ registries name).do: | url/string |
      (cached-versions_ registries url).do: | version/string |
        result.add (cli.CompletionCandidate "$name@$version")
    return result

  result := []
  names := {:}  // Package name to list of URLs.
  latest := cached-latest-descriptions_ registries
  latest.do: | url/string description/Description |
    result.add (cli.CompletionCandidate url --description=(short-description_ description.description))
    (names.get description.name --init=: []).add url
  names.do: | name/string urls/List |
    if urls.size != 1:
      // The name is ambiguous; the URL candidates are the only way to
      // uniquely identify these packages.
      continue.do
    description/Description := latest[urls[0]]
    result.add (cli.CompletionCandidate name --description=(short-description_ description.description))
  return result

/**
Completes package URLs, like for 'pkg describe'.
*/
complete-package-urls context/cli.CompletionContext -> List:
  return guarded_:
    result := []
    (cached-latest-descriptions_ completion-registries_).do: | url/string description/Description |
      result.add (cli.CompletionCandidate url --description=(short-description_ description.description))
    result

/**
Completes the versions of the package that was given as value for the
  rest option $url-option earlier on the command line.
*/
complete-package-versions context/cli.CompletionContext --url-option/string -> List:
  return guarded_:
    seen/List? := context.seen-options.get url-option
    if not seen or seen.is-empty: continue.guarded_ []
    registries := completion-registries_
    urls := matching-urls_ registries seen.last
    result := []
    urls.do: | url/string |
      (cached-versions_ registries url).do: | version/string |
        result.add (cli.CompletionCandidate version)
    result

/**
Completes the names of the configured registries.
*/
complete-registry-names context/cli.CompletionContext -> List:
  return guarded_:
    result := []
    completion-registries_.registries.do: | name/string registry/Registry |
      result.add (cli.CompletionCandidate name --description=registry.to-string)
    result

/**
Completes the prefixes of the packages that are installed in the
  current project, like for 'pkg uninstall'.

The project root is taken from the $project-root-option if it was
  provided on the command line, and defaults to the current directory.
*/
complete-dependency-prefixes context/cli.CompletionContext --project-root-option/string -> List:
  return guarded_:
    roots/List? := context.seen-options.get project-root-option
    root := (roots and not roots.is-empty) ? roots.last : "."
    contents := file.read-contents (fs.join root Specification.FILE-NAME)
    decoded := yaml.decode contents
    if decoded is not Map: continue.guarded_ []
    dependencies := decoded.get "dependencies"
    if dependencies is not Map: continue.guarded_ []
    result := []
    dependencies.do: | prefix/string entry |
      target := entry is Map
          ? (entry.get "url" or entry.get "path")
          : null
      result.add (cli.CompletionCandidate "$prefix" --description=(target and "$target"))
    result
