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

#include "timer.h"

#include "../objects_inline.h"
#include "../utils.h"

namespace toit {

TimerEventSource* TimerEventSource::_instance = null;

TimerEventSource::TimerEventSource()
    : EventSource("Timer")
    , Thread("Timer")
    , _timer_changed(OS::allocate_condition_variable(mutex()))
    , _stop(false) {
  ASSERT(_instance == null);
  _instance = this;
  spawn();
}

TimerEventSource::~TimerEventSource() {
  {
    // Stop the main thread.
    Locker locker(mutex());
    _stop = true;

    OS::signal(_timer_changed);
  }

  join();

  ASSERT(_timers.is_empty());

  OS::dispose(_timer_changed);

  _instance = null;
}

void TimerEventSource::arm(Timer* timer, int64_t timeout) {
  Locker locker(mutex());

  // Get current timeout, if any.
  auto head = _timers.first();
  int64_t old_timeout = head ? head->timeout() : timeout + 1;

  // Remove in case it was already enqueued.
  if (_timers.is_linked(timer)) {
    _timers.unlink(timer);
  }

  // Clear and install timer.
  timer->set_state(0);
  timer->set_timeout(timeout);

  _timers.insert_before(timer, [&timer](Timer* t) { return timer->timeout() < t->timeout(); });

  if (timeout < old_timeout) {
    // Signal if new timeout is less the the old.
    // This means we don't re-arm even if the first timer
    // was removed. This simply means we avoid waking up NOW, but instead
    // delays the wakeup to the already scheduled time. The result
    // is overall at maximum the same number of wakeups, but most likely
    // much less.
    OS::signal(_timer_changed);
  }
}

void TimerEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  ASSERT(is_locked());
  Timer* timer = r->as<Timer*>();

  Timer* first = _timers.first();
  if (_timers.is_linked(timer)) {
    _timers.unlink(timer);
    if (first == timer) {
      // Signal if the first one changes.
      OS::signal(_timer_changed);
    }
  }
}

void TimerEventSource::entry() {
  Locker locker(mutex());

  while (!_stop) {
    int64 time = OS::get_monotonic_time();

    int64 delay_us = 0;
    while (!_timers.is_empty()) {
      if (time >= _timers.first()->timeout()) {
        Timer* timer = _timers.remove_first();
        dispatch(locker, timer, 0);
      } else {
        delay_us = _timers.first()->timeout() - time;
        break;
      }
    }

    int delay_ms = (delay_us + 1000 - 1) / 1000;  // Ceiling division.
    OS::wait(_timer_changed, delay_ms);
  }
}

} // namespace toit
