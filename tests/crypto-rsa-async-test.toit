// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the file `LICENSE` in the tests directory.

import crypto.rsa
import expect show *
import monitor show ResourceState_

main:
  test-concurrent-generation
  test-close-pending-generation

test-concurrent-generation:
  requests := []
  try:
    // Submit all requests before waiting for any completion.
    8.repeat: requests.add (Generation 1024)
    requests.do: | request/Generation |
      verify-pair request.finish
  finally:
    requests.do: it.close

  // Exercise the public API with callers sharing the worker thread.
  pairs := Task.group (List 4: (:: rsa.RsaKey.generate --bits=1024))
  pairs.values.do: | pair/rsa.RsaKeyPair |
    message := "Concurrent RSA generation"
    expect (pair.verify message (pair.sign message))

test-close-pending-generation:
  // Closing the group must be safe both during generation and while queued.
  8.repeat:
    request := Generation 1024
    request.close
  // Completion of this request also drains the earlier abandoned requests.
  request := Generation 1024
  try:
    verify-pair request.finish
  finally:
    request.close

verify-pair pair/List:
  private-key := rsa.RsaKey.parse-private pair[0]
  public-key := rsa.RsaKey.parse-public pair[1]
  message := "Queued RSA generation"
  expect (public-key.verify message (private-key.sign message))

class Generation:
  group_ := null
  state_ := null

  constructor bits/int:
    group_ = generate-init
    succeeded := false
    try:
      resource := generate-start group_ bits
      state_ = ResourceState_ group_ resource
      succeeded = true
    finally:
      if not succeeded: close

  finish -> List:
    state_.wait
    return generate-finish state_.resource

  close:
    if not group_: return
    if state_: state_.dispose
    generate-close group_
    group_ = null

generate-init:
  #primitive.crypto.rsa-generate-init

generate-start group bits/int:
  #primitive.crypto.rsa-generate-start

generate-finish resource -> List:
  #primitive.crypto.rsa-generate-finish

generate-close group:
  #primitive.crypto.rsa-generate-close
