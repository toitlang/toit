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
  OS::signal(sockets_changed_);
}

void TlsEventSource::close(TlsSocket* socket) {
  { Locker locker(mutex());
    for (TlsSocket* it : sockets_) {
      if (it == socket) {
        // Delay the close until the event source is
        // done with the socket.
        socket->delay_close();
        return;
      }
    }
  }
  socket->resource_group()->unregister_resource(socket);
}

void TlsEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
#ifdef DEBUG
  // We never close a socket that is currently in the
  // event source socket list.
  TlsSocket* socket = r->as<TlsSocket*>();
  for (TlsSocket* it : sockets_) {
    ASSERT(it != socket);
  }
#endif
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

      // We maintain a simple invariant: We never close a socket
      // that is currently in the event source socket list. Remove
      // the socket now, so that the call to unregister will be
      // reached in the right state.
      sockets_.remove_first();

      if (socket->needs_delayed_close()) {
        Unlocker unlocker(locker);
        socket->resource_group()->unregister_resource(socket);
      } else {
        dispatch(locker, socket, result);
      }
    }

    OS::wait(sockets_changed_);
  }
}

} // namespace toit
