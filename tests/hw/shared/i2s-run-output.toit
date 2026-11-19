// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Parses fragmented output without accepting a verdict for another case.
class I2sRunOutput:
  ready_/string
  pass_/string
  pending_/string := ""
  armed/bool := false
  passed/bool := false
  transmit_/bool

  constructor configuration/string --transmit/bool=false --duplex/bool=false:
    if transmit and duplex: throw "INVALID_ARGUMENT"
    transmit_ = transmit or duplex
    direction := duplex ? "DUPLEX" : (transmit ? "TX" : "RX")
    ready_ = "I2S $direction READY $configuration"
    pass_ = "I2S $direction PASS $configuration " + (transmit_ ? "errors=" : "bytes=")

  // Returns true exactly when the complete READY line arrives.
  accept text/string -> bool:
    pending_ += text
    start-peer := false
    while true:
      newline := pending_.index-of "\n"
      if newline < 0: break
      line := pending_[..newline].trim
      pending_ = pending_[newline + 1..]
      if line == ready_:
        if armed: throw "Duplicate I2S READY"
        armed = true
        start-peer = true
      else if line.starts-with pass_:
        if not armed: throw "I2S verdict before READY"
        rest := line[pass_.size..]
        if transmit_:
          if rest != "0": throw "Invalid I2S verdict"
        else:
          space := rest.index-of " "
          if space < 1 or rest[space..] != " overruns=0": throw "Invalid I2S verdict"
          if (int.parse rest[..space]) <= 0: throw "Empty I2S capture"
        passed = true
    if pending_.size > 8192: throw "Oversized I2S output line"
    return start-peer
