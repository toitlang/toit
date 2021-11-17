// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import reader
import writer
import bytes
import log
import metrics

import .locker

CLOSED_ERROR_ ::= "AT_SESSION_CLOSED"
COMMAND_TIMEOUT_ERROR ::= "AT_COMMAND_TIMEOUT"

/**
Command to be send on a AT $Session. The command must be one of the 4 types
  `action`, `read`, `test` or `set`.
*/
class Command:
  static DEFAULT_TIMEOUT ::= Duration --s=2

  static ACTION_ ::= ""
  static READ_ ::= "?"
  static SET_ ::= "="
  static TEST_ ::= "=?"

  static COMMA_ ::= #[',']
  static DOUBLE_QUOTE_ ::= #['"']

  name/string
  type/string
  parameters/List ::= []
  data/ByteArray? ::= null

  timeout/Duration

  constructor.action .name --.timeout=DEFAULT_TIMEOUT:
    type = ACTION_

  constructor.read .name  --.timeout=DEFAULT_TIMEOUT:
    type = READ_

  constructor.test .name  --.timeout=DEFAULT_TIMEOUT:
    type = TEST_

  constructor.set .name --.parameters=[] --.data=null --.timeout=DEFAULT_TIMEOUT:
    type = SET_

  write_parameters writer:
    first := true
    parameters.do:
      if first: first = false
      else: writer.write COMMA_
      if it == null:
        // Don't write anything for nulls.
      else if it is string:
        writer.write DOUBLE_QUOTE_
        writer.write it
        writer.write DOUBLE_QUOTE_
      else:
        writer.write it.stringify

  stringify -> string:
    buffer := bytes.Buffer
    write_parameters
      writer.Writer buffer
    return "AT$name$type$buffer.bytes.to_string_non_throwing"

/**
Returns the parsed parts that make up the $line.

If $plain is set, the parser will not attempt to parse integers but instead
  return them as unparsed strings.
*/
parse_response line/ByteArray --plain=false -> List:
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
    end := line.index_of ',' --from=index
    if end == -1: end = size
    if end <= index:
      parts.add null
    else if line[index] == '"':
      parts.add
        line.to_string_non_throwing index + 1 end - 1
    else if plain:
      parts.add
        line.to_string_non_throwing index end
    else if line[index] == '(':
      end = line.index_of ')' --from=index
      parts.add
        parse_response line[index + 1..end]
      // Monarch has a non-comma-separated tuple list.
      if end + 1 < size and line[end + 1] == ',':
        // Advance $end to the ','.
        end++
    else:
      if (line.index_of '.' --from=index --to=end) >= 0:
        parts.add
          float.parse
            line.to_string index end
      else:
        i := int.parse_ line index end --on_error=: null
        parts.add
          i ? i : line.to_string_non_throwing index end

    index = end + 1
  return parts

/**
An AT session from a reader and a writer. The session can send AT commands to the
  while also processing URCs received.
*/
class Session:
  static DEFAULT_COMMAND_DELAY ::= Duration --ms=100

  static CR ::= 13

  static EOF ::= "UNEXPECTED_END_OF_READER"

  s3/int
  data_marker/int
  command_delay/Duration
  data_delay/Duration?

  reader_/reader.BufferedReader
  writer_/writer.Writer
  logger_/log.Logger?

  processor_/Processer_ ::= Processer_
  urc_handlers_/Map ::= {:}
  response_parsers_/Map ::= {:}
  ok_termination_/List ::= ["OK".to_byte_array]
  error_termination_/List ::= ["ERROR".to_byte_array]

  s3_data_/ByteArray

  command_/Command? := null
  command_deadline_/int := 0
  can_write_at_/int := 0
  responses_/List := []

  task_ := null
  error_/string? := null

  constructor r/reader.Reader w
      --logger=log.default
      --.s3=CR
      --.data_marker='@'
      --.command_delay=DEFAULT_COMMAND_DELAY
      --.data_delay=null:
    s3_data_ = #[CR]
    logger_ = logger
    reader_ = reader.BufferedReader r
    writer_ = writer.Writer w

    task_ = task::
      error := catch --trace=(: it != EOF):
        run_
      abort_ (error or CLOSED_ERROR_)

  /**
  Closes the AT session. This will abort any ongoing command.
  */
  close:
    abort_ CLOSED_ERROR_
    task_.cancel

  /**
  Returns true if the session is closed.
  */
  is_closed -> bool: return error_ != null

  /**
  Adds an OK termination condition.

  The string `OK` is present by default.
  */
  add_ok_termination termination/string:
    ok_termination_.add termination.to_byte_array

  /**
  Adds an ERROR termination condition.

  The string `ERROR` is present by default.
  */
  add_error_termination termination/string:
    error_termination_.add termination.to_byte_array

  /**
  Adds a custom response parser for the given $command name.

  The lambda is called with one argument, a $reader.BufferedReader.
  */
  add_response_parser command/string lambda/Lambda:
    response_parsers_.update command --if_absent=(: lambda): throw "parser already registered: $command"

  /**
  Register a URC (Unsolicited Result Code) handler for the command $name.
  */
  register_urc name/string lambda/Lambda:
    urc_handlers_.update name --if_absent=(: lambda): throw "urc already registered: $name"

  /**
  Unregister an already registered URC handler for the command $name.
  */
  unregister_urc name/string:
    urc_handlers_.remove name
      --if_absent=: throw "urc not registered: $name"

  /**
  Executes a `read` command with the $command_name.
  */
  read command_name/string --timeout/Duration?=null -> Result:
    return send
      Command.read command_name --timeout=timeout

  /**
  Executes a $Command.read with the $command_name.

  Returns null on time out when non $check.
  */
  read command_name/string --timeout/Duration?=null --check -> Result?:
    cmd ::= Command.read command_name --timeout=timeout
    return check ? send cmd : send_non_check cmd

  /**
  Executes a `test` command with the $command_name.
  */
  test command_name/string --timeout/Duration?=null -> Result:
    return send
      Command.test command_name --timeout=timeout

  /**
  Executes a $Command.test with the $command_name.

  Returns null on time out when non $check.
  */
  test command_name/string --timeout/Duration?=null --check -> Result?:
    cmd ::= Command.test command_name --timeout=timeout
    return check ? send cmd : send_non_check cmd

  /**
  Executes a `set` command with the $command_name, along with $parameters and optional $data.
  */
  set command_name/string parameters/List --data=null --timeout/Duration?=null -> Result:
    return send
      Command.set command_name --parameters=parameters --data=data --timeout=timeout

  /**
  Executes a $Command.set with the $command_name.

  Returns null on time out when non $check.
  */
  set command_name/string parameters/List --data=null --timeout/Duration?=null --check/bool-> Result?:
    cmd ::= Command.set command_name --parameters=parameters --data=data --timeout=timeout
    return check ? send cmd : send_non_check cmd

  /**
  Executes an `action` command with the $command_name.
  */
  action command_name/string --timeout/Duration?=null -> Result:
    return send
      Command.action command_name --timeout=timeout

  /**
  Executes a $Command.action with the $command_name.

  Returns null on time out when non $check.
  */
  action command_name/string --timeout/Duration?=null --check/bool -> Result?:
    cmd ::= Command.action command_name --timeout=timeout
    return check ? send cmd : send_non_check cmd

  /**
  Executes the $command on the Session. If the $send call is aborted (e.g. timeout), the Session
    will delay the next action until a response is received or the $Command.timeout is expired.

  Only one command can be executed at the time. Use the $Locker in a multi-task environment.
  */
  send command/Command -> Result:
    return send_ command
      --on_timeout=: throw COMMAND_TIMEOUT_ERROR
      --on_error=: | exception result | throw (exception ? exception : "$result")

  /**
  The same as $send, but returns null when it times out.
  */
  send_non_check command/Command -> Result?:
    return send_ command --on_timeout=(: return null) --on_error=(: return null)

  send_ command/Command [--on_timeout] [--on_error] -> Result:
    while true:
      if error_: throw error_

      now := Time.monotonic_us
      ready_at := max can_write_at_ command_deadline_

      if ready_at <= now: break

      duration_ms := min 250 (ready_at - now) / 1000
      sleep --ms=duration_ms

    now := Time.monotonic_us
    if command_deadline_ > now: throw "COMMAND ALREADY IN PROGRESS"

    command_ = command
    command_deadline_ = now + command.timeout.in_us
    responses_ = []

    task.with_deadline_ command_deadline_:
      try:
        write_command_ command
      finally: | is_exception exception |
        // Abort stream if write failed (especially timeout), as this will leave
        // the session in an undefined state.
        if is_exception: abort_ exception

    if result := processor_.wait_for_result command_deadline_:
      if not ok_termination_.contains result.code.to_byte_array:
        exception := result.exception
        on_error.call exception result
      return result

    return on_timeout.call

  abort_ error:
    if not error_:
      error_ = error
      processor_.close error
      command_deadline_ = 0
      task_.cancel

  write_command_ command/Command:
    logger_.with_level log.INFO_LEVEL: it.info "-> $command"
    writer_.write "AT"
    writer_.write command.name
    writer_.write command.type
    command.write_parameters writer_
    writer_.write s3_data_

  dispatch_urc_ urc/string response/List:
    delay_next_request_
    urc_handlers_.do: | prefix lambda |
      if urc.starts_with prefix:
        logger_.with_level log.INFO_LEVEL: it.info "<- [URC] $urc $response"
        lambda.call response
        return
    logger_.with_level log.INFO_LEVEL: it.info "<- *ignored* [URC] $urc $response"

  is_terminating_ line/ByteArray:
    return ok_termination_.contains line or error_termination_.contains line

  is_echo_ line/ByteArray:
    return line.size >= 3 and line[0] == 'A' and line[1] == 'T' and line[2] == '+'

  run_:
    while true:
      c := reader_.byte 0
      if c == '+':
        read_formatted_
      else if c == data_marker:
        reader_.skip 1
        if command := command_:
          if data := command.data:
            // Wait before sending data.
            if data_delay: sleep data_delay
            writer_.write data
            logger_.with_level log.INFO_LEVEL: it.info "<- $(%c data_marker)"
            logger_.with_level log.INFO_LEVEL: it.info "-> <$(data.size) bytes>"
            continue
        logger_.with_level log.INFO_LEVEL: it.info "<- $(%c data_marker) *no data*"
      else if c >= 32:
        if not command_:
          reader_.read_bytes_until s3
        else:
          read_plain_
      else:
        reader_.skip 1

  read_formatted_:
    // Formatted output: `+CMD: ...\r`.
    // Find end of line. Note it may not be valid for custom parsers.
    line_end := reader_.index_of s3
    // Look for ':'.
    cmd_end := reader_.index_of ':' --to=line_end
    if cmd_end < 0:
      // If we didn't find a ':' within the line, it's an URC with no param.
      cmd := reader_.read_string line_end
      dispatch_urc_ cmd []
      return

    cmd_bytes := reader_.bytes cmd_end
    if is_terminating_ cmd_bytes:
      line := reader_.read_string line_end
      reader_.skip 1  // Skip s3.
      logger_.with_level log.INFO_LEVEL: it.info "<- $line"
      complete_command_ line
      return

    cmd := cmd_bytes.to_string
    cmd_end++
    if (reader_.byte cmd_end) == ' ': cmd_end++
    reader_.skip cmd_end

    parsed := response_parsers_.get cmd
      --if_present=:
        logger_.with_level log.INFO_LEVEL: it.info "<- $cmd: <custom>"
        it.call reader_
      --if_absent=:
        bytes := reader_.read_bytes line_end - cmd_end
        reader_.skip 1  // Skip s3.
        logger_.with_level log.INFO_LEVEL: it.info "<- $cmd: $bytes.to_string_non_throwing"
        parse_response bytes

    if command_ and command_.name == cmd:
      responses_.add parsed
    else:
      dispatch_urc_ cmd parsed

  read_plain_:
    line := reader_.read_bytes_until s3
    if line.size == 0: return
    logger_.with_level log.INFO_LEVEL: it.info "<- $line.to_string_non_throwing"
    if is_echo_ line: return
    if is_terminating_ line:
      complete_command_ line.to_string
      return

    if command_:
      responses_.add
        parse_response line --plain=true

  complete_command_ code:
    delay_next_request_
    command_deadline_ = 0
    if command_:
      command_ = null
      processor_.set_result
        Result code responses_

  delay_next_request_:
    // Delay the next write after a response or an URC.
    can_write_at_ = Time.monotonic_us + command_delay.in_us

monitor Processer_:
  result_/Result? := null

  set_result result/Result:
    result_ = result

  wait_for_result deadline/int -> Result?:
    result_ = null
    has_result := try_await --deadline=deadline: result_
    if not has_result: return null
    r := result_
    result_ = null
    return r

  close error:
    result_ = Result.exception error

/**
Result from executing an AT $Command on a $Session.
*/
class Result:
  static COMMAND_ERROR_CODE_ ::= "COMMAND ERROR"

  code/string
  responses/List

  constructor .code .responses:

  constructor.exception exception/any:
    code = COMMAND_ERROR_CODE_
    responses = [ exception ]

  exception:
    if code != COMMAND_ERROR_CODE_ or responses.size != 1: return null
    return responses[0]

  single -> List:
    if responses.size != 1: throw "FORMAT_ERROR: $responses"
    return responses[0]

  last -> List:
    if responses.size < 1: throw "FORMAT_ERROR: $responses"
    return responses[responses.size - 1]

  stringify -> string:
    return "$code $responses"
