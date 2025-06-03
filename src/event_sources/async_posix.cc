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

#include "../top.h"

#if defined(TOIT_POSIX)

#include "async_posix.h"

namespace toit {

AsyncEventThread::AsyncEventThread(const char* name, AsyncEventSource* event_source)
    : Thread(name)
    , event_source_(event_source)
    , mutex_(OS::allocate_mutex(20, name))
    , queue_cond_(OS::allocate_condition_variable(mutex_)) {}

void AsyncEventThread::start() {
  spawn();
}

void AsyncEventThread::stop() {
  { Locker locker(mutex_);
    if (state_ == STOPPED) return;
    if (state_ == RUNNING) {
      cancel();
    }
    state_ = STOPPED;
    OS::signal(queue_cond_);
  }
  join();
}


void AsyncEventThread::entry() {
  Locker locker(mutex_);
  while (true) {
    while (state_ == IDLE && queue_.is_empty()) {
      OS::wait(queue_cond_);
    }
    if (state_ == STOPPED) return;
    auto element = queue_.remove_first();
    auto resource = element->resource;
    auto func = element->func;
    delete element;
    state_ = RUNNING;
    word result;
    { Unlocker unlocker(locker);
      result = func(resource);
    }
    state_ = IDLE;
    { Unlocker unlocker(locker);
      event_source_->on_event(resource, result);
    }
  }
}

bool AsyncEventThread::run(Resource* resource, const std::function<word (Resource*)>& func) {
  Locker locker(mutex_);
  if (state_ != IDLE || !queue_.is_empty()) return false;
  enqueue(locker, resource, func);
  return true;
}

void AsyncEventThread::enqueue(Resource* resource, const std::function<word (Resource*)>& func) {
  Locker locker(mutex_);
  enqueue(locker, resource, func);
}

void AsyncEventThread::enqueue(const Locker& locker, Resource* resource, const std::function<word (Resource*)>& func) {
  auto element = _new QueueElement();
  if (element == null) FATAL("Failed to allocate memory for queue element");

  element->func = func;
  element->resource = resource;

  queue_.append(element);
  OS::signal(queue_cond_);
}

AsyncEventSource::AsyncEventSource(const char* name)
    : EventSource(name, 1){}

void AsyncEventSource::on_event(Resource* resource, word data) {
  Locker locker(mutex());
  if (resource) dispatch(locker, resource, data);
}

} // namespace toit

#endif // TOIT_POSIX
