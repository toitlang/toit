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

#include "mutex.h"
#include "os.h"

namespace toit {

void Locker::leave() {
  Thread* thread = Thread::current();
  if (thread->locker_ != this) FATAL("unlocking would break lock order");
  thread->locker_ = previous();
  previous_ = null;
  // Perform the actual unlock unless it was a reentrant locking.
  if (!reentrant_) mutex_->unlock();
}

static bool is_reentrant(Locker* locker, Mutex* mutex) {
  // Search the chain of lockers, looking for a previous
  // locking of the mutex at hand.
  while (locker->mutex() != mutex) {
    locker = locker->previous();
    if (!locker) return false;
  }
  return true;
}

void Locker::enter() {
  ASSERT(previous_ == null);
  Thread* thread = Thread::current();
  Mutex* mutex = this->mutex();
  int level = mutex->level();

  bool reentrant = false;
  Locker* previous = thread->locker_;
  if (previous != null) {
    // Skip any reentrant lockers. There will be at least one
    // non-reentrant locker.
    while (previous->reentrant_) previous = previous->previous();
    int previous_level = previous->mutex()->level();
    if (level <= previous_level) {
      reentrant = is_reentrant(previous, mutex);
      if (!reentrant) {
        FATAL("trying to take lock of level %d (%s) while holding lock of level %d (%s)",
            level, mutex->name(), previous_level, previous->mutex()->name());
      }
    }
  }

  if (!reentrant) mutex->lock();
  previous_ = thread->locker_;
  reentrant_ = reentrant;
  thread->locker_ = this;
}

}  // namespace toit
