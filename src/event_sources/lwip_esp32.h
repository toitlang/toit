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

#include <functional>

#if defined(TOIT_USE_LWIP) || defined(TOIT_FREERTOS)

#include <lwip/tcpip.h>

#include "../resource.h"
#include "../os.h"
#include "../process.h"

namespace toit {

static const int FIRST_TOIT_ERROR = -126;
static const int ERR_NAME_LOOKUP_FAILURE = -126;
static const int LAST_TOIT_ERROR = -128;

// Returns the error as a string. Returns null on allocation failure.
Object* lwip_error(Process* process, err_t err);

// The LwIPEventSource handles the LwIP thread, which is system-wide.  All LwIP
// code must run on this thread, and it blocks when nothing is happening in
// LwIP.
class LwIPEventSource : public EventSource {
 public:
  static LwIPEventSource* instance() { return _instance; }

  LwIPEventSource();
  ~LwIPEventSource();

  // Calls a closure on the LwIP thread, while temporarily blocking the thread
  // that calls call_on_thread. The LwIP thread code runs for a short time and
  // should never block.  Because we are blocking the calling thread it is OK
  // to do Toit heap operations in the closure code.
  Object* call_on_thread(const std::function<Object* ()>& func) {
    CallContext call = {
      null,
      func,
      false,
    };

    // Send a message to the LwIP thread that instructs it to run our code.
    // The '0' indicates that we should not block, but immediately below we
    // will manually block the thread using OS::wait.
    int err = tcpip_callback(&on_thread, void_cast(&call));
    if (err != ERR_OK) {
      FATAL("failed calling function on LwIP thread: %d\n", err);
    }

    // Wait for the LwIP thread to perform our task.
    Locker locker(_mutex);
    while (!call.done) OS::wait(_call_done);
    return call.result;
  }

  // This event source (and LwIP thread) is shared across all Toit processes,
  // so there is a mutex to control access.
  Mutex* mutex() { return _mutex; }

 private:
  struct CallContext {
    Object* result;
    const std::function<Object*()>& func;
    bool done;
  };

  static void on_thread(void* arg);

  static LwIPEventSource* _instance;

  Mutex* _mutex;
  ConditionVariable* _call_done;
};

} // namespace toit

#endif  // TOIT_USE_LWIP
