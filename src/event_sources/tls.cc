// Copyright (C) 2021 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "tls.h"

#include "../objects_inline.h"
#include "../utils.h"

namespace toit {

TlsEventSource* TlsEventSource::instance_ = null;

TlsEventSource::TlsEventSource()
    : LazyEventSource("TLS", 1)
    , Thread("TLS") {
  instance_ = this;
}

TlsEventSource::~TlsEventSource() {
  ASSERT(sockets_changed_ == null);
  instance_ = null;
}

bool TlsEventSource::start() {
  Locker locker(mutex());
  ASSERT(sockets_changed_ == null);
  sockets_changed_ = OS::allocate_condition_variable(mutex());
  if (sockets_changed_ == null) return false;
  if (!spawn(5 * KB)) {
    OS::dispose(sockets_changed_);
    sockets_changed_ = null;
    return false;
  }
  stop_ = false;
  return true;
}

void TlsEventSource::stop() {
  {
    // Stop the main thread.
    Locker locker(mutex());
    stop_ = true;

    OS::signal(sockets_changed_);
  }

  join();
  OS::dispose(sockets_changed_);
  sockets_changed_ = null;
}

void TlsEventSource::handshake(TlsSocket* socket) {
  Locker locker(mutex());
  sockets_.append(socket);
  // The condition is shared with threads waiting in on_unregister_resource.
  OS::signal_all(sockets_changed_);
}

void TlsEventSource::close(TlsSocket* socket) {
  socket->resource_group()->unregister_resource(socket);
}

void TlsEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  // A socket that is queued for, or in the middle of, a handshake step is
  // still used by the worker thread. Unregistration is followed by deletion
  // of the socket, and when a process dies, of its whole resource group and
  // the TLS group state the handshake uses. Deferring the close and letting
  // the worker unregister the socket on its own thread later raced with
  // exactly that teardown. Instead, mark the socket so that the worker does
  // not start another step or dispatch a result, and wait here until the
  // worker has dropped it. That blocks the closing process for at most one
  // handshake step, which is pure computation on already buffered input.
  // Non-socket resources (handshake tokens) also reach this hook; they are
  // never in the list.
  while (true) {
    bool pending = false;
    for (auto socket : sockets_) {
      if (socket != r) continue;
      socket->delay_close();
      pending = true;
      break;
    }
    if (!pending) return;
    OS::wait(sockets_changed_);  // Releases the event-source mutex while waiting.
  }
}

void TlsEventSource::entry() {
  Locker locker(mutex());
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);

  while (!stop_) {
    while (true) {
      TlsSocket* socket = sockets_.first();
      if (socket == null) break;

      word result = 0;
      if (!socket->needs_delayed_close()) {
        Unlocker unlocker(locker);
        result = socket->handshake();
      }

      // The owning process unregisters and deletes the socket, never this
      // thread. Once the socket has been removed from the list and the
      // condition signaled, it must not be touched again.
      sockets_.remove_first();

      if (!socket->needs_delayed_close()) {
        dispatch(locker, socket, result);
      }
      OS::signal_all(sockets_changed_);
    }

    OS::wait(sockets_changed_);
  }
}

} // namespace toit
