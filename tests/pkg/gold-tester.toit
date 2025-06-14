// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli show Cli Ui Cache Config
import cli.ui as cli-pkg
import cli.test show TestUi TestAbort
import encoding.json
import encoding.yaml
import expect show *
import fs
import host.directory
import host.file
import host.pipe
import host.os
import http
import io
import monitor
import net
import net.tcp
import system

import .utils_
import ...tools.pkg as pkg


with-tmp-dir [block]:
  tmp-dir := directory.mkdtemp "/tmp/test-"
  // On macos the '/tmp' directory is a symlink to '/private/tmp', so we
  // resolve the real path to avoid issues with the gold files not having the
  // correct paths.
  tmp-dir = directory.realpath tmp-dir
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

class RunResult_:
  stdout/string
  stderr/string
  exit-value/int

  constructor --.stdout --.stderr --.exit-value:

  exit-code -> int:
    if (exit-value & pipe.PROCESS-SIGNALLED_) != 0:
      // Process crashed.
      exit-signal := pipe.exit-signal exit-value
      return -exit-signal
    return pipe.exit-code exit-value

  full-output -> string:
    result := stdout.replace --all "\r" ""
    if result != "" and not result.ends-with "\n":
      result += "\n <Missing newline at end of stdout> \n"
    if stderr != "":
      result += "\nSTDERR---\n" + (stderr.replace --all "\r" "")
      if not stderr.ends-with "\n":
        result += "\n <Missing newline at end of stderr> \n"
    result += "Exit Code: $exit-code\n"
    return result

class GoldTester:
  gold-dir_/string
  working-dir_/string
  toit-exec_/string
  should-update_/bool
  port_/int

  constructor
      --toit-exe/string
      --gold-dir/string
      --working-dir/string
      --should-update/bool
      --port/int:
    toit-exec_ = toit-exe
    gold-dir_ = gold-dir
    working-dir_ = working-dir
    should-update_ = should-update
    port_ = port

  normalize str/string -> string:
    str = str.replace --all "localhost:$port_" "localhost:<[*PORT*]>"
    // In lock files, the ':' is replaced with '_'.
    str = str.replace --all "localhost_$port_" "localhost_<[*PORT*]>"
    str = str.replace --all "$working-dir_" "<[*WORKING-DIR*]>"
    return str

  gold name/string commands/List:
    outputs := []
    commands.do: | command-line/List |
      command := command-line.first
      if command.starts-with "//":
        outputs.add "command\n"
      else if command == "analyze" or command == "exec":
        toit-command := command == "analyze" ? "analyze" : "run"
        run-result := toit toit-command command-line[1..]
        output := run-result.full-output
        normalized := normalize output
        command-string := command-line.join " "
        outputs.add "$command-string\n$normalized"
      else if command == "package.lock":
        lock-content := file.read-contents "$working-dir_/package.lock"
        normalized := normalize lock-content.to-string
        // Replace all hash values.
        hash-index := -1
        while true:
          hash-index = normalized.index-of "hash: " (hash-index + 1)
          if hash-index == -1: break
          newline-index := normalized.index-of "\n" hash-index
          if newline-index == -1: throw "No newline after hash"
          normalized = normalized[..hash-index] + "hash: <[*HASH*]>" + normalized[newline-index..]
        outputs.add "== package.lock\n$normalized"
      else if command == "pkg":
        test-ui := TestUi --quiet=false
        cli := Cli "pkg" --ui=test-ui
        e := catch --trace=(: it is not TestAbort):
          pkg.main --cli=cli ["--project-root=$working-dir_"] + command-line[1..]
        exit-status := e ? "Aborted" : "OK"
        if e and e is not TestAbort:
          print-on-stderr_ "Command failed: $e"
          expect e is TestAbort
        full-output := test-ui.stdout + test-ui.stderr
        outputs.add "$exit-status\n$command-line\n$full-output"
      else:
        throw "Unknown command: $command"

    gold-file := "$gold-dir_/$(name).gold"
    actual := outputs.join "==================\n"
    if should-update_:
      directory.mkdir --recursive gold-dir_
      file.write-contents --path=gold-file actual
    else:
      expected-content := (file.read-contents gold-file).to-string
      expected-content = expected-content.replace --all "\r" ""
      expect-equals expected-content actual

  toit command/string args -> RunResult_:
    full-args := [toit-exec_, command, "--"] + args
    process := pipe.fork
        --use-path
        --create-stdout
        --create-stderr
        toit-exec_
        full-args
    stdout := process.stdout
    stderr := process.stderr

    stdout-data := #[]
    stdout-task := task::
      try:
        reader := stdout.in
        while chunk := reader.read:
          stdout-data += chunk
      finally:
        stdout.close

    stderr-data := #[]
    stderr-task := task::
      try:
        reader := stderr.in
        while chunk := reader.read:
          stderr-data += chunk
      finally:
        stderr.close

    exit-value := process.wait
    stdout-task.cancel
    stderr-task.cancel

    return RunResult_
        --stdout=stdout-data.to-string
        --stderr=stderr-data.to-string
        --exit-value=exit-value

run-git-http-backend --prefix/string --root/string request/http.RequestIncoming writer/http.ResponseWriter:
  resource := request.query.resource
  path-info := "/$resource[prefix.size..]"
  path := request.path
  query-index := path.index-of "?"
  query-string := query-index != -1
      ? path[query-index + 1..]
      : ""

  env := {
    "PATH_INFO": path-info,
    "GIT_PROJECT_ROOT": root,
    "REMOTE_ADDR": "127.0.0.1",
    "REQUEST_METHOD": request.method,
  }
  if query-string != "":
    env["QUERY_STRING"] = query-string
  if request.headers.contains "Content-Type":
    env["CONTENT_TYPE"] = request.headers.single "Content-Type"
  if request.headers.contains "Content-Length":
    env["CONTENT_LENGTH"] = request.headers.single "Content-Length"
  request.headers.keys.do: | key/string |
    value := request.headers.single key
    if value != "":
      env["HTTP_$(key.to-ascii-upper.replace --all "-" "_")"] = value

  process := pipe.fork
      --environment=env
      --use-path
      --create-stdin
      --create-stdout
      "git"
      ["git", "http-backend"]

  stdin := process.stdin
  stdout := process.stdout

  stdin-task := task::
    while chunk := request.body.read:
      stdin.out.write chunk

  stdout-latch := monitor.Latch
  stdout-task := task::
    try:
      while true:
        line := stdout.in.read-line
        if not line or line == "": break
        colon-index := line.index-of ":"
        if colon-index == -1:
          print-on-stderr_ "Ignoring invalid header line: $line"
          continue
        key := line[0..colon-index - 1]
        value := line[colon-index + 1..]
        writer.headers.add key value

      writer.write-headers 200
      while chunk := stdout.in.read:
        // The chunk may have '\0' characters, which don't work nicely
        // when trying to debug print with '.to-string-non-throwing'.
        writer.out.write chunk

    finally:
      stdout.close
      stdout-latch.set "done"

  process.wait
  stdout-latch.get
  stdin-task.cancel
  request.body.drain
  writer.close

with-http-server http-dir/string tcp-socket/tcp.ServerSocket --git-roots/Map [block]:
  server := http.Server --max-tasks=20
  print "Serving on http://localhost:$tcp-socket.local-address.port"
  server-task := task::
    server.listen tcp-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
      resource := request.query.resource
      path/string? := null
      git-roots.do: | resource-prefix/string dir/string |
        if resource.starts-with resource-prefix:
          run-git-http-backend --prefix=resource-prefix --root=dir request writer
          continue.listen

      cleaned := path ? fs.clean path : null
      if not cleaned or not cleaned.starts-with "$http-dir/" or not file.is_file cleaned:
        writer.write-headers 404
        writer.out.write "Not found"
        writer.close
        continue.listen
      content := file.read-contents cleaned
      writer.out.write content
      writer.close

  try:
    block.call server
  finally:
    server-task.cancel

class AssetsBuilder:
  static HTTP-PKG-PREFIX ::= "/pkg/"
  static HTTP-REGISTRY-PREFIX ::= "/registry/"

  port_/int
  http-dir_/string
  git-roots := {:}

  constructor --port/int --http-dir/string:
    port_ = port
    http-dir_ = http-dir

  delete-path path/string:
    if file.is_directory path:
      directory.rmdir --recursive path
    else:
      file.delete path

  copy-path --source/string --target/string:
    if file.is_directory source:
      directory.mkdir --recursive target
      stream := directory.DirectoryStream source
      while name := stream.next:
        copy-path --source="$source/$name" --target="$target/$name"
    else if source.ends-with ".zip":
      unzip --source=source --target-dir=(fs.dirname target)
    else:
      content := (file.read-contents source).to-string
      content = content.replace --all "<[*PORT*]>" "$port_"
      file.write-contents --path=target content

  git-run args/List:
    exit-code := pipe.run-program (["git"] + args)
    expect-equals exit-code 0

  setup-git --working-dir/string --source-dir/string -> none:
    directory.mkdir --recursive working-dir
    directory.chdir working-dir
    git-run ["init"]
    git-run ["config", "user.email", "test@example.com"]
    git-run ["config", "user.name", "Test User"]
    git-run ["config", "tag.forceSignAnnotated", "false"]
    git-run ["config", "tag.gpgSign", "false"]
    stream := directory.DirectoryStream source-dir
    while version-name := stream.next:
      // Start by deleting the current version.
      delete-stream := directory.DirectoryStream working-dir
      while file-name := delete-stream.next:
        if file-name == ".git": continue
        path := "$working-dir/$file-name"
        delete-path path
      // Copy over the new version.
      copy-path --source="$source-dir/$version-name" --target=working-dir
      git-run ["add", "."]
      git-run ["commit", "--message", "Add $version-name"]
      git-run ["tag", version-name]
    git-run ["update-server-info"]
    file.write-contents --path="$working-dir/.git/hooks/post-update" """
      #!/bin/sh
      git update-server-info
      """
    file.write-contents --path="$working-dir/.git/git-daemon-export-ok" ""

  setup-git-pkg name/string --working-dir/string --source-dir/string -> none:
    setup-git --working-dir=working-dir --source-dir=source-dir

  setup-git-pkgs dir/string --working-dir/string:
    stream := directory.DirectoryStream dir
    while name := stream.next:
      git-dir := "$working-dir/$name"
      directory.mkdir git-dir
      setup-git-pkg
          name
          --working-dir="$working-dir/$name"
          --source-dir="$dir/$name"
    git-roots["$HTTP-PKG-PREFIX"] = working-dir

  setup-git-registry name/string --working-dir/string --source-dir/string -> none:
    setup-git --working-dir=working-dir --source-dir=source-dir

  setup-git-registries dir/string --working-dir/string:
    stream := directory.DirectoryStream dir
    while name := stream.next:
      setup-git-registry name
          --source-dir="$dir/$name"
          --working-dir="$working-dir/$name"
    git-roots["$HTTP-REGISTRY-PREFIX"] = working-dir

  setup --working-dir/string --assets-dir/string:
    stream := directory.DirectoryStream assets-dir
    while name := stream.next:
      if name == "gold": continue
      path := "$assets-dir/$name"
      if name == "GIT-SERVE-PKGS":
        pkg-dir := "$http-dir_/pkg"
        directory.mkdir --recursive pkg-dir
        setup-git-pkgs path --working-dir=pkg-dir
        continue
      if name == "GIT-SERVE-REGISTRIES":
        registry-dir := "$http-dir_/registry"
        directory.mkdir --recursive registry-dir
        setup-git-registries --working-dir=registry-dir path
        continue
      copy-path --source=path --target="$working-dir/$name"

with-gold-tester args/List --with-git-pkg-registry/bool=false [block]:
  toit-exe := args[0]

  source-location := system.program-path
  source-dir := fs.dirname source-location
  source-name := (fs.basename source-location).trim --right "-gold-test.toit"
  shared-dir := "$source-dir/assets/shared"
  assets-dir := "$source-dir/assets/$source-name"
  gold-dir := "$assets-dir/gold"
  network := net.open
  tcp-socket := network.tcp-listen 0
  port := tcp-socket.local-address.port

  with-tmp-dir: | tmp-dir |
    registry-cache-dir := "$tmp-dir/CACHE"
    registry-cache-file := "$registry-cache-dir/registries.yaml"
    directory.mkdir --recursive registry-cache-dir
    // By default we don't have any cache file.
    registry-content := "{}"
    if with-git-pkg-registry:
      registry-content = yaml.stringify {
          "git-pkgs": {
              "url": "http://localhost:$port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs",
              "type": "git",
              "ref-hash": "HEAD",
          }
      }
    file.write-contents --path=registry-cache-file registry-content
    os.env["TOIT_PKG_CACHE_DIR"] = registry-cache-dir

    http-dir := "$tmp-dir/HTTP-SERVE"
    directory.mkdir http-dir
    assets-builder := AssetsBuilder --port=port --http-dir=http-dir
    assets-builder.setup --working-dir=tmp-dir --assets-dir=shared-dir
    assets-builder.setup --working-dir=tmp-dir --assets-dir=assets-dir
    git-roots := assets-builder.git-roots
    with-http-server http-dir tcp-socket --git-roots=git-roots:
      directory.chdir tmp-dir
      tester := GoldTester
          --port=port
          --toit-exe=toit-exe
          --gold-dir=gold-dir
          --working-dir=tmp-dir
          --should-update=(os.env.get "UPDATE_GOLD") != null
      block.call tester
