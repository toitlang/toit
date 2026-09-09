// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import net
import net.tcp show Socket ServerSocket

class MockDiagnostic:
  path / string ::= ?
  message / string ::= ?
  start-line / int ::= ?
  start-column / int ::= ?
  end-line / int ::= ?
  end-column / int ::= ?

  constructor --.path .message .start-line .start-column .end-line=start-line .end-column=start-column:

  is-same-as-json json/Map -> bool:
    return json["message"] == message and
        json["range"]["start"]["line"] == start-line and
        json["range"]["start"]["character"] == start-column and
        json["range"]["end"]["line"] == end-line and
        json["range"]["end"]["character"] == end-column

  to-compiler-format -> string:
    return """
      WITH POSITION
      error
      $path
      $start-line
      $start-column
      $end-line
      $end-column
      $message
      *******************
      """

class MockData:
  diagnostics / List := ?
  deps / List := ?

  constructor .diagnostics .deps:

/**
One run of the mock compiler, that is, one compiler process the LSP server
  started.
*/
class MockRun:
  pid / int
  /// The command the server sent, like "ANALYZE" or "COMPLETE".
  command / string
  /// The lines that followed the command: paths, and for some commands the
  /// line and column.
  request / List
  /// Whether the run waits for the test to release it.
  is-waiting / bool := true
  /// Set to true once the run may finish, or to false if the compiler died
  /// while it was waiting.
  released_ / monitor.Latch ::= monitor.Latch

  constructor --.pid --.command --.request:

  release_ value/bool -> none:
    if not is-waiting: return
    is-waiting = false
    released_.set value

  stringify -> string: return "$command pid=$pid $request"

/**
Controls the mock compiler (mock_compiler.cc).

The LSP server starts the mock compiler like the real one. Each run connects
  back to this class over a socket, announces its request, and waits for the
  answer it should print. The server must have $PORT-ENVIRONMENT-VARIABLE
  set to $port when it is spawned, so that the mock compiler inherits it.
  The answer for each command is set with $set-analysis-result and friends.

If an answer was set with `--sync`, runs for that command are held back
  until the test releases them (see $release and $release-all). Tests can
  thus see which compilers are running, and decide when they may finish,
  without relying on timing. A run counts as waiting from the moment it
  announces itself until it is released or dies.
*/
class MockCompiler:
  /// The environment variable through which the mock compiler finds $port.
  static PORT-ENVIRONMENT-VARIABLE ::= "TOIT_MOCK_COMPILER_PORT"
  static ANALYZE ::= "ANALYZE"
  static COMPLETE ::= "COMPLETE"
  /// How long $wait-for-waiting waits before giving up.
  static WAIT-TIMEOUT-MS ::= 10_000

  server_ / ServerSocket

  mock-information_ / Map/*<path/string, MockData>*/ ::= {:}
  answers_ / Map/*<command/string, string>*/ ::= {:}
  synced-commands_ / Set ::= {}
  runs_ / List := []
  changed_ / monitor.Signal ::= monitor.Signal

  /// Starts listening for mock compilers.
  constructor:
    network := net.open
    server_ = network.tcp-listen 0
    task --background::
      while true:
        socket := null
        // Closing the server socket ends the accept loop.
        if (catch: socket = server_.accept): break
        // A null socket is a spurious wakeup.
        if socket: task:: handle_ socket

  /// The port on which the mock compilers are expected.
  port -> int: return server_.local-address.port

  /// Stops listening for mock compilers.
  close -> none:
    server_.close

  set-mock-data --path/string data/MockData:
    mock-information_[path] = data

  /**
  Sets the $answer the mock compiler prints for analysis requests.

  If $sync is true, runs for analysis requests wait until they are released.
  If $crash is true, the compiler crashes after printing the answer.
  If $timeout is true, the compiler hangs after printing the answer.
  */
  set-analysis-result answer/string="" --sync/bool=false --crash/bool=false --timeout/bool=false -> none:
    set-answer_ ANALYZE answer --sync=sync --crash=crash --timeout=timeout

  /// Variant of $set-analysis-result for completion requests.
  set-completion-result answer/string="" --sync/bool=false --crash/bool=false --timeout/bool=false -> none:
    set-answer_ COMPLETE answer --sync=sync --crash=crash --timeout=timeout

  set-answer_ command/string answer/string --sync/bool --crash/bool --timeout/bool -> none:
    // The directives are understood by mock_compiler.cc.
    if timeout: answer = "TIMEOUT\n" + answer
    if crash: answer = "CRASH\n" + answer
    answers_[command] = answer
    if sync:
      synced-commands_.add command
    else:
      synced-commands_.remove command

  /// The runs that have started so far.
  started -> List: return runs_.copy

  /// The runs that are waiting to be released.
  waiting -> List: return runs_.filter: it.is-waiting

  /**
  Blocks until at least $count runs are waiting.

  Returns the waiting runs.
  */
  wait-for-waiting count/int -> List:
    exception := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      with-timeout --ms=WAIT-TIMEOUT-MS:
        changed_.wait: waiting.size >= count
    if exception:
      throw "Timed out waiting for $count mock compilers. Started: $runs_"
    return waiting

  /// Lets the given $run finish.
  release run/MockRun -> none:
    run.release_ true
    changed_.raise

  /// Lets all runs finish, including the ones that start later.
  release-all -> none:
    synced-commands_.clear
    waiting.do: release it

  handle_ socket/Socket -> none:
    try:
      reader := socket.in
      pid-line := reader.read-line
      command := reader.read-line
      // The compiler died before it announced itself.
      if not pid-line or not command: return
      request := []
      while true:
        line := reader.read-line
        if not line or line == "": break
        request.add line
      run := MockRun --pid=(int.parse pid-line) --command=command --request=request
      runs_.add run
      changed_.raise

      if synced-commands_.contains command:
        // A run that is killed while it waits must not count as waiting.
        task::
          catch: reader.read
          run.release_ false
          changed_.raise
        if not run.released_.get: return
      else:
        run.release_ true

      answer := answers_.get command --if-absent=: ""
      // The compiler may have been killed (for example by a canceled request)
      // before it read the answer.
      catch:
        socket.out.write "$answer.size\n"
        socket.out.write answer
    finally:
      socket.close

  build-analysis-answer --path/string -> string:
    summary-string := build-summary_
    diagnostics-string := build-diagnostics_ path
    return summary-string + "\n" + diagnostics-string

  build-deps_ data --chunks/List:
    if not data:
      chunks.add "1"
      chunks.add "/CORE"
    else:
      chunks.add data.deps.size + 1
      chunks.add "/CORE"
      chunks.add-all data.deps

  /// Builds the summary of all paths known to the mock compiler.
  build-summary_ -> string:
    chunks := []
    build-summary_ --chunks=chunks
    return "SUMMARY\n" + (chunks.join "\n") + "\n"

  build-summary_ --chunks/List -> none:
    all-uris := {}
    mock-information_.do: |uri data|
      all-uris.add uri
      all-uris.add-all data.deps

    chunks.add all-uris.size
    all-uris.do:
      chunks.add it
      chunks.add 0  // Currently there are no toplevel elements in the modules.
    all-uris.do:
      data := mock-information_.get it
      chunks.add it
      build-deps_ data --chunks=chunks
      // The external hash is 20 bytes, but we join all chunks with a "\n" above.
      // As such we only add 19 bytes here and let the 20th byte be a '\n'.
      chunks.add ("a" * 19)
      // For now, just provide empty summaries.
      chunks.add 7 * 2  // The following 6 entries take one byte for the number/'-' and one for the '\n'.
      chunks.add "-"
      chunks.add 0 // No transitive exports.
      chunks.add 0 // Exported identifiers.
      chunks.add 0 // Classes
      chunks.add 0 // Methods
      chunks.add 0 // Globals
      chunks.add 0 // Toitdoc

  build-diagnostics_ entry-path/string -> string:
    chunks := []
    build-diagnostics_ entry-path --seen={} --chunks=chunks
    return chunks.join "\n" + "\n"

  build-diagnostics_ path/string --seen/Set --chunks/List -> none:
    if seen.contains path: return
    seen.add path
    data := mock-information_.get path
    if not data: return
    chunks.add-all
        data.diagnostics.map: it.to-compiler-format
    data.deps.do: build-diagnostics_ it --seen=seen --chunks=chunks
