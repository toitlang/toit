// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

import ble.experimental.attribute-server as attributes
import ble.experimental.service.requests as bridge
import ble.experimental.service.client as clients
import ble.experimental.service.provider as providers

main:
  with-timeout --ms=10_000:
    test-mailbox
    test-expiry
    test-written-budget
    test-cancel
    test-close
    test-rpc
    test-rpc --separate-process
    test-serving-blocks
    test-client-death
    ["GATT_REQUESTS_CLOSED", "HCI_QUEUE_OVERFLOW"].do: test-handler-disconnect it

future -> int: return Time.monotonic-us + 1_000_000

test-written-budget:
  requests := bridge.Requests
  requests.written-timeout = Duration --ms=50
  ended := monitor.Latch
  worker := task::
    ended.set (catch: requests.written 3 #[42])
  try:
    record := requests.next
    expect-equals bridge.WRITTEN record[1]
    expect-equals DEADLINE-EXCEEDED-ERROR ended.get
    expect-throw "GATT_REQUEST_EXPIRED": requests.reply record[0]
    // Expiry releases the mailbox; a later accepted hook can complete.
    requests.written-timeout = Duration --s=1
    completed := monitor.Latch
    next-worker := task::
      requests.written 3 #[43]
      completed.set true
    try:
      next := requests.next
      expect-equals #[43] next[5]
      requests.reply next[0]
      completed.get
    finally:
      next-worker.cancel
  finally:
    worker.cancel
    requests.close

test-mailbox:
  requests := bridge.Requests
  ended := monitor.Latch
  proposed := #[1, 2]
  worker := task::
    try:
      expect-equals [0, #[]] (requests.exchange bridge.VALIDATE-WRITE 3 18 proposed future)
    finally:
      ended.set true
  try:
    record := requests.next
    expect-equals [bridge.VALIDATE-WRITE, 3, 18] record[1..4]
    record[5][0] = 99
    expect-equals #[1, 2] proposed
    token := record[0]
    // The recipient owns the record, but cannot alter reply validation.
    record[0] = -1
    record[1] = bridge.READ
    record[4] = 0
    expect-throw "GATT_REQUEST_BUSY": requests.exchange bridge.READ 3 10 #[] future
    expect-throw "INVALID_ARGUMENT": requests.reply token --value=#[1]
    requests.reply token
    ended.get
    expect-throw "GATT_REQUEST_EXPIRED": requests.reply token
  finally:
    requests.close
    worker.cancel

test-expiry:
  requests := bridge.Requests
  ended := monitor.Latch
  worker := task::
    try:
      expect-throw DEADLINE-EXCEEDED-ERROR: requests.exchange bridge.READ 3 10 #[] (Time.monotonic-us + 50_000)
    finally:
      ended.set true
  record := requests.next
  ended.get
  expect-throw "GATT_REQUEST_EXPIRED": requests.reply record[0] --value=#[1]
  // An expired request must not poison the next transaction.
  next-ended := monitor.Latch
  worker = task::
    try:
      expect-equals [0, #[2]] (requests.exchange bridge.READ 3 10 #[] future)
    finally:
      next-ended.set true
  next := requests.next
  expect next[0] > record[0]
  requests.reply next[0] --value=#[2]
  next-ended.get
  requests.close

test-close:
  requests := bridge.Requests
  ended := monitor.Latch
  worker := task::
    try:
      expect-throw "GATT_REQUESTS_CLOSED": requests.next
    finally:
      ended.set true
  yield
  expect-throw "GATT_REQUEST_PULL_BUSY": requests.next
  requests.close
  ended.get
  requests = bridge.Requests
  ended = monitor.Latch
  worker = task::
    try:
      expect-throw "GATT_REQUESTS_CLOSED": requests.exchange bridge.READ 3 10 #[] future
    finally:
      ended.set true
  record := requests.next
  requests.close
  ended.get
  expect-throw "GATT_REQUESTS_CLOSED": requests.reply record[0]

test-rpc --separate-process/bool=false:
  provider := TestProvider
  provider.install
  try:
    if separate-process:
      spawn:: rpc-client
    else:
      rpc-client
    provider.uninstall --wait
    expect-equals #[0x0b, 7, 8] provider.read-result
    expect-equals #[0x13] provider.write-result
    expect-equals #[5, 6] provider.value
    expect provider.closed
  finally:
    provider.uninstall

rpc-client:
  client := clients.Client
  client.open
  session := client.session
  try:
    // The sole session cannot be acquired by another client.
    other := clients.Client
    other.open
    try:
      expect-throw "GATT_SERVICE_BUSY": other.session
    finally:
      other.close
    read := session.next
    expect-equals bridge.READ read.kind
    sleep --ms=25
    read.reply #[7, 8]
    expect-throw "GATT_ALREADY_REPLIED": read.reply #[9]
    write := session.next
    expect-equals #[5, 6] write.value
    write.value[0] = 99
    write.accept
    written := session.next
    expect-equals #[5, 6] written.value
    written.accept
  finally:
    session.close
    client.close

class TestProvider extends providers.Provider:
  read-result/ByteArray? := null
  write-result/ByteArray? := null
  value/ByteArray? := null
  closed/bool := false
  current/TestSession? := null

  constructor:
    super

  create-session client/int -> providers.Session:
    current = TestSession this client
    return current

class TestSession extends providers.Session:
  provider_/TestProvider
  worker_/Task? := null

  constructor .provider_ client/int:
    super provider_ client
    worker_ = task::
      database := attributes.Database
      database.add-service #[0x00, 0x18]
      handle := database.add-characteristic #[0x01, 0x2a] --read --write --dynamic-read --validate-write
      session := database.session
      try:
        provider_.read-result = session.request #[0x0a, 3, 0]
            (: | read/attributes.ReadRequest | requests.read read)
            (: | write/attributes.WriteRequest | requests.validate write)
        provider_.write-result = session.request #[0x12, 3, 0, 5, 6]
            (: | read/attributes.ReadRequest | requests.read read)
            (: | write/attributes.WriteRequest | requests.validate write)
        provider_.value = database.value handle
        session.writes-do: | h/int value/ByteArray | requests.written h value
      finally:
        session.close

  on-closed -> none:
    super
    if worker_: worker_.cancel
    provider_.closed = true

test-client-death:
  provider := TestProvider
  provider.install
  try:
    spawn::
      client := clients.Client
      client.open
      session := client.session
      request := session.next
      expect-equals bridge.READ request.kind
      // Process exit must close the service resource without an explicit reply.
    provider.uninstall --wait
    expect provider.closed
    expect-null provider.read-result
    expect-null provider.write-result
  finally:
    provider.uninstall


test-serving-blocks:
  provider := TestProvider
  provider.install
  try:
    spawn:: serving-client
    provider.uninstall --wait
    expect-equals #[0x0b, 7, 8] provider.read-result
    expect-equals #[0x13] provider.write-result
    expect provider.closed
  finally:
    provider.uninstall

serving-client:
  client := clients.Client
  client.open
  saved/clients.Request? := null
  try:
    session := client.session
    session.serve
        (: | request/clients.Request |
          saved = request
          request.reply #[7, 8])
        (: | request/clients.Request |
          expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[9]
          request.accept)
        (: | handle/int value/ByteArray |
          expect-equals 3 handle
          expect-equals #[5, 6] value
          // Non-local return must still release the session and serving task.
          return)
  finally:
    client.close


test-handler-disconnect reason/string:
  provider := TestProvider
  provider.install
  client := clients.Client
  client.open
  session := client.session
  started := monitor.Latch
  ended := monitor.Latch
  cleaned := false
  saved/clients.Request? := null
  worker := task::
    try:
      session.serve
          (: | request/clients.Request |
            saved = request
            started.set true
            try:
              sleep --ms=10_000
            finally:
              cleaned = true)
          (: | request/clients.Request | request.accept)
          (: | handle/int value/ByteArray | unreachable)
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    started.get
    provider.current.requests.close --error=reason
    provider.current.close
    with-timeout --ms=200: ended.get
    expect cleaned
    expect worker.is-canceled
    expect-equals reason session.termination-reason
    expect-throw "GATT_REQUEST_EXPIRED": saved.reply #[1]
  finally:
    session.close
    client.close
    provider.uninstall


test-cancel:
  requests := bridge.Requests
  ended := monitor.Latch
  worker := task::
    try:
      requests.exchange bridge.READ 3 10 #[] future
    finally:
      critical-do --no-respect-deadline: ended.set true
  record := requests.next
  worker.cancel
  ended.get
  expect-throw "GATT_REQUEST_EXPIRED": requests.reply record[0] --value=#[1]
  // Cancellation removes the record rather than leaving the queue occupied.
  next-ended := monitor.Latch
  worker = task::
    try:
      expect-equals [0, #[2]] (requests.exchange bridge.READ 3 10 #[] future)
    finally:
      next-ended.set true
  next := requests.next
  requests.reply next[0] --value=#[2]
  next-ended.get
  requests.close
