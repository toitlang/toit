// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the file `LICENSE` in the tests directory.

import crypto.rsa
import expect show *
import monitor show ResourceState_

main:
  // A heartbeat distinguishes a waiting worker from a blocked VM scheduler.
  heartbeat := task::
    while true:
      sleep --ms=5_000
      log "Scheduler heartbeat"
  try:
    log "Testing concurrent RSA generation"
    test-concurrent-generation
    log "Testing abandoned RSA generation"
    test-close-pending-generation
    log "All asynchronous RSA tests passed"
  finally:
    heartbeat.cancel

log message/string:
  print "[RSA $(Time.monotonic-us / 1_000) ms] $message"

test-concurrent-generation:
  requests := []
  try:
    // Submit all requests before waiting for any completion.
    // One running request and two queued requests are enough to test the queue.
    3.repeat: | i | requests.add (Generation "queued-$i" 1024)
    requests.do: | request/Generation |
      verify-pair request.finish
  finally:
    requests.do: it.close

  // Exercise the public API with callers sharing the worker thread.
  log "Testing concurrent RSA generation through the public API"
  pairs := Task.group (List 2: | i | (:: generate-pair i))
  pairs.values.do: | pair/rsa.RsaKeyPair |
    message := "Concurrent RSA generation"
    expect (pair.verify message (pair.sign message))
  log "Public API signatures verified"

generate-pair id/int -> rsa.RsaKeyPair:
  log "public-$id: generating key"
  pair := rsa.RsaKey.generate --bits=1024
  log "public-$id: key generated"
  return pair

test-close-pending-generation:
  // Closing the group must be safe both during generation and while queued.
  2.repeat: | i |
    request := Generation "abandoned-$i" 1024
    request.close
  // Completion of this request also drains the earlier abandoned requests.
  request := Generation "drain" 1024
  try:
    verify-pair request.finish
  finally:
    request.close

verify-pair pair/List:
  log "Parsing and verifying generated key pair"
  private-key := rsa.RsaKey.parse-private pair[0]
  public-key := rsa.RsaKey.parse-public pair[1]
  message := "Queued RSA generation"
  expect (public-key.verify message (private-key.sign message))
  log "Generated key pair verified"

class Generation:
  name/string
  group_ := null
  state_ := null

  constructor .name bits/int:
    log "$name: submitting $(bits)-bit key generation"
    group_ = generate-init
    succeeded := false
    try:
      resource := generate-start group_ bits
      log "$name: submitted"
      state_ = ResourceState_ group_ resource
      succeeded = true
    finally:
      if not succeeded: close

  finish -> List:
    log "$name: waiting for completion"
    state_.wait
    log "$name: completion event received"
    result := generate-finish state_.resource
    log "$name: key retrieved"
    return result

  close:
    if not group_: return
    log "$name: closing resource group"
    if state_: state_.dispose
    generate-close group_
    group_ = null
    log "$name: resource group closed"

generate-init:
  #primitive.crypto.rsa-generate-init

generate-start group bits/int:
  #primitive.crypto.rsa-generate-start

generate-finish resource -> List:
  #primitive.crypto.rsa-generate-finish

generate-close group:
  #primitive.crypto.rsa-generate-close
