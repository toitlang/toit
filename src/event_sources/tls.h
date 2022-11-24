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

#pragma once

#include "../resource.h"
#include "../os.h"
#include "../top.h"

namespace toit {

class TlsSocket;

typedef LinkedFifo<TlsSocket, 1> TlsSocketList;

class TlsSocket : public Resource, public TlsSocketList::Element {
 public:
  TlsSocket(ResourceGroup* resource_group)
    : Resource(resource_group) {}

  virtual word handshake() = 0;
};

class TlsEventSource : public LazyEventSource, public Thread {
 public:
  static TlsEventSource* instance() { return instance_; }

  TlsEventSource();

  virtual void on_unregister_resource(Locker& locker, Resource* r) override;

  void handshake(TlsSocket* socket);

 protected:
  friend class LazyEventSource;
  static TlsEventSource* instance_;

  ~TlsEventSource();

  virtual bool start() override;
  virtual void stop() override;

 private:
  void entry() override;

  ConditionVariable* sockets_changed_ = null;
  TlsSocketList sockets_;
  bool stop_ = false;
};

} // namespace toit
