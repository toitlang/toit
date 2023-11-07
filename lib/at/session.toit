// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader
import writer
import bytes
import log

import .locker

CLOSED-ERROR_ ::= "AT_SESSION_CLOSED"
COMMAND-TIMEOUT-ERROR ::= "AT_COMMAND_TIMEOUT"

/**
Command to be send on a AT $Session. The command must be one of the 4 types
  `action`, `read`, `test` or `set`.

Deprecated.
*/
class Command:
  static DEFAULT-TIMEOUT ::= Duration --s=2

  static ACTION_ ::= ""
  static READ_ ::= "?"
  static SET_ ::= "="
  static TEST_ ::= "=?"
  static RAW_ ::= "R"

  static COMMA_ ::= #[',']
  static DOUBLE-QUOTE_ ::= #['"']

  name/string
  type/string
  parameters/List ::= []
  data ::= null

  timeout/Duration

  constructor.action .name --.timeout=DEFAULT-TIMEOUT:
    type = ACTION_

  constructor.read .name  --.timeout=DEFAULT-TIMEOUT:
    type = READ_

  constructor.test .name  --.timeout=DEFAULT-TIMEOUT:
    type = TEST_

  constructor.set .name --.parameters=[] --.data=null --.timeout=DEFAULT-TIMEOUT:
    type = SET_

  constructor.raw command/string --s3-data/bool=true --.timeout=DEFAULT-TIMEOUT:
    name = command
    type = RAW_
    data = s3-data

  write-parameters writer:
    first := true
    parameters.do:
      if first: first = false
      else: writer.write COMMA_
      if it == null:
        // Don't write anything for nulls.
      else if it is string:
        writer.write DOUBLE-QUOTE_
        writer.write it
        writer.write DOUBLE-QUOTE_
      else:
        writer.write it.stringify

  stringify -> string:
    if type == RAW_: return "raw[$name]$(data ? "+s3" : "")"
    buffer := bytes.Buffer
    write-parameters
      writer.Writer buffer
    return "AT$name$type$buffer.bytes.to-string-non-throwing"

/**
Returns the parsed parts that make up the $line.

If $plain is set, the parser will not attempt to parse integers but instead
  return them as unparsed strings.
*/
parse-response line/ByteArray --plain=false -> List:
  parts := List
  index := 0
  size := line.size
  // Truncate tailing spaces.
  while size > 0 and line[size - 1] == ' ': size--
  while index < size:
    // Trim spaces.
    while line[index] == ' ': index++
    // TODO(anders): I wonder if this is good enough, could a result be e.g.
    //    +LALA: "foo,bar","baz"
    end := line.index-of ',' --from=index
    if end == -1: end = size
    if end <= index:
      parts.add null
    else if line[index] == '"':
      parts.add
        line.to-string-non-throwing index + 1 end - 1
    else if plain:
      parts.add
        line.to-string-non-throwing index end
    else if line[index] == '(':
      end = line.index-of ')' --from=index
      parts.add
        parse-response line[index + 1..end]
      // Monarch has a non-comma-separated tuple list.
      if end + 1 < size and line[end + 1] == ',':
        // Advance $end to the ','.
        end++
    else:
      if (line.index-of '.' --from=index --to=end) >= 0:
        parts.add
          float.parse
            line.to-string index end
      else:
        i := int.parse_ line index end --radix=10 --on-error=: null
        parts.add
          i ? i : line.to-string-non-throwing index end

    index = end + 1
  return parts

/**
An AT session from a reader and a writer. The session can send AT commands to the
  while also processing URCs received.

Deprecated.
*/
class Session:
  static DEFAULT-COMMAND-DELAY ::= Duration --ms=100

  static CR ::= 13

  static EOF ::= "UNEXPECTED_END_OF_READER"

  s3/int
  data-marker/int
  command-delay/Duration
  data-delay/Duration?

  reader_/reader.BufferedReader
  writer_/writer.Writer
  logger_/log.Logger?

  processor_/Processer_ ::= Processer_
  urc-handlers_/Map ::= {:}
  response-parsers_/Map ::= {:}
  ok-termination_/List ::= ["OK".to-byte-array]
  error-termination_/List ::= ["ERROR".to-byte-array]

  s3-data_/ByteArray

  command_/Command? := null
  command-deadline_/int := 0
  can-write-at_/int := 0
  responses_/List := []

  task_ := null
  error_/string? := null

  constructor r/reader.Reader w
      --logger=log.default
      --.s3=CR
      --.data-marker='@'
      --.command-delay=DEFAULT-COMMAND-DELAY
      --.data-delay=null:
    s3-data_ = #[CR]
    logger_ = logger
    reader_ = reader.BufferedReader r
    writer_ = writer.Writer w

    task_ = task::
      error := catch --trace=(: it != EOF):
        run_
      abort_ (error or CLOSED-ERROR_)

  /**
  Closes the AT session. This will abort any ongoing command.
  */
  close:
    abort_ CLOSED-ERROR_
    task_.cancel

  /**
  Returns true if the session is closed.
  */
  is-closed -> bool: return error_ != null

  /**
  Adds an OK termination condition.

  The string `OK` is present by default.
  */
  add-ok-termination termination/string:
    ok-termination_.add termination.to-byte-array

  /**
  Adds an ERROR termination condition.

  The string `ERROR` is present by default.
  */
  add-error-termination termination/string:
    error-termination_.add termination.to-byte-array

  /**
  Adds a custom response parser for the given $command name.

  The lambda is called with one argument, a $reader.BufferedReader.
  */
  add-response-parser command/string lambda/Lambda:
    response-parsers_.update command --if-absent=(: lambda): throw "parser already registered: $command"

  /**
  Register a URC (Unsolicited Result Code) handler for the command $name.
  */
  register-urc name/string lambda/Lambda:
    urc-handlers_.update name --if-absent=(: lambda): throw "urc already registered: $name"

  /**
  Unregister an already registered URC handler for the command $name.
  */
  unregister-urc name/string:
    urc-handlers_.remove name
      --if-absent=: throw "urc not registered: $name"

  /**
  Executes a `read` command with the $command-name.
  */
  read command-name/string --timeout/Duration?=null -> Result:
    return send
      Command.read command-name --timeout=timeout

  /**
  Executes a $Command.read with the $command-name.

  Returns null on time out when non $check.
  */
  read command-name/string --timeout/Duration?=null --check -> Result?:
    cmd ::= Command.read command-name --timeout=timeout
    return check ? send cmd : send-non-check cmd

  /**
  Executes a `test` command with the $command-name.
  */
  test command-name/string --timeout/Duration?=null -> Result:
    return send
      Command.test command-name --timeout=timeout

  /**
  Executes a $Command.test with the $command-name.

  Returns null on time out when non $check.
  */
  test command-name/string --timeout/Duration?=null --check -> Result?:
    cmd ::= Command.test command-name --timeout=timeout
    return check ? send cmd : send-non-check cmd

  /**
  Executes a `set` command with the $command-name, along with $parameters and optional $data.
  */
  set command-name/string parameters/List --data=null --timeout/Duration?=null -> Result:
    return send
      Command.set command-name --parameters=parameters --data=data --timeout=timeout

  /**
  Executes a $Command.set with the $command-name.

  Returns null on time out when non $check.
  */
  set command-name/string parameters/List --data=null --timeout/Duration?=null --check/bool-> Result?:
    cmd ::= Command.set command-name --parameters=parameters --data=data --timeout=timeout
    return check ? send cmd : send-non-check cmd

  /**
  Executes an `action` command with the $command-name.
  */
  action command-name/string --timeout/Duration?=null -> Result:
    return send
      Command.action command-name --timeout=timeout

  /**
  Executes a $Command.action with the $command-name.

  Returns null on time out when non $check.
  */
  action command-name/string --timeout/Duration?=null --check/bool -> Result?:
    cmd ::= Command.action command-name --timeout=timeout
    return check ? send cmd : send-non-check cmd

  /**
  Executes the $command on the Session. If the $send call is aborted (e.g. timeout), the Session
    will delay the next action until a response is received or the $Command.timeout is expired.

  Only one command can be executed at the time. Use the $Locker in a multi-task environment.
  */
  send command/Command -> Result:
    return send_ command
      --on-timeout=: throw COMMAND-TIMEOUT-ERROR
      --on-error=: | exception result | throw (exception ? exception : "$result")

  /**
  The same as $send, but returns null when it times out.
  */
  send-non-check command/Command -> Result?:
    return send_ command --on-timeout=(: return null) --on-error=(: return null)

  send_ command/Command [--on-timeout] [--on-error] -> Result:
    while true:
      if error_: throw error_

      now := Time.monotonic-us
      ready-at := max can-write-at_ command-deadline_

      if ready-at <= now: break

      // Add one to avoid rounding down to a number of milliseconds that
      // will not get us past 'ready at'.
      duration-ms := min 250 ((ready-at - now) / 1000) + 1
      sleep --ms=duration-ms

    now := Time.monotonic-us
    if command-deadline_ > now: throw "COMMAND ALREADY IN PROGRESS"

    command_ = command
    command-deadline_ = now + command.timeout.in-us
    responses_ = []

    Task_.current.with-deadline_ command-deadline_:
      try:
        write-command_ command
      finally: | is-exception exception |
        // Abort stream if write failed (especially timeout), as this will leave
        // the session in an undefined state.
        if is-exception: abort_ exception.value

    if result := processor_.wait-for-result command-deadline_:
      if not ok-termination_.contains result.code.to-byte-array:
        exception := result.exception
        on-error.call exception result
      return result

    return on-timeout.call

  abort_ error:
    if not error_:
      error_ = error
      processor_.close error
      command-deadline_ = 0
      task_.cancel

  write-command_ command/Command:
    logger_.with-level log.INFO-LEVEL: it.info "-> $command"
    if command.type == Command.RAW_:
      writer_.write command.name
      if command.data: writer_.write s3-data_
    else:
      writer_.write "AT"
      writer_.write command.name
      writer_.write command.type
      command.write-parameters writer_
      writer_.write s3-data_

  dispatch-urc_ urc/string response/List:
    delay-next-request_
    urc-handlers_.do: | prefix lambda |
      if urc.starts-with prefix:
        logger_.with-level log.INFO-LEVEL: it.info "<- [URC] $urc $response"
        lambda.call response
        return
    logger_.with-level log.INFO-LEVEL: it.info "<- *ignored* [URC] $urc $response"

  is-terminating_ line/ByteArray:
    return ok-termination_.contains line or error-termination_.contains line

  is-echo_ line/ByteArray:
    return line.size >= 3 and line[0] == 'A' and line[1] == 'T' and line[2] == '+'

  run_:
    while true:
      c := reader_.byte 0
      if c == '+':
        read-formatted_
      else if c == data-marker:
        reader_.skip 1
        if command := command_:
          if data := command.data:
            // Wait before sending data.
            if data-delay: sleep data-delay
            writer_.write data
            logger_.with-level log.INFO-LEVEL: it.info "<- $(%c data-marker)"
            logger_.with-level log.INFO-LEVEL: it.info "-> <$(data.size) bytes>"
            continue
        logger_.with-level log.INFO-LEVEL: it.info "<- $(%c data-marker) *no data*"
      else if c >= 32:
        if not command_:
          reader_.read-bytes-until s3
        else:
          read-plain_
      else:
        reader_.skip 1

  read-formatted_:
    // Formatted output: `+CMD: ...\r`.
    // Find end of line. Note it may not be valid for custom parsers.
    line-end := reader_.index-of s3
    // Look for ':'.
    cmd-end := reader_.index-of ':' --to=line-end
    if cmd-end < 0:
      // If we didn't find a ':' within the line, it's an URC with no param.
      cmd := reader_.read-string line-end
      dispatch-urc_ cmd []
      return

    cmd-bytes := reader_.bytes cmd-end
    if is-terminating_ cmd-bytes:
      line := reader_.read-string line-end
      reader_.skip 1  // Skip s3.
      logger_.with-level log.INFO-LEVEL: it.info "<- $line"
      complete-command_ line
      return

    cmd := cmd-bytes.to-string
    cmd-end++
    if (reader_.byte cmd-end) == ' ': cmd-end++
    reader_.skip cmd-end

    parsed := response-parsers_.get cmd
      --if-present=:
        logger_.with-level log.INFO-LEVEL: it.info "<- $cmd: <custom>"
        it.call reader_
      --if-absent=:
        bytes := reader_.read-bytes line-end - cmd-end
        reader_.skip 1  // Skip s3.
        logger_.with-level log.INFO-LEVEL: it.info "<- $cmd: $bytes.to-string-non-throwing"
        parse-response bytes

    if command_ and command_.name == cmd:
      responses_.add parsed
    else:
      dispatch-urc_ cmd parsed

  read-plain_:
    line := reader_.read-bytes-until s3
    if line.size == 0: return
    logger_.with-level log.INFO-LEVEL: it.info "<- $line.to-string-non-throwing"
    if is-echo_ line: return
    if is-terminating_ line:
      complete-command_ line.to-string
      return

    if command_:
      responses_.add
        parse-response line --plain=true

  complete-command_ code:
    delay-next-request_
    command-deadline_ = 0
    if command_:
      command_ = null
      processor_.set-result
        Result code responses_

  delay-next-request_:
    // Delay the next write after a response or an URC.
    can-write-at_ = Time.monotonic-us + command-delay.in-us

monitor Processer_:
  result_/Result? := null

  set-result result/Result:
    result_ = result

  wait-for-result deadline/int -> Result?:
    result_ = null
    has-result := try-await --deadline=deadline: result_
    if not has-result: return null
    r := result_
    result_ = null
    return r

  close error:
    result_ = Result.exception error

/**
Result from executing an AT $Command on a $Session.

Deprecated.
*/
class Result:
  static COMMAND-ERROR-CODE_ ::= "COMMAND ERROR"

  code/string
  responses/List

  constructor .code .responses:

  constructor.exception exception/any:
    code = COMMAND-ERROR-CODE_
    responses = [ exception ]

  exception:
    if code != COMMAND-ERROR-CODE_ or responses.size != 1: return null
    return responses[0]

  single -> List:
    if responses.size != 1: throw "FORMAT_ERROR: $responses"
    return responses[0]

  last -> List:
    if responses.size < 1: throw "FORMAT_ERROR: $responses"
    return responses[responses.size - 1]

  stringify -> string:
    return "$code $responses"
