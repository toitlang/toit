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

TLSEventSource* TLSEventSource::_instance = null;

TLSEventSource* TLSEventSource::instance() {
  return LazyEventSource::get_instance<TLSEventSource>();
}

TLSEventSource::TLSEventSource()
    : LazyEventSource("TLS", 1)
    , Thread("TLS") {
}

TLSEventSource::~TLSEventSource() {
  OS::dispose(_sockets_changed);
  _instance = null;
}

bool TLSEventSource::start() {
  if (mutex() == null) return false;

  _sockets_changed = OS::allocate_condition_variable(mutex());
  if (_sockets_changed == null) return false;

  if (!spawn(5 * KB)) return false;

  return true;
}

void TLSEventSource::stop() {
  {
    // Stop the main thread.
    Locker locker(mutex());
    _stop = true;

    OS::signal(_sockets_changed);
  }

  join();
}

void TLSEventSource::handshake(TLSSocket* socket) {
  Locker locker(mutex());
  _sockets.append(socket);
  OS::signal(_sockets_changed);
}

void TLSEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  TLSSocket* socket = r->as<TLSSocket*>();
  _sockets.remove(socket);
}

void TLSEventSource::entry() {
  Locker locker(mutex());

  while (!_stop) {
    while (true) {
      TLSSocket* socket = _sockets.remove_first();
      if (socket == null) break;

      // Keep locker while handshake is going on, to avoid conflicting remove.
      // If we want to better support multiple concurrent handshakes, this
      // can be further optimized but will be quite complex.
      word result = socket->handshake();
      dispatch(locker, socket, result);
    }

    OS::wait(_sockets_changed);
  }
}

} // namespace toit
