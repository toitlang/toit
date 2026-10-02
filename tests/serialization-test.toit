// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *
import monitor show Channel
import system
import system.containers show current-image-id_

test-atom object:
  expect-equals
      object
      tison.decode
          tison.encode object

test-array array:
  result := tison.decode
      tison.encode array
  expect-equals array.size result.size
  for i := 0; i < array.size; i++:
    expect-equals array[i] result[i]

test-map:
  map := Map
  map["1"] = "1"
  map["45"] = "45"
  result := tison.decode (tison.encode map)
  expect-equals result["1"] "1"
  expect-equals result["45"] "45"
  expect (not result.contains 2)

main:
  test-atom 12
  test-atom true
  test-atom false
  test-atom null
  test-atom ""
  test-atom "Fiskerdreng"
  test-array (Array_ 0)
  // No cycles, no reuse array.
  a := Array_ 4
  a[0] = 12
  a[1] = true
  a[2] = false
  a[3] = null
  test-array a
  // With strings.
  a = Array_ 4
  a[0] = "Fiskerdreng"
  a[1] = ""
  a[2] = "Fiskerdreng"
  a[3] = ""
  test-array a
  a = Array_ 1
  a[0] = "Fisk"
  test-array a
  c := 75
  test-map
  test-throwing-process-send
  test-tison-throwing
  test-proxy-process-send
  test-external-message-limit
  test-nonowned-message-preflight
  test-message-ownership

class Unserializable:

test-nonowned-message-preflight:
  // Non-disposable image bytes must be copied inline, not reserve transfer
  // slots. The guard keeps the old encoder from handing image memory away.
  expect-throw "SERIALIZATION_FAILED":
    process-send_ 100000000 -10 [(List 9: current-image-id_), Unserializable]

class TestMessageHandler implements SystemMessageHandler_:
  static TYPE ::= 123
  messages/Channel ::= Channel 1

  on-message type/int gid/int pid/int message/any -> none:
    expect-equals TYPE type
    expect-equals process-current-id_ pid
    messages.send message

  roundtrip message:
    expect (process-send_ process-current-id_ TYPE message)
    return messages.receive

test-message-ownership:
  handler := TestMessageHandler
  set-system-message-handler_ TestMessageHandler.TYPE handler
  try:
    with-timeout --ms=10000:
      // Exactly eight external references must decode in every mixture of
      // transferred buffers and copied slices, not just the all-one-kind cases.
      9.repeat: | transferred |
        buffers := List 8: ByteArray.external 256
        message := List 8: | i |
          buffers[i].fill i
          i < transferred ? buffers[i] : buffers[i][1..]
        result := handler.roundtrip message
        expect-equals 8 result.size
        8.repeat: | i |
          expect-equals (i < transferred ? 0 : 256) buffers[i].size
          expect-equals (i < transferred ? 256 : 255) result[i].size
          result[i].do: expect-equals i it

      // Repeated direct references, a nested map, slices and COW wrappers
      // must all preserve bytes without creating multiple malloc owners.
      [0, 1, 128, 129, 256, 4096].do: | length |
        bytes := (ByteArray.external length) as ByteArray_
        bytes.fill 42
        message := [bytes, {"data": bytes}, bytes[..], CowByteArray_ bytes]
        result := handler.roundtrip message
        expect-equals 0 bytes.size
        copies := [result[0], result[1]["data"], result[2], result[3]]
        copies.do: | copy |
          expect-equals length copy.size
          copy.do: expect-equals 42 it
        if length != 0:
          copies[0][0] = 99
          3.repeat: expect-equals 42 copies[it + 1][0]
        system.process-stats --gc
        copies.do: expect-equals length it.size

        discarded := ByteArray.external length
        expect-not (process-send_ 100000000 -10 [discarded, discarded])
        expect-equals 0 discarded.size

      // Image IDs are raw external bytes, but their program-owned backing
      // cannot be neutered or freed by the receiver or a dropped message.
      id := current-image-id_
      saved := id.copy
      result := handler.roundtrip id
      expect-equals saved result
      result[0] = result[0] ^ 255
      expect-equals saved id
      expect-not (process-send_ 100000000 -10 id)
      expect-equals saved id
      system.process-stats --gc
  finally:
    clear-system-message-handler_ TestMessageHandler.TYPE

test-external-message-limit:
  // Transferred buffers and copied slices share the decoder's eight slots.
  // A trailing guard keeps a broken size pass from committing any transfers.
  10.repeat: | transferred |
    buffers := List 9: ByteArray.external 256
    message := List 9: | i |
      buffers[i].fill i
      i < transferred ? buffers[i] : buffers[i][1..]
    message.add Unserializable
    expect-throw "TOO_MANY_EXTERNALS":
      process-send_ 100000000 -10 message
    message.remove-last
    expect-throw "TOO_MANY_EXTERNALS":
      process-send_ process-current-id_ TestMessageHandler.TYPE message
    buffers.do: | buffer |
      expect-equals 256 buffer.size
      expect-equals buffer[0] buffer[255]

test-proxy-process-send:
  proxy := get-generic-resource-group_
  bytes := ByteArray.external 256
  bytes.fill 42
  // The trailing unserializable object prevents the old encoder from
  // committing a transfer of the native resource pointer during this test.
  // The proxy must be rejected first, before inspecting that object.
  expect-throw "WRONG_OBJECT_TYPE":
    process-send_ 100000000 -10 [bytes, proxy, Unserializable]
  expect-equals 256 bytes.size
  bytes.do: expect-equals 42 it
  expect-not proxy.is-raw-bytes_
  expect-throw "WRONG_OBJECT_TYPE": tison.encode proxy
  // Rejection must also be safe without the trailing guard, including when
  // the receiver is this process and could otherwise take over the pointer.
  [100000000, process-current-id_].do: | pid |
    expect-throw "WRONG_OBJECT_TYPE": process-send_ pid -10 proxy
    expect-throw "WRONG_OBJECT_TYPE": process-send_ pid -10 [bytes, proxy]
    expect-equals 256 bytes.size
    bytes.do: expect-equals 42 it
    expect-not proxy.is-raw-bytes_

test-throwing-process-send:
  l := List 10: ByteArray.external 100
  expect-throw "TOO_MANY_EXTERNALS": process-send_ 0 0 l
  expect-not (process-send_ 100000000 -10 #[])
  l = []
  l.add l
  expect-throw "NESTING_TOO_DEEP": process-send_ 0 0 l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect-throw "SERIALIZATION_FAILED": process-send_ 0 0 l
  // We had an issue where sending an object with an embedded map
  // would lead to a crash during deallocation -- but only if sent
  // to a non-existing process. Check that it now works.
  mappy := [ {"foo": "bar"}, #[1, 2, 3] ]
  expect-not (process-send_ 100000000 -10 mappy)

test-tison-throwing:
  l := []
  l.add l
  expect-throw "NESTING_TOO_DEEP": tison.encode l
  l = [Unserializable]
  // We catch this, which means we don't get information about which class failed.
  // If we left it uncaught, the stack trace decoder would tell us.
  expect-throw "SERIALIZATION_FAILED": tison.encode l
