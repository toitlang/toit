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
static const int ERR_MEM_NON_RECOVERABLE = -127;
static const int LAST_TOIT_ERROR = -128;

// Only accessed from the LWIP thread.
extern bool needs_gc;

// Returns the error as a string. Returns null on allocation failure.
Object* lwip_error(Process* process, err_t err);

// The LwipEventSource handles the LwIP thread, which is system-wide.  All LwIP
// code must run on this thread, and it blocks when nothing is happening in
// LwIP.
class LwipEventSource : public EventSource {
 public:
  static LwipEventSource* instance() { return instance_; }

  LwipEventSource();
  ~LwipEventSource();

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
    Locker locker(mutex_);
    while (!call.done) OS::wait(call_done_);
    return call.result;
  }

  // This event source (and LwIP thread) is shared across all Toit processes,
  // so there is a mutex to control access.
  Mutex* mutex() { return mutex_; }

 private:
  struct CallContext {
    Object* result;
    const std::function<Object*()>& func;
    bool done;
  };

  static void on_thread(void* arg);

  static LwipEventSource* instance_;

  Mutex* mutex_;
  ConditionVariable* call_done_;
};

} // namespace toit

#endif  // TOIT_USE_LWIP
