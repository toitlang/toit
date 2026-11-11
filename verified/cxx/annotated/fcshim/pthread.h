// Copyright (C) 2026 Toit contributors.
//
// Stand-in for <pthread.h> when frama-clang parses the VM's headers: Frama-C's
// own libc pthread.h carries ACSL contracts that frama-clang 0.0.20 cannot
// parse in C++ ("reference to 'pthread_once' is ambiguous", then an
// assertion failure in framaCIRGen). Only what src/mutex.h uses.
#pragma once
#define __FC_PTHREAD_H
#include <__fc_define_pthread_types.h>
extern "C" {
int pthread_mutex_init(pthread_mutex_t* mutex, const pthread_mutexattr_t* attr);
int pthread_mutex_destroy(pthread_mutex_t* mutex);
int pthread_mutex_lock(pthread_mutex_t* mutex);
int pthread_mutex_unlock(pthread_mutex_t* mutex);
int pthread_mutex_trylock(pthread_mutex_t* mutex);
}
