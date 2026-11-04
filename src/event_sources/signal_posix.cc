// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_POSIX

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include "signal.h"

namespace toit {

static volatile sig_atomic_t signal_write_fd = -1;

// Only async-signal-safe calls here. The event source thread does the rest.
static void signal_handler(int signal) {
  int saved_errno = errno;
  int fd = signal_write_fd;
  if (fd >= 0) {
    uint8 marker = signal;
    ssize_t result = write(fd, &marker, sizeof(marker));
    USE(result);
  }
  errno = saved_errno;
}

static bool set_descriptor_flag(int fd, int get_command, int set_command, int flag) {
  int flags = fcntl(fd, get_command);
  return flags >= 0 && fcntl(fd, set_command, flags | flag) == 0;
}

// The numbers are platform-specific. E.g., on Linux, SIGUSR1 is 10, on macOS
// it's 30.
const SignalInfo SignalEventSource::signals_[] = {
  { "HUP",   SIGHUP,   true },
  { "INT",   SIGINT,   true },
  { "QUIT",  SIGQUIT,  true },
  { "KILL",  SIGKILL,  false },
  { "USR1",  SIGUSR1,  true },
  { "USR2",  SIGUSR2,  true },
  { "PIPE",  SIGPIPE,  true },
  { "ALRM",  SIGALRM,  true },
  { "TERM",  SIGTERM,  true },
  { "CHLD",  SIGCHLD,  true },
  { "CONT",  SIGCONT,  true },
  { "STOP",  SIGSTOP,  false },
  { "TSTP",  SIGTSTP,  true },
  { "TTIN",  SIGTTIN,  true },
  { "TTOU",  SIGTTOU,  true },
  { "WINCH", SIGWINCH, true },
#ifdef TOIT_BSD
  // Some Linux architectures define SIGINFO as an alias of SIGPWR, so check
  // the platform rather than the macro.
  { "INFO",  SIGINFO,  true },
#endif
  { null,    0,        false },
};

SignalEventSource::SignalEventSource()
    : LazyEventSource("Signal", 1)
    , Thread("Signal") {
  ASSERT(instance_ == null);
  instance_ = this;
}

SignalEventSource::~SignalEventSource() {
  instance_ = null;
}

bool SignalEventSource::start() {
  stopping_ = false;
  if (pipe(wake_pipe_) != 0) return false;
  if (!set_descriptor_flag(wake_pipe_[0], F_GETFD, F_SETFD, FD_CLOEXEC) ||
      !set_descriptor_flag(wake_pipe_[1], F_GETFD, F_SETFD, FD_CLOEXEC) ||
      !set_descriptor_flag(wake_pipe_[1], F_GETFL, F_SETFL, O_NONBLOCK)) {
    goto abort;
  }
  signal_write_fd = wake_pipe_[1];
  if (spawn()) return true;

abort:
  signal_write_fd = -1;
  close(wake_pipe_[0]);
  close(wake_pipe_[1]);
  wake_pipe_[0] = wake_pipe_[1] = -1;
  return false;
}

void SignalEventSource::stop() {
  signal_write_fd = -1;
  {
    Locker locker(mutex());
    stopping_ = true;
  }
  // 0 is not a signal, so it only wakes the thread.
  uint8 marker = 0;
  ssize_t result;
  do {
    result = write(wake_pipe_[1], &marker, sizeof(marker));
  } while (result < 0 && errno == EINTR);
  join();
  close(wake_pipe_[0]);
  close(wake_pipe_[1]);
  wake_pipe_[0] = wake_pipe_[1] = -1;
}

void SignalEventSource::capture_base(Locker& locker, int number) {
  if (base_captured_[number]) return;
  if (sigaction(number, null, &base_[number]) != 0) {
    FATAL("unable to read signal disposition");
  }
  base_captured_[number] = true;
}

void SignalEventSource::install(Locker& locker, int number) {
  capture_base(locker, number);
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  sigemptyset(&action.sa_mask);
  action.sa_handler = signal_handler;
  // SA_RESTART keeps blocking calls such as the subprocess waitpid loop from
  // failing with EINTR.
  action.sa_flags = SA_RESTART;
  // SA_NOCLDSTOP: only report children that terminated, not ones that were
  // stopped or continued (SIGSTOP, SIGCONT, job control).
  if (number == SIGCHLD) action.sa_flags |= SA_NOCLDSTOP;
  if (sigaction(number, &action, null) != 0) {
    FATAL("unable to install signal handler");
  }
}

void SignalEventSource::restore(Locker& locker, int number) {
  ASSERT(base_captured_[number]);
  if (sigaction(number, &base_[number], null) != 0) {
    FATAL("unable to restore signal disposition");
  }
}

void SignalEventSource::set_disposition(int number, SignalDisposition disposition) {
  Locker locker(mutex());
  capture_base(locker, number);
  // An explicit SIG_IGN on SIGCHLD makes the kernel reap children itself, so
  // the subprocess event source's waitpid fails with ECHILD and pipe waits
  // hang. SIG_DFL discards the signal too, but keeps the exit statuses.
  bool ignore = disposition == SIGNAL_DISPOSITION_IGNORE && number != SIGCHLD;
  base_[number].sa_handler = ignore ? SIG_IGN : SIG_DFL;
  base_[number].sa_flags &= ~SA_SIGINFO;
  if (counts_[number] == 0) restore(locker, number);
}

int SignalEventSource::raise(int number) {
  return ::raise(number) == 0 ? 0 : errno;
}

void SignalEventSource::entry() {
  while (true) {
    uint8 markers[64];
    ssize_t result;
    do {
      result = read(wake_pipe_[0], markers, sizeof(markers));
    } while (result < 0 && errno == EINTR);
    // Without this thread installed handlers keep swallowing signals that
    // nobody delivers, so the process could no longer be interrupted.
    if (result <= 0) FATAL("unable to read from signal pipe");

    // Coalesce the batch, so a burst of the same signal is one delivery.
    uint32 signals = 0;
    for (ssize_t i = 0; i < result; i++) {
      int number = markers[i];
      if (is_supported(number)) signals |= 1u << number;
    }

    Locker locker(mutex());
    if (stopping_) return;
    if (signals != 0) deliver(locker, signals);
  }
}

}  // namespace toit

#endif  // TOIT_POSIX
