// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.central
import expect show *
import monitor
import system
import .ble-hci-test as fixture

ACL ::= #[2, 0x34, 2, 3, 0, 7, 8, 9]
COMPLETED ::= #[1, 0x35, 0x0c, 5, 1, 0x34, 2, 1, 0]
DISCONNECTED ::= #[4, 5, 4, 0, 0x34, 2, 0x13]

main:
  with-timeout --ms=10_000:
    zero-command-credits
    deferred-reuse
    canceled-consumer
    canceled-consumer --failed-return
    canceled-credit-write
    credit-write-timeout
    failed-submission
    failed-consumption --failed-return=false
    failed-consumption --failed-return
    setup-failures
    rejected-input --unknown
    rejected-input --no-unknown

initialize-radio radio/fixture.FakeTransport --count/int=1:
  fixture.initialize-replies radio --receive-flow
  fixture.reply radio #[1, 0x33, 0x0c, 7, 0, 4, 0, count, 0, 0, 0] #[]
  fixture.reply radio #[1, 0x31, 0x0c, 1, 1] #[]

connected controller/hci.Controller radio/fixture.FakeTransport -> ByteArray:
  radio.received.add fixture.connection-event.copy
  expect-equals fixture.connection-event controller.receive
  bytes := ACL.copy
  radio.received.add bytes
  expect-identical bytes controller.receive
  return bytes

zero-command-credits:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  responder := task::
    initialize-radio radio
    // An opcode-zero completion changes ordinary command credits without a reply.
    radio.received.add #[4, 0x0e, 3, 0, 0, 0]
    radio.received.add #[4, 0xff, 0]
    expect-equals COMPLETED radio.sent.take
    // There is deliberately no success event for Host Completed Packets.
    radio.received.add #[4, 0x0e, 3, 1, 0, 0]
    fixture.reply radio #[1, 9, 16, 0] #[1, 2, 3, 4, 5, 6]
  ordinary/Task? := null
  try:
    hci.initialize controller --receive-acl-packets=1
    expect controller.receive-flow-control
    expect-equals #[4, 0xff, 0] controller.receive
    packet := connected controller radio
    result := monitor.Latch
    ordinary = task:: result.set (controller.command hci.READ-ADDRESS)
    expect-equals 42 (controller.consume packet:
      system.process-stats --gc
      42)
    expect-equals #[1, 2, 3, 4, 5, 6] result.get
    controller.check-open_
  finally:
    if ordinary: ordinary.cancel
    responder.cancel
    controller.close
    controller.wait-closed

deferred-reuse:
  radio := DeferredRadio
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  worker/Task? := null
  try:
    hci.initialize controller --receive-acl-packets=1
    packet := connected controller radio
    baseline := radio.sent-count
    ended := monitor.Latch
    worker = task::
      controller.consume packet: null
      ended.set true
    radio.entered.get
    radio.received.add DISCONNECTED.copy
    radio.received.add fixture.connection-event.copy
    expect-equals DISCONNECTED controller.receive
    expect-equals fixture.connection-event controller.receive
    replacement := ACL.copy
    radio.received.add replacement
    expect-identical replacement controller.receive
    radio.resume.set true
    ended.get
    expect-equals baseline radio.sent-count
    controller.consume replacement: null
    expect-equals COMPLETED radio.sent.take
    expect-equals baseline + 1 radio.sent-count
  finally:
    if worker: worker.cancel
    initializer.cancel
    controller.close
    controller.wait-closed

canceled-consumer --failed-return/bool=false:
  radio := failed-return ? FailedRadio : fixture.FakeTransport
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  worker/Task? := null
  try:
    hci.initialize controller --receive-acl-packets=1
    expect-throw "HCI_RX_EARLY_ACL_UNSUPPORTED":
      central.Central controller --early-acl-timeout=(Duration --ms=20)
    packet := connected controller radio
    started := monitor.Latch
    ended := monitor.Latch
    worker = task::
      try:
        controller.consume packet:
          started.set true
          sleep --ms=10_000
      finally:
        critical-do --no-respect-deadline: ended.set true
    started.get
    worker.cancel
    with-timeout --ms=200: ended.get
    if failed-return:
      expect radio.closed
      expect-throw "HCI_RX_CREDIT_RETURN_FAILED": controller.receive
    else:
      expect-equals COMPLETED radio.sent.take
      controller.check-open_
  finally:
    if worker: worker.cancel
    initializer.cancel
    controller.close
    controller.wait-closed

failed-submission:
  radio := FailedRadio
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  try:
    hci.initialize controller --receive-acl-packets=1
    packet := connected controller radio
    expect-throw "TEST_RX_RETURN_FAILED": controller.consume packet: null
    expect radio.closed
    expect-throw "HCI_RX_CREDIT_RETURN_FAILED": controller.receive
  finally:
    initializer.cancel
    controller.close
    controller.wait-closed

canceled-credit-write:
  radio := DeferredRadio
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  worker/Task? := null
  try:
    hci.initialize controller --receive-acl-packets=1
    packet := connected controller radio
    ended := monitor.Latch
    worker = task::
      try:
        controller.consume packet: null
      finally:
        critical-do --no-respect-deadline: ended.set true
    radio.entered.get
    worker.cancel
    sleep --ms=10
    expect (not ended.has-value)
    radio.resume.set true
    with-timeout --ms=200: ended.get
    expect-equals COMPLETED radio.sent.take
    controller.check-open_
  finally:
    if worker: worker.cancel
    initializer.cancel
    controller.close
    controller.wait-closed

credit-write-timeout:
  radio := DeferredRadio
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  try:
    hci.initialize controller --receive-acl-packets=1
    packet := connected controller radio
    // Never release the deferred write; its own deadline must fail the owner.
    expect-throw "DEADLINE_EXCEEDED": controller.consume packet: null
    expect radio.closed
    expect-throw "HCI_RX_CREDIT_RETURN_FAILED": controller.receive
  finally:
    initializer.cancel
    controller.close
    controller.wait-closed

failed-consumption --failed-return/bool:
  radio := failed-return ? FailedRadio : fixture.FakeTransport
  controller := hci.Controller radio
  initializer := task:: initialize-radio radio
  try:
    hci.initialize controller --receive-acl-packets=1
    packet := connected controller radio
    expect-throw "TEST_PACKET_PROCESSING_FAILED":
      controller.consume packet: throw "TEST_PACKET_PROCESSING_FAILED"
    if failed-return:
      expect radio.closed
      expect-throw "HCI_RX_CREDIT_RETURN_FAILED": controller.receive
    else:
      expect-equals COMPLETED radio.sent.take
      controller.check-open_
      // A subsequent packet must be admitted and credited: no window leak.
      next := ACL.copy
      radio.received.add next
      expect-identical next controller.receive
      controller.consume next: null
      expect-equals COMPLETED radio.sent.take
  finally:
    initializer.cancel
    controller.close
    controller.wait-closed

class DeferredRadio extends fixture.FakeTransport:
  entered/monitor.Latch ::= monitor.Latch
  resume/monitor.Latch ::= monitor.Latch
  deferred_/bool := false

  send-if bytes/ByteArray [allowed] -> bool:
    if not deferred_:
      deferred_ = true
      entered.set true
      resume.get
    return super bytes allowed

class FailedRadio extends fixture.FakeTransport:
  send-if bytes/ByteArray [allowed] -> bool: throw "TEST_RX_RETURN_FAILED"

setup-failures:
  [false, true].do: | supported/bool |
    radio := fixture.FakeTransport
    controller := hci.Controller radio
    responder := task::
      fixture.initialize-replies radio --receive-flow=supported
      if supported:
        expect-equals #[1, 0x33, 0x0c, 7, 0, 4, 0, 1, 0, 0, 0] radio.sent.take
        radio.received.add #[4, 0x0e, 4, 1, 0x33, 0x0c, 0x11]
    try:
      error := catch: hci.initialize controller --receive-acl-packets=1
      if supported:
        expect (error is hci.CommandError and error.status == 0x11)
        expect radio.closed
        expect-throw "HCI_RX_CONFIGURATION_FAILED": controller.receive
      else:
        expect-equals "HCI_RX_FLOW_UNSUPPORTED" error
        expect (not controller.receive-flow-control)
    finally:
      responder.cancel
      controller.close
      controller.wait-closed

rejected-input --unknown/bool:
  radio := fixture.FakeTransport
  controller := hci.Controller radio
  responder := task:: initialize-radio radio
  try:
    hci.initialize controller --receive-acl-packets=1
    if not unknown:
      connected controller radio
    radio.received.add ACL.copy
    expected := unknown ? "HCI_RX_UNKNOWN_HANDLE" : "HCI_RX_WINDOW_EXCEEDED"
    expect-throw expected: controller.receive
    expect radio.closed
  finally:
    responder.cancel
    controller.close
    controller.wait-closed
