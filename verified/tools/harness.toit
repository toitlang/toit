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

/**
Shared code of the test drivers in verified/tools: repository paths, running
  a command with a time limit, running work in parallel, the program
  discovery of the suite, compiling and dumping programs, and output
  formatting that the drivers' result files rely on.

Every entry point lives in verified/tools, so the repository root is two
  directories above the running program.
*/

import encoding.json
import fs
import host.directory
import host.file
import host.os
import host.pipe
import io
import monitor
import system

/** The repository root. */
REPO/string ::= fs.clean (fs.join (fs.dirname system.program-path) ".." "..")
/** The verified/ directory. */
VERIFIED/string ::= fs.join REPO "verified"
/** The spec crate (verified/spec). */
SPEC-CRATE/string ::= fs.join VERIFIED "spec"
/** The vmverify crate (verified/vmverify). */
VMVERIFY-CRATE/string ::= fs.join VERIFIED "vmverify"

/** The `toit` executable: the TOIT environment variable, or the host build's SDK. */
toit-bin -> string:
  return os.env.get "TOIT" or (fs.join REPO "build/host/sdk/bin/toit")

/** The SDK directory of $toit-bin. */
sdk-dir -> string:
  return fs.dirname (fs.dirname toit-bin)

/** The SDK's toit.compile (next to $toit-bin). */
toit-compile-bin -> string:
  return fs.join sdk-dir "lib/toit/bin/toit.compile"

/** The SDK's toit.run (next to $toit-bin). */
toit-run-bin -> string:
  return fs.join sdk-dir "lib/toit/bin/toit.run"

/** The reference interpreter of the spec crate. */
SPEC-RUNNER/string ::= fs.join SPEC-CRATE "target/release/toit-spec-run"

/** The arguments ctest passes to every test. */
TEST-ARGS/List ::= ["foo", "bar", "gee"]

/** The environment entry ctest sets for every test. */
TEST-ENV/Map ::= {"TOIT_TEST_ENV_ENTRY": "TOIT_TEST_ENV_VALUE"}

/**
Makes $path absolute (relative to the current directory) and clean.
Drivers call this on their path arguments before $enter-repo.
*/
absolute path/string -> string:
  return fs.clean (fs.to-absolute path)

/**
Changes the current directory to the repository root: every command the
  drivers run runs there, like ctest runs the tests.
*/
enter-repo -> none:
  directory.chdir REPO

/** $path relative to the repository root. */
repo-relative path/string -> string:
  return fs.to-relative path --base=REPO

/** The number of processors (`nproc`). */
cpu-count -> int:
  catch:
    return int.parse (pipe.backticks ["nproc"]).trim
  return 8

/** Creates the directory $path and its parents if needed. */
make-dirs path/string -> none:
  directory.mkdir --recursive path

/** Writes $content (a string or byte array) to $path. */
write-file path/string content -> none:
  file.write-contents content --path=path

/** Reads $path as a string. */
read-file path/string -> string:
  return (file.read-contents path).to-string-non-throwing

/** Whether $path exists (file or directory). */
exists path/string -> bool:
  return (file.stat path) != null

/**
The result of $run: the exit code (negative for a signal, as Python's
  subprocess reports it) or "timeout", and the captured output.
*/
class RunResult:
  code/any
  stdout/ByteArray
  stderr/ByteArray

  constructor .code .stdout .stderr:

  timed-out -> bool: return code == "timeout"

  /** Whether the command exited normally with code 0. */
  ok -> bool: return code == 0

  /** The exit code as a string ("0", "-11", "timeout"). */
  code-string -> string: return "$code"

  stdout-string -> string: return stdout.to-string-non-throwing
  stderr-string -> string: return stderr.to-string-non-throwing

/**
Runs $command (a list: executable and arguments) and captures its output.

The $environment entries are added to (or, with a null value, removed from)
  the environment of this process. With $timeout-s the command is killed
  after that many seconds and the result's code is "timeout". With $out-path
  stdout and stderr are also written to the files $out-path with ".out" and ".err" appended.
*/
run command/List -> RunResult
    --timeout-s/int?=null
    --environment/Map?=null
    --out-path/string?=null:
  process := pipe.fork command[0] command
      --create-stdout
      --create-stderr
      --environment=environment
  out := io.Buffer
  err := io.Buffer
  done := monitor.Semaphore
  readers := [
    task:: drain_ process.stdout out done,
    task:: drain_ process.stderr err done,
  ]
  timed-out := false
  if timeout-s:
    exception := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      with-timeout --ms=(timeout-s * 1000):
        done.down
        done.down
        process.wait
    if exception:
      timed-out = true
      catch: process.kill --hard
      process.wait
      // Grandchildren may keep the pipes open; give the readers a moment.
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout --ms=1000:
          done.down
          done.down
      readers.do: it.cancel
  else:
    done.down
    done.down
    process.wait
  catch: process.stdout.close
  catch: process.stderr.close
  code/any := ?
  if timed-out:
    code = "timeout"
  else if process.exit-signal:
    code = -process.exit-signal
  else:
    code = process.exit-code
  result := RunResult code (out.bytes) (err.bytes)
  if out-path:
    write-file "$(out-path).out" result.stdout
    write-file "$(out-path).err" result.stderr
  return result

drain_ stream/pipe.Stream buffer/io.Buffer done/monitor.Semaphore -> none:
  try:
    reader := stream.in
    while chunk := reader.read:
      buffer.write chunk
  finally:
    done.up

/**
Runs $command with inherited stdout and stderr and throws if it fails
  (Python's `subprocess.run(..., check=True)`).
*/
run-checked command/List --environment/Map?=null -> none:
  process := pipe.fork command[0] command --environment=environment
  process.wait
  if process.exit-code != 0:
    throw "command failed ($(process.exit-code or "signal $process.exit-signal")): $(command.join " ")"

/**
Calls $work with every item of $items, at most $jobs at a time, and returns
  the results in the order of $items.
*/
parallel-map items/List --jobs/int work/Lambda -> List:
  results := List items.size
  parallel-do items --jobs=jobs
      --work=work
      --done=:: | item index result | results[index] = result
  return results

/**
Calls $work with every item of $items, at most $jobs at a
  time, and calls $done with each item, its index and the result in the
  order the work finishes. $done runs in the calling task.
*/
parallel-do items/List --jobs/int --work/Lambda --done/Lambda -> none:
  if items.is-empty: return
  slots := monitor.Semaphore --count=(max 1 jobs)
  finished := monitor.Channel items.size
  items.size.repeat: | index |
    slots.down
    item := items[index]
    task::
      result := null
      exception := catch --trace:
        result = work.call item
      slots.up
      finished.send [index, result, exception]
  items.size.repeat:
    entry := finished.receive
    if entry[2]: throw entry[2]
    done.call items[entry[0]] entry[0] entry[1]

/**
The test programs of the suite (tests/NAME-test.toit and friends), relative
  to the repository root and sorted per pattern. With $filters only the
  ones that contain one of the strings.
*/
discover filters/List?=null -> List:
  patterns := [
    ["tests", "-test.toit"],
    ["tests/regress", "-test.toit"],
    ["tests", "-test-slow.toit"],
    ["tests", "-test-force.toit"],
    ["tests/regress", "-test-force.toit"],
  ]
  files := []
  patterns.do: | pattern |
    names := list-files (fs.join REPO pattern[0]) --suffix=pattern[1]
    names.do: files.add "$pattern[0]/$it"
  if filters and not filters.is-empty:
    files = files.filter: | f | filters.any: f.contains it
  return files

/**
The names of the files in $dir that end with $suffix (and do not start
  with a dot, like a shell glob), sorted.
*/
list-files dir/string --suffix/string="" -> List:
  names := []
  stream := directory.DirectoryStream dir
  try:
    while name := stream.next:
      if name.starts-with ".": continue
      if not name.ends-with suffix: continue
      if not file.is-file (fs.join dir name): continue
      names.add name
  finally:
    stream.close
  names.sort --in-place
  return names

/** Builds the release binaries of the cargo crate in $crate (optionally only $bin). */
cargo-build crate/string --bin/string?=null -> none:
  command := ["cargo", "build", "--release", "--quiet",
              "--manifest-path", fs.join crate "Cargo.toml"]
  if bin: command += ["--bin", bin]
  run-checked command

/**
Compiles tools/spec_dump.toit to $path (unless it exists and $if-missing is
  set).
*/
compile-dumper path/string --if-missing/bool=false -> none:
  if if-missing and exists path: return
  run-checked [toit-bin, "compile", "--snapshot", "-o", path, fs.join REPO "tools/spec_dump.toit"]

/**
Compiles $src in format 2 to $out/<name>.snapshot and dumps it with the
  $dumper snapshot to $out/<name>.dump, where <name> is $src relative to
  the repository with '/' replaced by '_' and without ".toit". Reuses an
  existing dump. Returns [dump, null], or [null, "compile-error"] or
  [null, "dump-error"].
*/
compile-and-dump src/string out/string dumper/string -> List:
  name := (repo-relative src).replace --all "/" "_"
  name = name[..name.size - 5]
  snapshot := fs.join out "$(name).snapshot"
  dump := fs.join out "$(name).dump"
  if not exists dump:
    result := run [toit-compile-bin, "-Xbytecode_format=2", "-w", snapshot, src] --timeout-s=300
    if not result.ok: return [null, "compile-error"]
    result = run [toit-bin, "run", dumper, "--", snapshot, dump] --timeout-s=300
    if not result.ok: return [null, "dump-error"]
  return [dump, null]

/**
Encodes $value as JSON like Python's `json.dumps(value, indent=..., sort_keys=...)`
  with the default separators and ensure_ascii.
*/
json-pretty value --indent/int --sort-keys/bool=false -> string:
  buffer := io.Buffer
  json-pretty_ buffer value indent 0 sort-keys
  return buffer.to-string

json-pretty_ buffer/io.Buffer value indent/int level/int sort-keys/bool -> none:
  pad := : | n |
    buffer.write "\n"
    buffer.write (" " * (n * indent))
  if value is Map:
    if value.is-empty:
      buffer.write "{}"
      return
    keys := value.keys
    if sort-keys: keys.sort --in-place
    buffer.write "{"
    keys.size.repeat: | i |
      if i > 0: buffer.write ","
      pad.call level + 1
      json-string_ buffer "$keys[i]"
      buffer.write ": "
      json-pretty_ buffer value[keys[i]] indent (level + 1) sort-keys
    pad.call level
    buffer.write "}"
  else if value is List:
    if value.is-empty:
      buffer.write "[]"
      return
    buffer.write "["
    value.size.repeat: | i |
      if i > 0: buffer.write ","
      pad.call level + 1
      json-pretty_ buffer value[i] indent (level + 1) sort-keys
    pad.call level
    buffer.write "]"
  else if value is string:
    json-string_ buffer value
  else if value == true:
    buffer.write "true"
  else if value == false:
    buffer.write "false"
  else if value == null:
    buffer.write "null"
  else:
    buffer.write "$value"

json-string_ buffer/io.Buffer s/string -> none:
  buffer.write "\""
  s.do --runes: | c |
    if c == '"': buffer.write "\\\""
    else if c == '\\': buffer.write "\\\\"
    else if c == '\n': buffer.write "\\n"
    else if c == '\r': buffer.write "\\r"
    else if c == '\t': buffer.write "\\t"
    else if c == 0x08: buffer.write "\\b"
    else if c == 0x0c: buffer.write "\\f"
    else if c < 0x20 or c >= 0x7f:
      if c >= 0x10000:
        v := c - 0x10000
        buffer.write "\\u$(%04x 0xd800 + (v >> 10))\\u$(%04x 0xdc00 + (v & 0x3ff))"
      else:
        buffer.write "\\u$(%04x c)"
    else:
      buffer.write (string.from-rune c)
  buffer.write "\""

/** $s padded with spaces on the right to $width (Python's "%-Ns"). */
pad-right s/string width/int -> string:
  return s.size >= width ? s : s + " " * (width - s.size)

/** $s padded with spaces on the left to $width (Python's "%Ns"). */
pad-left s/string width/int -> string:
  return s.size >= width ? s : " " * (width - s.size) + s

/** $n with an explicit sign (Python's "%+d"). */
signed n/int -> string:
  return n >= 0 ? "+$n" : "$n"

/** $x with an explicit sign and $digits decimals (Python's "%+.Nf"). */
signed-float x/float --digits/int=1 -> string:
  text := x.stringify digits
  return x >= 0.0 and not text.starts-with "-" ? "+$text" : text
