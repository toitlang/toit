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

#include "top.h"

#ifdef TOIT_FREERTOS
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#else
#include <errno.h>
#include <pthread.h>
#endif

namespace toit {

class Mutex {
 public:
  Mutex(int level, const char* name) : level_(level), name_(name) {
#ifdef TOIT_FREERTOS
    sem_ = xSemaphoreCreateMutex();
    if (!sem_) FATAL("mutex allocation of semaphore failed")
#else
    pthread_mutex_init(&mutex_, null);
#endif
  }

  ~Mutex() {
#ifdef TOIT_FREERTOS
    vSemaphoreDelete(sem_);
#else
    pthread_mutex_destroy(&mutex_);
#endif
  }

  int level() const { return level_; }
  const char* name() const { return name_; }

  void lock() {
#ifdef TOIT_FREERTOS
    if (xSemaphoreTake(sem_, portMAX_DELAY) != pdTRUE) {
      FATAL("mutex lock failed");
    }
#else
    int error = pthread_mutex_lock(&mutex_);
    if (error != 0) FATAL("mutex lock failed with error %d", error);
#endif
  }

  void unlock() {
#ifdef TOIT_FREERTOS
    if (xSemaphoreGive(sem_) != pdTRUE) {
      FATAL("mutex unlock failed");
    }
#else
    int error = pthread_mutex_unlock(&mutex_);
    if (error != 0) FATAL("mutex unlock failed with error %d", error);
#endif
  }

  bool is_locked() {
#ifdef TOIT_FREERTOS
    return xSemaphoreGetMutexHolder(sem_) != null;
#else
    int error = pthread_mutex_trylock(&mutex_);
    if (error == 0) {
      pthread_mutex_unlock(&mutex_);
      return false;
    }
    if (error != EBUSY) FATAL("mutex trylock failed with error %d", error);
    return true;
#endif
  }

 private:
  const int level_;
  const char* const name_;
#ifdef TOIT_FREERTOS
  SemaphoreHandle_t sem_;
#else
  pthread_mutex_t mutex_;
#endif

  friend class ConditionVariable;
};

// Stack alloated block structured operation for locking and unlocking a mutex.
// Usage:
//  { Locker l(mutex);
//    .. mutex is locked until end of scope ...
//  }
class Locker {
 public:
  explicit Locker(Mutex* mutex) : mutex_(mutex) {
    enter();
  }

  ~Locker() {
    leave();
  }

  Mutex* mutex() const { return mutex_; }
  Locker* previous() const { return previous_; }

 private:
  // Explicitly leave the locker, while in the scope. Must be re-entered by
  // calling `enter`.
  void leave();

  // Enter a locker after leaving it.
  void enter();

  Mutex* const mutex_;
  Locker* previous_ = null;
  bool reentrant_ = false;

  friend class Unlocker;
};

// Block structured operation for temporarily unlocking a mutex inside a Locker.
// Usage:
//  { Unlocker u(locker);
//    .. mutex is unlocked until end of scope ...
//  }
class Unlocker {
 public:
  explicit Unlocker(Locker& locker) : locker_(locker) {
    locker_.leave();
  }

  ~Unlocker() {
    locker_.enter();
  }

 private:
  Locker& locker_;
};

}  // namespace toit
