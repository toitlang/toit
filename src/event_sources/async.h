// Copyright (C) 2024 Toitware ApS.
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

#include "../top.h"

#if defined(TOIT_POSIX) || defined(TOIT_WINDOWS) || defined(TOIT_ESP32)

#include "../linked.h"
#include "../resource.h"

namespace toit {

class AsyncEventSource;
class AsyncEventThread;

typedef LinkedList<AsyncEventThread> AsyncEventThreadList;

class AsyncEventThread : public Thread, public AsyncEventThreadList::Element {
 public:
  // The thread is not started until start() is called.
  AsyncEventThread(const char* name, AsyncEventSource* event_source);

  virtual ~AsyncEventThread() {
    // Stop might take the mutex, so the mutex must not be disposed before the
    // stop() call.
    stop();
    OS::dispose(mutex_);
  }

  /// Runs the given function in the thread.
  /// Expects no other function to be running (or enqueued) at the same time. Returns
  /// false if this condition is not met.
  bool run(Resource* resource, const std::function<word (Resource*)>& func);
  /// Enqueues the given resource and function to be run in the thread.
  /// The functions are run in the order they are enqueued.
  void enqueue(Resource* resource, const std::function<word (Resource*)>& func);

  void start();
  // It is safe to call stop() multiple times.
  void stop();

#ifdef TOIT_NO_THREADS
  // Without threads, the enqueued functions of all started threads are run
  // when the event loop polls. Async event sources are typically singletons
  // that are created on demand, and not managed by the VM's event manager,
  // so they are polled through this static function (see
  // EventSourceManager::poll).
  // Returns the time at which to poll again, or -1 if there is no more work.
  static int64 poll_all(int64 now);
#endif

 private:
  class QueueElement;
  typedef LinkedFifo<QueueElement> Queue;

  class QueueElement : public Queue::Element {
   public:
    std::function<word (Resource*)> func;
    Resource* resource;
  };

  enum State {
    IDLE,
    RUNNING,
    STOPPED,
  };

  AsyncEventSource* event_source_;
  Mutex* mutex_;
  ConditionVariable* queue_cond_;
  Queue queue_;
  State state_ = IDLE;

  void entry() override;
  void enqueue(const Locker& locker, Resource* resource, const std::function<word (Resource*)>& func);

#ifdef TOIT_NO_THREADS
  static AsyncEventThreadList started_threads_;

  // Runs the next enqueued function, if any. Returns whether there are
  // more functions waiting to be run.
  bool run_next();
#endif
};

class AsyncEventSource : public EventSource {
 public:
  AsyncEventSource(const char* name);


 private:
  virtual void on_event(Resource* resource, word data);
  friend class AsyncEventThread;
};

} // namespace toit

#endif // defined(TOIT_POSIX) || defined(TOIT_WINDOWS) || defined(TOIT_ESP32)
