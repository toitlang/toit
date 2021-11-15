// Copyright (C) 2018 Toitware ApS.
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

#include "../linked.h"
#include "../os.h"
#include "../resource.h"

namespace toit {

class DNSLookupRequest : public Resource {
  public:
   TAG(DNSLookupRequest);
   DNSLookupRequest(ResourceGroup* group, uint8_t* address)
     : Resource(group)
     , _address(address)
     , _done(false) {}

   ~DNSLookupRequest() {
     free(_address);
   }

  void mark_done() { _done = true; }
  bool is_done() { return _done; }

  uint8_t* address() { return _address; }
  void set_address(uint8_t* address) { _address = address; }

  int length() { return _length; }
  void set_length(int length) { _length = length; }

  int error() { return _error; }
  void set_error(int error) { _error = error; }

 private:
  uint8_t* _address;
  int _length = 0;
  int _error = 0;
  bool _done = false;
};

class DNSEventSource : public EventSource, public Thread {
 public:
  static DNSEventSource* instance() { return _instance; }

  DNSEventSource();
  ~DNSEventSource();

  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

 private:
  void entry() override;

  static DNSEventSource* _instance;

  bool _stop;
  ConditionVariable* _lookup_requests_changed;
};

} // namespace toit
