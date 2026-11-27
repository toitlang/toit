// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show *
import host.directory
import host.file
import host.pipe
import uart
import system

// Shared host-side support. Serial I/O uses the SDK's native HostPort.
options args/List required/List --optional/List=[] -> Map:
  result := {:}
  index := 0
  while index < args.size:
    argument/string := args[index++]
    if not argument.starts-with "--": throw "Expected option, got $argument"
    parts := argument[2..].split "="
    key := parts[0]
    if not (required.contains key) and not (optional.contains key):
      throw "Unknown option --$key"
    if key == "validated":
      if parts.size != 1: throw "--validated takes no value"
      result[key] = true
    else if parts.size > 1:
      result[key] = parts[1..].join "="
    else:
      if index == args.size: throw "Missing value for --$key"
      result[key] = args[index++]
  required.do: |key|
    if not result.contains key: throw "Missing --$key"
  return result

now -> int: return Time.monotonic-us / 1000

upload args/Map image/string log-path/string --reboot/bool=true:
  command := [args["uploader"], "--port", args["port"]]
  if not reboot: command.add "--no-reboot"
  command.add image
  normalized := log-path
  if system.platform == system.PLATFORM-WINDOWS:
    normalized = normalized.replace --all "\\" "/"
  slash := normalized.index-of --last "/"
  if slash >= 0: directory.mkdir --recursive normalized[..(max 1 slash)]
  log := file.Stream.for-write log-path
  process := pipe.fork command[0] command --stdout=log --stderr=log
  try:
    with-timeout --ms=90_000: process.wait
    expect-equals 0 process.exit-code
  finally:
    if process.exit-code == null:
      catch: process.kill --hard
      catch: process.wait
    log.close

class Console:
  path/string
  port/uart.HostPort? := null
  transcript/string := ""
  disconnects/int := 0
  pending_/string := ""

  constructor .path:
    open

  open:
    port = uart.HostPort path --baud-rate=115_200
    error := catch: port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR true
    if error:
      close
      throw error

  close:
    if port: port.close
    port = null

  command text/string:
    with-timeout --ms=5000: port.out.write "$text\n"

  // Reads a bounded amount while allowing USB disconnect/reconnect.
  poll --ms/int=100 -> string:
    if not port:
      error := catch: open
      if error:
        sleep --ms=50
        return ""
    text := ""
    error := catch:
      with-timeout --ms=ms:
        bytes := port.in.read
        if not bytes: throw "SERIAL_CLOSED"
        text = bytes.to-string-non-throwing
        transcript += text
    if error and error != DEADLINE-EXCEEDED-ERROR:
      close
      disconnects++
    return text

  line deadline/int -> string:
    while true:
      at := pending_.index-of "\n"
      if at >= 0:
        result := pending_[..at].trim
        pending_ = pending_[at + 1..]
        return result
      if now >= deadline: throw "Serial response deadline exceeded"
      pending_ += poll --ms=(min 100 (deadline - now))
      end := pending_.index-of "\n"
      if (end < 0 ? pending_.size : end) > 1024: throw "Device sent an overlong line"

  protocol deadline/int -> string:
    while true:
      result := line deadline
      if result.starts-with "TOIT-OTA ": return result

  info -> List:
    command "TOIT-OTA INFO"
    deadline := now + 5000
    while true:
      response := protocol deadline
      if response.starts-with "TOIT-OTA ERROR": throw response
      if not response.starts-with "TOIT-OTA INFO ": continue
      words := response.split " "
      expect-equals 6 words.size
      expect-equals "1" words[2]
      result := words[3..].map: int.parse it
      expect (result[0] == 0 or result[0] == 1)
      expect (result[1] == 0 or result[1] == 1)
      expect (result[2] > 0)
      return result
