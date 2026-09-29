// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** Security levels, as required by an application and as achieved by a link. */
SECURITY-NONE ::= 0
/** The link is encrypted; pairing may have been Just Works. */
SECURITY-ENCRYPTED ::= 1
/** The link is encrypted with a key from authenticated (MITM-protected) pairing. */
SECURITY-AUTHENTICATED ::= 2

/** This device's role on a link: it connected to a peripheral. */
ROLE-CENTRAL ::= 0
/** This device's role on a link: a central connected to it. */
ROLE-PERIPHERAL ::= 1

/** The LE 1M PHY every link starts on. */
PHY-1M ::= 1
/** The LE 2M PHY: twice the symbol rate, a little less range. */
PHY-2M ::= 2
/** The LE Coded PHY: long range, low rate. */
PHY-CODED ::= 3

/**
A Bluetooth device address with its type.

$bytes are in the order used on the air and in HCI (least significant byte
  first); $stringify prints the usual most-significant-first form.
*/
class Address:
  static PUBLIC ::= 0
  static RANDOM ::= 1

  bytes_/ByteArray
  type/int

  /** An address from its six HCI-order bytes. */
  constructor bytes/ByteArray --.type=PUBLIC:
    if bytes.size != 6 or not 0 <= type <= 1: throw "INVALID_ARGUMENT"
    bytes_ = bytes.copy

  /** Parses "aa:bb:cc:dd:ee:ff", most significant byte first. */
  constructor.parse text/string --random/bool=false:
    parts := text.split ":"
    if parts.size != 6: throw "INVALID_ARGUMENT"
    bytes_ = ByteArray 6: int.parse parts[5 - it] --radix=16
    type = random ? RANDOM : PUBLIC

  /** The six address bytes, least significant first. */
  bytes -> ByteArray: return bytes_.copy

  is-random -> bool: return type == RANDOM

  operator == other -> bool:
    return other is Address and type == other.type and bytes_ == other.bytes_

  hash-code -> int: return bytes_[0] | (bytes_[1] << 8) | (bytes_[2] << 16)

  stringify -> string:
    text := (List 6: "$(%02x bytes_[5 - it])").join ":"
    return is-random ? "$text (random)" : text

/** The PHYs a link uses in each direction ($PHY-1M, $PHY-2M, $PHY-CODED). */
class Phy:
  tx/int
  rx/int

  constructor .tx .rx:

  operator == other -> bool: return other is Phy and tx == other.tx and rx == other.rx
  hash-code -> int: return tx * 4 + rx

  stringify -> string: return tx == rx ? name_ tx : "tx $(name_ tx), rx $(name_ rx)"

  static name_ phy/int -> string:
    if phy == PHY-1M: return "1M"
    if phy == PHY-2M: return "2M"
    if phy == PHY-CODED: return "Coded"
    return "PHY $phy"

/** The link-layer payload sizes in effect, in octets per packet. */
class DataLength:
  tx-octets/int
  rx-octets/int

  constructor .tx-octets .rx-octets:

  stringify -> string: return "tx $tx-octets, rx $rx-octets octets"

/**
Connection parameters: how often the two devices meet and how long a
  silent link survives.
*/
class ConnectionParameters:
  /** The connection interval in units of 1.25 ms. */
  interval-units/int
  /** The number of connection events the peripheral may skip. */
  latency/int
  /** The supervision timeout in units of 10 ms. */
  timeout-units/int

  constructor .interval-units .latency .timeout-units:

  interval -> Duration: return Duration --us=interval-units * 1250
  supervision-timeout -> Duration: return Duration --ms=timeout-units * 10

  stringify -> string:
    return "interval $(interval-units * 1.25) ms, latency $latency, timeout $(timeout-units * 10) ms"

/**
Why a link ended.

$code is the HCI reason (Core Vol 1 Part F), or null when the link ended
  without one, for example because the provider failed; $message then says
  what happened.
*/
class DisconnectReason:
  code/int?
  message/string?

  constructor .code --.message=null:

  /** The central or peripheral application on the other side ended the link. */
  static REMOTE-USER ::= 0x13
  /** This side ended the link. */
  static LOCAL-HOST ::= 0x16
  /** The peer stopped answering for a supervision timeout. */
  static TIMEOUT ::= 0x08
  /** The link-layer's message integrity check failed. */
  static MIC-FAILURE ::= 0x3d
  /** The link never got going after the connection request. */
  static FAILED-TO-ESTABLISH ::= 0x3e

  stringify -> string:
    if code == null: return message or "unknown"
    name := NAMES_.get code
    hex := "0x$(%02x code)"
    return name ? "$name ($hex)" : "reason $hex"

  static NAMES_ ::= {
    0x05: "authentication failure",
    0x08: "connection timeout",
    0x13: "remote user terminated",
    0x14: "remote device low resources",
    0x15: "remote device power off",
    0x16: "local host terminated",
    0x1a: "unsupported remote feature",
    0x22: "link layer response timeout",
    0x28: "instant passed",
    0x3b: "unacceptable connection parameters",
    0x3d: "MIC failure",
    0x3e: "failed to establish",
  }

/**
An ATT error: the peer's answer to a request (on the central side), or the
  answer a handler gives to a central (on the peripheral side).
*/
class AttError:
  static READ-NOT-PERMITTED ::= 0x02
  static WRITE-NOT-PERMITTED ::= 0x03
  static INSUFFICIENT-AUTHENTICATION ::= 0x05
  static REQUEST-NOT-SUPPORTED ::= 0x06
  static INVALID-OFFSET ::= 0x07
  static INSUFFICIENT-AUTHORIZATION ::= 0x08
  static ATTRIBUTE-NOT-FOUND ::= 0x0a
  static INVALID-ATTRIBUTE-VALUE-LENGTH ::= 0x0d
  static UNLIKELY-ERROR ::= 0x0e
  static INSUFFICIENT-ENCRYPTION ::= 0x0f
  static VALUE-NOT-ALLOWED ::= 0x13

  /** The ATT error code; application codes are 0x80 to 0x9f. */
  code/int
  /** The handle the error concerns, or 0 when not known. */
  handle/int
  /** The request opcode the error answers, or 0 when not known. */
  request/int

  constructor .code --.handle=0 --.request=0:
    if not 1 <= code <= 0xff: throw "INVALID_ARGUMENT"

  stringify -> string: return "ATT error 0x$(%02x code) (handle $handle)"

/** What the BLE service and its controller support. */
class Capabilities:
  /** Whether the provider scans. */
  scanning/bool
  /** Whether the provider connects to peripherals. */
  central/bool
  /** Whether the provider serves centrals from a GATT server. */
  peripheral/bool
  /** Whether the provider broadcasts without connections. */
  advertising/bool
  /** The largest attribute value in bytes. */
  max-value-size/int
  /** The largest ATT MTU the provider negotiates. */
  max-mtu/int

  constructor --.scanning --.central --.peripheral --.advertising --.max-value-size --.max-mtu:
