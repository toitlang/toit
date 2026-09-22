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
  sessions_/List ::= List 2
  opening_/bool := false

  constructor:
    super "toit.io/experimental/ble" --major=0 --minor=17
    provides api.SELECTOR --handler=this

  /** Bounds simultaneous central clients; other radio modes stay exclusive. */
  central-session-limit -> int: return 1

  /** Allows one peripheral and one central client only for an explicit shared provider. */
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

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.CAPABILITIES:
      if arguments != null: throw "INVALID_ARGUMENT"
      return capabilities
    if index == api.OPEN or index == api.OPEN-BUILDER or index == api.OPEN-BOUNDED-BUILDER or index == api.OPEN-SCAN or index == api.CONNECT or index == api.OPEN-ADVERTISING:
      if index == api.OPEN and arguments != null: throw "INVALID_ARGUMENT"
      if index == api.OPEN-BUILDER and arguments is not string: throw "INVALID_ARGUMENT"
      if index == api.OPEN-BOUNDED-BUILDER:
        if arguments is not List or arguments.size != 3: throw "INVALID_ARGUMENT"
      if index == api.OPEN-SCAN and arguments is not List: throw "INVALID_ARGUMENT"
      if index == api.CONNECT and arguments is not List: throw "INVALID_ARGUMENT"
      if index == api.OPEN-ADVERTISING and arguments is not List: throw "INVALID_ARGUMENT"
      if opening_: throw "GATT_SERVICE_BUSY"
      limit := central-session-limit
      if not 1 <= limit <= 2: throw "INVALID_ARGUMENT"
      mixed := mixed-role-sessions
      if mixed and limit != 2: throw "INVALID_ARGUMENT"
      peripheral := index == api.OPEN or index == api.OPEN-BUILDER or index == api.OPEN-BOUNDED-BUILDER
      occupied := 0
      free-slot := -1
      sessions_.size.repeat: | slot/int |
        session/Session? := sessions_[slot]
        if session and session.is-released:
          sessions_[slot] = null
          session = null
        if not session:
          if free-slot < 0: free-slot = slot
          continue.repeat
        occupied++
        if session.owner-client == client: throw "GATT_SERVICE_BUSY"
        if index == api.CONNECT and session.is-central: continue.repeat
        if mixed and ((index == api.CONNECT and session.is-peripheral) or
            (peripheral and session.is-central)):
          continue.repeat
        throw "GATT_SERVICE_BUSY"
      if occupied >= limit or free-slot < 0: throw "GATT_SERVICE_BUSY"
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
