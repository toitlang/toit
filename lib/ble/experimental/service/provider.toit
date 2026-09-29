// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services

import .api as api
import .requests as bridge

/** RPC ownership with exclusive radio modes and bounded connection sharing. */
abstract class Provider extends services.ServiceProvider implements services.ServiceHandler:
  // Reserve the supported ownership slots before opening any controller.
  // Registering a successfully created session must not grow a list afterward.
  // Eight slots cover every configuration (two shared sessions, or up to
  // eight peripheral sessions); admission never uses more than configured.
  sessions_/List ::= List 8
  opening_/bool := false

  constructor:
    super "toit.io/experimental/ble" --major=0 --minor=17
    provides api.SELECTOR --handler=this

  /**
  Bounds simultaneous peripheral sessions on one shared controller.

  One by default: the peripheral owns the controller exclusively. A provider
    that returns more lets that many clients (or one client several times)
    serve a central each on a shared host, advertising again while
    connected; central sessions are then refused while any peripheral
    session exists. At most eight.
  */
  peripheral-session-limit -> int: return 1

  /** Bounds simultaneous central sessions (at most eight); other radio modes stay exclusive. */
  central-session-limit -> int: return 1

  /**
  Lets central and peripheral sessions share the controller, each up to its
    own limit; without it they exclude each other.
  */
  mixed-role-sessions -> bool: return false

  /** Creates a session whose close hook releases its protocol resources. */
  abstract create-session client/int -> Session

  /**
  Describes configured software operations without opening the controller.

  The wire fields are flags, maximum scan duration in microseconds, maximum
    GATT value bytes, maximum ATT MTU and simultaneous controller-owning sessions.
    Zero denotes an unsupported operation. This reports neither controller
    availability nor security policy. Specialized providers override conservatively.
  */
  capabilities -> List: return [0, 0, 0, 0, 1]

  /** Opens a scan with bounded queues; unsupported by providers without scanning. */
  create-scan client/int arguments/List -> Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /** Opens non-connectable advertising when supported by the provider. */
  create-advertising client/int arguments/List -> Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /** Opens a central-role connection when supported by the provider. */
  create-connection client/int arguments/List -> Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /** Opens a client-defined database; unsupported by non-GATT providers. */
  create-builder client/int name/string -> Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /** Opens a builder with explicit bounds; subclasses may support larger values. */
  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> Session:
    if value-limit != 20 or mtu-limit != 23: throw "GATT_UNSUPPORTED_SERVICE_OPERATION"
    return create-builder client name

  /**
  Describes the controller as [identity address, transmit power control,
    advertising transmit power or null, 2M PHY support].

  Unsupported by providers without a controller.
  */
  adapter-info -> List:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /** Sets the controller's transmit power in dBm and returns the level used. */
  set-tx-power dbm/int -> int:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  /**
  Runs $block while no session holds or is opening the controller.

  Throws GATT_SERVICE_BUSY otherwise. Session admission is refused while the
    block runs, so it may open the controller briefly.
  */
  with-idle-controller_ [block]:
    if opening_: throw "GATT_SERVICE_BUSY"
    sessions_.size.repeat: | slot/int |
      session/Session? := sessions_[slot]
      if session and session.is-released: sessions_[slot] = null
      else if session: throw "GATT_SERVICE_BUSY"
    opening_ = true
    try:
      return block.call
    finally:
      opening_ = false

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.CAPABILITIES:
      if arguments != null: throw "INVALID_ARGUMENT"
      return capabilities
    if index == api.ADAPTER-INFO:
      if arguments != null: throw "INVALID_ARGUMENT"
      return adapter-info
    if index == api.SET-TX-POWER:
      if arguments is not int or not -127 <= arguments <= 127: throw "INVALID_ARGUMENT"
      return set-tx-power arguments
    if index == api.OPEN or index == api.OPEN-BUILDER or index == api.OPEN-BOUNDED-BUILDER or index == api.OPEN-SCAN or index == api.CONNECT or index == api.OPEN-ADVERTISING:
      if index == api.OPEN and arguments != null: throw "INVALID_ARGUMENT"
      if index == api.OPEN-BUILDER and arguments is not string: throw "INVALID_ARGUMENT"
      if index == api.OPEN-BOUNDED-BUILDER:
        if arguments is not List or arguments.size != 3: throw "INVALID_ARGUMENT"
      if index == api.OPEN-SCAN and arguments is not List: throw "INVALID_ARGUMENT"
      if index == api.CONNECT and arguments is not List: throw "INVALID_ARGUMENT"
      if index == api.OPEN-ADVERTISING and arguments is not List: throw "INVALID_ARGUMENT"
      if opening_: throw "GATT_SERVICE_BUSY"
      // Admission: scanning and broadcasting own the controller alone. Central
      // and peripheral sessions share it up to their limits, and with each
      // other only with mixed roles. A client holds one session, except that
      // it may add peripheral sessions when several are allowed.
      central-limit := central-session-limit
      peripheral-limit := peripheral-session-limit
      if not 1 <= central-limit <= 8 or not 1 <= peripheral-limit <= 8: throw "INVALID_ARGUMENT"
      mixed := mixed-role-sessions
      peripheral := index == api.OPEN or index == api.OPEN-BUILDER or index == api.OPEN-BOUNDED-BUILDER
      central := index == api.CONNECT
      centrals := 0
      peripherals := 0
      exclusive := 0
      free-slot := -1
      sessions_.size.repeat: | slot/int |
        session/Session? := sessions_[slot]
        if session and session.is-released:
          sessions_[slot] = null
          session = null
        if not session:
          if free-slot < 0: free-slot = slot
          continue.repeat
        if session.owner-client == client and
            not (peripheral and session.is-peripheral and peripheral-limit > 1):
          throw "GATT_SERVICE_BUSY"
        if session.is-central: centrals++
        else if session.is-peripheral: peripherals++
        else: exclusive++
      if free-slot < 0 or exclusive > 0: throw "GATT_SERVICE_BUSY"
      if central:
        if centrals >= central-limit or (peripherals > 0 and not mixed): throw "GATT_SERVICE_BUSY"
      else if peripheral:
        if peripherals >= peripheral-limit or (centrals > 0 and not mixed): throw "GATT_SERVICE_BUSY"
      else if centrals > 0 or peripherals > 0:
        throw "GATT_SERVICE_BUSY"
      opening_ = true
      try:
        session/Session := ?
        if index == api.OPEN-ADVERTISING:
          session = create-advertising client arguments
        else if index == api.CONNECT:
          session = create-connection client arguments
        else if index == api.OPEN-SCAN:
          session = create-scan client arguments
        else if index == api.OPEN:
          session = create-session client
        else if index == api.OPEN-BUILDER:
          session = create-builder client arguments
        else:
          session = create-bounded-builder client arguments[0] arguments[1] arguments[2]
        sessions_[free-slot] = session
        return session
      finally:
        opening_ = false
    if arguments is not List or arguments.is-empty: throw "INVALID_ARGUMENT"
    session := (resource client arguments[0]) as Session
    if index == api.NEXT:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      session.check-serving
      return session.requests.next
    if index == api.WAIT-CLOSED:
      if arguments.size != 1: throw "INVALID_ARGUMENT"
      return session.requests.wait-closed
    if index == api.REPLY:
      if arguments.size != 4: throw "INVALID_ARGUMENT"
      session.requests.reply arguments[1] --error=arguments[2] --value=arguments[3]
      return null
    return session.invoke index arguments[1..]

/** Owns the bounded request mailbox and closes it on client exit or death. */
class Session extends services.ServiceResource:
  requests/bridge.Requests
  owner-client/int

  /** Reports whether this resource can share a central host. */
  is-central -> bool: return false

  /** Reports a configured peripheral reservation, including an unstarted builder. */
  is-peripheral -> bool: return false

  constructor provider/Provider client/int --value-limit/int=20:
    owner-client = client
    requests = bridge.Requests --value-limit=value-limit
    super provider client

  /** Reports whether closure has also released implementation resources. */
  is-released -> bool: return is-closed

  /** Checks whether application requests can be pulled yet. */
  check-serving -> none:

  /** Handles session operations beyond request delivery. */
  invoke index/int arguments/List -> any:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  on-closed -> none:
    requests.close
