// Copyright (C) 2026 Toit contributors.
import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.security-owner show Owner
import ble.experimental.security
import ble.experimental.pairing-attempts as retry
import ble.experimental.service.gatt-provider as gatt
import encoding.hex
import system

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    if provider.confirmations != 2: throw "WRONG_CONFIRMATION_COUNT"
    print "RETRY_PROVIDER COMPLETE confirmations=2"
  finally:
    provider.uninstall

class Provider extends gatt.Provider:
  attempts/retry.Attempts ::= retry.Attempts --minimum=(Duration --s=10)
  confirmations/int := 0
  round/int := -1
  radio/Radio? := null
  constructor: super
  pairing-attempts -> retry.Attempts: return attempts
  pairing-io-capability -> int?: return 1
  require-authentication -> bool: return true
  open-transport -> transport.Transport:
    round++
    radio = Radio
    return radio
  confirm-pairing number/int -> bool:
    confirmations++
    print "RETRY_PROVIDER NUMERIC round=$round value=$number approve=$(round == 2)"
    return round == 2
  run-security-owner owner/Owner -> none:
    started := Time.monotonic-us --since-wakeup
    error := catch: super owner
    pairing-owner := owner as security.Pairing
    reason := pairing-owner.failure-reason
    if error: owner.close
    system.process-stats --gc
    if pairing-owner.failure-reason != reason: throw "RETRY_FAILURE_REASON_LOST"
    if reason != (round == 0 ? 12 : null): throw "RETRY_FAILURE_REASON_WRONG"
    print "RETRY_PROVIDER FAILURE round=$round reason=$reason retained=true"
    print "RETRY_PROVIDER RESULT round=$round error=$error encrypted=$(owner.encrypted) smp=$(radio.smp-packets) awake=$started finished=$((Time.monotonic-us --since-wakeup))"
    if round == 1 and (error != "SMP_REPEATED_ATTEMPTS" or radio.smp-packets != 0):
      throw "RETRY_ADMISSION_NOT_ENFORCED"
    if error: throw error

class Radio implements transport.Transport:
  inner/transport.Transport ::= esp32.Esp32Transport
  smp-packets/int := 0
  metadata/int := 0
  receive -> ByteArray:
    packet := inner.receive
    if metadata < 30 and packet.size >= 8 and packet[0] == 4 and packet[1] == 0x3e and (packet[3] == 1 or packet[3] == 0x0a):
      metadata++
      print "RETRY_RADIO CONNECTION status=$(packet[4]) handle=$(packet[5] + 256 * packet[6]) role=$(packet[7]) awake=$((Time.monotonic-us --since-wakeup))"
    if metadata < 30 and packet.size >= 3 and packet[0] == 4 and (packet[1] == 0x13 or packet[1] == 5):
      metadata++
      print "RETRY_RADIO EVENT value=$(hex.encode packet) awake=$((Time.monotonic-us --since-wakeup))"
    return packet
  send packet/ByteArray -> none:
    if packet.size >= 9 and packet[0] == 2 and packet[7] == 6 and packet[8] == 0:
      smp-packets++
    inner.send packet
  send-if packet/ByteArray [allowed] -> bool:
    if not allowed.call: return false
    send packet
    return true
  close -> none: inner.close
