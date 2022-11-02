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

TLSEventSource* TLSEventSource::instance_ = null;

TLSEventSource::TLSEventSource()
    : LazyEventSource("TLS", 1)
    , Thread("TLS") {
  instance_ = this;
}

TLSEventSource::~TLSEventSource() {
  ASSERT(sockets_changed_ == null);
  instance_ = null;
}

bool TLSEventSource::start() {
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

void TLSEventSource::stop() {
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

void TLSEventSource::handshake(TLSSocket* socket) {
  Locker locker(mutex());
  sockets_.append(socket);
  OS::signal(sockets_changed_);
}

void TLSEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  TLSSocket* socket = r->as<TLSSocket*>();
  sockets_.remove(socket);
}

void TLSEventSource::entry() {
  Locker locker(mutex());
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + EVENT_SOURCE_MALLOC_TAG);

  while (!stop_) {
    while (true) {
      TLSSocket* socket = sockets_.remove_first();
      if (socket == null) break;

      // Keep locker while handshake is going on, to avoid conflicting remove.
      // If we want to better support multiple concurrent handshakes, this
      // can be further optimized but will be quite complex.
      word result = socket->handshake();
      dispatch(locker, socket, result);
    }

    OS::wait(sockets_changed_);
  }
}

} // namespace toit
