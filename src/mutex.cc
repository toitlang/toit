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
  thread->locker_ = previous_;
  // Perform the actual unlock.
  mutex_->unlock();
}

void Locker::enter() {
  Thread* thread = Thread::current();
  int level = mutex_->level();
  Locker* previous_locker = thread->locker_;
  if (previous_locker != null) {
    int previous_level = previous_locker->mutex_->level();
    if (level <= previous_level) {
      FATAL("trying to take lock of level %d (%s) while holding lock of level %d (%s)",
          level, mutex_->name(), previous_level, previous_locker->mutex_->name());
    }
  }
  // Lock after checking the precondition to avoid deadlocking
  // instead of just failing the precondition check.
  mutex_->lock();
  // Only update variables after we have the lock - that grants right
  // to update the locker.
  previous_ = thread->locker_;
  thread->locker_ = this;
}

}  // namespace toit
