// Copyright (C) 2019 Toitware ApS.
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

#if defined(TOIT_LINUX) || defined(TOIT_DARWIN)

#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../objects_inline.h"

#include "subprocess.h"

namespace toit {

SubprocessEventSource* SubprocessEventSource::_instance = null;

SubprocessEventSource::SubprocessEventSource()
      : EventSource("ProcessWait")
      , Thread("ProcessWait")
      , _subprocess_waits_changed(OS::allocate_condition_variable(mutex()))
      , _running(false)
      , _stop(false) {
  ASSERT(_instance == null);
  _instance = this;

  Locker locker(mutex());
  spawn();

  // Wait for the thread to be running, to ensure we don't miss signals.
  while (!_running) {
    OS::wait(_subprocess_waits_changed);
  }
}

SubprocessEventSource::~SubprocessEventSource() {
  { Locker locker(mutex());
    _stop = true;

    // Make waitpid exit by starting to ignore child signals.
    struct sigaction act;
    sigemptyset(&act.sa_mask);
    act.sa_handler = SIG_IGN;
    act.sa_flags = SA_NOCLDSTOP;
    sigaction(SIGCHLD, &act, null);

    // In case it is waiting for work in the condition variable.
    OS::signal(_subprocess_waits_changed);
  }

  // Wait for SubprocessEventSource thread to exit.
  join();

  while (ProcessWaitResult* r = _ignores.remove_first()) {
    delete r;
  }
  while (ProcessWaitResult* r = _results.remove_first()) {
    delete r;
  }
  ASSERT(resources().is_empty());

  OS::dispose(_subprocess_waits_changed);
  _instance = null;
}

static const int PROCESS_EXITED = 1;
static const int PROCESS_SIGNALLED = 2;
static const int PROCESS_EXIT_CODE_SHIFT = 2;
static const int PROCESS_EXIT_CODE_MASK = 0xff;
static const int PROCESS_SIGNAL_SHIFT = 10;
static const int PROCESS_SIGNAL_MASK = 0xff;

static int status_from(int wstatus) {
  int status = 0;
  if (WIFEXITED(wstatus)) {
    status |= PROCESS_EXITED;
    status |= (WEXITSTATUS(wstatus) & PROCESS_EXIT_CODE_MASK) << PROCESS_EXIT_CODE_SHIFT;
  }
  if (WIFSIGNALED(wstatus)) {
    status |= PROCESS_SIGNALLED;
    status |= (WTERMSIG(wstatus) & PROCESS_SIGNAL_MASK) << PROCESS_SIGNAL_SHIFT;
  }
  return status;
}

void SubprocessEventSource::on_register_resource(Locker& locker, Resource* r) {
  OS::signal(_subprocess_waits_changed);
  auto resource = static_cast<IntResource*>(r);
  pid_t pid = resource->id();
  ProcessWaitResult* already_exited = _results.remove_where([&](ProcessWaitResult* result) {
    return result->pid() == pid;
  });
  // TODO: Remove any results from the same process that were not waited for.
  if (already_exited) {
    // The process already terminated before its resource was registered.
    // We are calling dispatch from the Toit process thread, which is a little
    // unusual, but should work fine.
    dispatch(locker, r, status_from(already_exited->wstatus()));
  }
}

bool SubprocessEventSource::ignore_result(IntResource* resource) {
  // TODO(anders): Event sources should not be communicated with outside of register/unregister.
  Locker locker(mutex());
  OS::signal(_subprocess_waits_changed);
  pid_t pid = resource->id();
  // We do this twice to be sure that the second time is harmless.  This
  // happens rarely when the primitive is restarted due to allocation failure,
  // and we want to make sure it's not going to cause rare problems.
  unregister_resource(locker, resource);
#ifdef DEBUG
  unregister_resource(locker, resource);
#endif
  ProcessWaitResult* already_exited = _results.remove_where([&](ProcessWaitResult* result) {
    return result->pid() == pid;
  });
  if (!already_exited) {
    ProcessWaitResult* waiter = _new ProcessWaitResult(pid, 0);
    if (waiter == null) return false;
    _ignores.prepend(waiter);
  }
  return true;
}

void SubprocessEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  OS::signal(_subprocess_waits_changed);
  auto resource = static_cast<IntResource*>(r);
  pid_t pid = resource->id();
  ProcessWaitResult* already_exited = _results.remove_where([&](ProcessWaitResult* result) {
    return result->pid() == pid;
  });
  // TODO: Remove any results from the same process that were not waited for.
  if (already_exited) {
    // The process already terminated before its resource was registered.
    // We are calling dispatch from the Toit process thread, which is a little
    // unusual, but should work fine.
    dispatch(locker, r, status_from(already_exited->wstatus()));
  }
}

// The loop running on the dedicated thread.
void SubprocessEventSource::entry() {
  Locker locker(mutex());
  // If we issue a signal before this lock is taken, we can lose a signal
  // and be stuck in OS::wait.
  _running = true;
  OS::signal(_subprocess_waits_changed);

  while (!_stop) {
    // Wait for subprocesses to start.
    OS::wait(_subprocess_waits_changed);  // Releases and reacquires the mutex.

    // Loop over waitpid until waitpid returns -1, indicating no more
    // child processes are running.
    while (true) {
      int wstatus;
      pid_t pid;
      int waitpid_errno;
      // Block here waiting for subprocesses to exit.
      { Unlocker unlock(locker);
        pid = waitpid(-1, &wstatus, 0);
        waitpid_errno = errno;  // Save it while we do other syscalls.
      }
      if (pid == -1) {
        if (waitpid_errno == ECHILD) {
          // There was no subprocess to wait for, but perhaps a subprocess terminated
          // after the waitpid, but before we grabbed the lock.  Do a non-blocking
          // waitpid under the lock to see if we need to sleep and wait for a pid
          // to wait for.
          pid = waitpid(-1, &wstatus, WNOHANG);
          waitpid_errno = errno;
        }
      }
      if (pid == -1) {
        ASSERT(waitpid_errno == ECHILD);  // There were no subprocesses to wait for.
        break;
      }
      Resource* r = find_resource_by_id(locker, pid);
      // If someone wanted to ignore the exit code from this pid then remove that
      // entry from the list now it exited.
      auto ignore = _ignores.remove_where([&](ProcessWaitResult* ignore) {
        return ignore->pid() == pid;
      });
      if (r != null) {
        // Someone was waiting on this pid, so wake them.
        dispatch(locker, r, status_from(wstatus));
      } else if (!ignore) {
        // Nobody was waiting on this result, so store it up for later.
        // We don't check for an allocation failure here, but this code is never
        // run on the device, and on large machines we can assume that
        // allocations do not fail in normal running.  Currently EventSource
        // threads have no way to trigger a GC, so there's not much we can do if
        // allocation fails here.
  #ifdef TOIT_FREERTOS
        UNREACHABLE();
  #endif
        _results.prepend(_new ProcessWaitResult(pid, wstatus));
      }
    }
  }
}


} // namespace toit

#endif // TOIT_LINUX
