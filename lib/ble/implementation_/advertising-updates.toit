// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor

/**
Advertising payload updates while a peripheral accept is in progress.

An application that advertises changing data (a counter, a sensor value)
  hands the link owner a $Changes object with its accept call and then calls
  $Changes.update from its own task. The accept worker takes each $Request
  through $Changes.next, applies it to the controller between advertising
  windows and settles it with $Changes.complete; $Changes.stop ends admission
  when advertising ends. One update is pending at a time and each is
  answered exactly once, also when the accept is cancelled or fails.
*/

/** Owns a single-use queue of payload changes for one peripheral accept operation. */
class Changes:
  state_/State_ ::= State_

  /** Copies a bounded update and waits for its accept worker; returns false after advertising ends. */
  update data/ByteArray response/ByteArray -> bool:
    if data.size > 31 or response.size > 31: throw "INVALID_ARGUMENT"
    request := Request data.copy response.copy
    published := false
    completed := false
    try:
      critical-do --no-respect-deadline: published = state_.post request
      if not published:
        completed = true
        return false
      result/bool := request.done.get
      completed = true
      return result
    finally:
      if published and not completed:
        critical-do --no-respect-deadline: stop --error="HCI_ADVERTISING_UPDATE_ABORTED"

  /** Marks successful controller enablement without reopening an ended queue. */
  ready -> none: state_.ready

  /** Wakes the worker to inspect a controller advertising-window event. */
  wake -> none: state_.wake

  /** Returns the outstanding request, or null on termination or a window event. */
  next -> Request?:
    return state_.next

  /** Reports whether connection creation or cleanup has ended advertising. */
  ended -> bool: return state_.ended

  /** Completes an update only if advertising still belongs to this operation. */
  complete request/Request -> none: state_.complete request

  /** Ends admission and releases a waiting update, including before enablement. */
  stop --error/string?=null -> none: state_.stop --error=error

monitor State_:
  ready_/bool := false
  ended/bool := false
  error_/string? := null
  wake_/bool := false
  request_/Request? := null

  post request/Request -> bool:
    if error_: throw error_
    if ended: return false
    if request_: throw "BLE_ADVERTISING_UPDATE_BUSY"
    request_ = request
    return true

  ready -> none: ready_ = true
  wake -> none: wake_ = true

  next -> Request?:
    await: ended or wake_ or (ready_ and request_ != null)
    if error_: throw error_
    wake_ = false
    return ended ? null : request_

  complete request/Request -> none:
    if ended: return
    if request_ != request: throw "HCI_ADVERTISING_UPDATE_MISMATCH"
    request_ = null
    request.done.set true

  stop --error/string?=null -> none:
    if ended: return
    ended = true
    error_ = error
    request := request_
    request_ = null
    if request:
      if error: request.done.set error --exception
      else: request.done.set false

/** Holds owned payloads until the accept worker settles their controller commands. */
class Request:
  data/ByteArray
  response/ByteArray
  done/monitor.Latch ::= monitor.Latch

  constructor .data .response:
