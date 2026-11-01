// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <signal.h>
#include <windows.h>

#include "../resources/terminal.h"
#include "signal.h"

namespace toit {

// The C runtime has no number for WINCH, so this is the Linux one.
static const int SIMULATED_SIGWINCH = 28;
// The C runtime has no SIGKILL. 9 is the POSIX number, which the subprocess
// kill primitive also accepts.
static const int SIMULATED_SIGKILL = 9;

const SignalInfo SignalEventSource::signals_[] = {
  { "INT",   SIGINT,             true },
  { "KILL",  SIMULATED_SIGKILL,  false },
  { "TERM",  SIGTERM,            true },
  { "WINCH", SIMULATED_SIGWINCH, true },
  { "BREAK", SIGBREAK,           true },
  { null,    0,                  false },
};

static int number_for_ctrl_type(DWORD type) {
  switch (type) {
    case CTRL_C_EVENT:
      return SIGINT;
    case CTRL_BREAK_EVENT:
      return SIGBREAK;
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
      return SIGTERM;
    default:
      return 0;
  }
}

// A process has at most one console, so stdout and stderr report the same
// window unless redirected. Stdin is a console input handle, which has no
// screen buffer.
static bool read_console_dimensions(TerminalDimensions* dimensions) {
  return read_terminal_dimensions(1, dimensions) == 0 ||
      read_terminal_dimensions(2, dimensions) == 0;
}

// The control handler stays installed for the lifetime of the VM so that an
// ignore disposition works without any watcher.
SignalEventSource::SignalEventSource()
    : LazyEventSource("Signal", 1)
    , Thread("Signal")
    , changed_(OS::allocate_condition_variable(mutex())) {
  ASSERT(instance_ == null);
  instance_ = this;
  if (!SetConsoleCtrlHandler(ctrl_handler, TRUE)) {
    FATAL("unable to install console control handler");
  }
}

SignalEventSource::~SignalEventSource() {
  SetConsoleCtrlHandler(ctrl_handler, FALSE);
  OS::dispose(changed_);
  instance_ = null;
}

bool SignalEventSource::start() {
  stopping_ = false;
  return spawn();
}

void SignalEventSource::stop() {
  {
    Locker locker(mutex());
    stopping_ = true;
    OS::signal_all(changed_);
  }
  join();
}

// Runs on a thread the system creates for the event. Returns FALSE, which
// lets the default action run, whenever nothing here consumed the event.
BOOL WINAPI SignalEventSource::ctrl_handler(DWORD type) {
  int number = number_for_ctrl_type(type);
  if (number == 0) return FALSE;
  // Needed to take the event source lock. This leaks a small SystemThread
  // per event since the thread is never reused, but control events are
  // manual and rare.
  Thread::ensure_system_thread();
  Outcome outcome = instance_->handle(number);
  if (outcome == NOT_HANDLED) return FALSE;
  if (type != CTRL_C_EVENT && type != CTRL_BREAK_EVENT) {
    // For close, logoff and shutdown Windows terminates the process as soon
    // as ctrl_handler returns, and after its own grace period (around 5s) if it
    // doesn't. Block to give the program that time to react to TERM, or to
    // keep running if TERM is ignored, unless it exits first.
    Sleep(INFINITE);
  }
  return TRUE;
}

SignalEventSource::Outcome SignalEventSource::handle(int number) {
  Locker locker(mutex());
  if (counts_[number] > 0) {
    deliver(locker, 1u << number);
    return DELIVERED;
  }
  return base_[number] == SIGNAL_DISPOSITION_IGNORE ? IGNORED : NOT_HANDLED;
}

void SignalEventSource::set_disposition(int number, SignalDisposition disposition) {
  Locker locker(mutex());
  base_[number] = disposition;
}

int SignalEventSource::raise(int number) {
  // Exit code 9, like the subprocess kill primitive.
  if (number == SIMULATED_SIGKILL) {
    TerminateProcess(GetCurrentProcess(), SIMULATED_SIGKILL);
    return GetLastError();
  }
  if (handle(number) != NOT_HANDLED) return 0;
  // Nothing consumed it, so emulate the default action: a window size change
  // is ignored, a console control event terminates the process.
  if (number == SIMULATED_SIGWINCH) return 0;
  TerminateProcess(GetCurrentProcess(), STATUS_CONTROL_C_EXIT);
  return 0;
}

// Only WINCH needs the poller; the other signals are pushed by the system.
void SignalEventSource::install(Locker& locker, int number) {
  if (number != SIMULATED_SIGWINCH) return;
  read_console_dimensions(&dimensions_);
  OS::signal(changed_);
}

void SignalEventSource::restore(Locker& locker, int number) {}

void SignalEventSource::entry() {
  Locker locker(mutex());
  while (true) {
    // Wait until somebody is interested in WINCH.
    while (!stopping_ && counts_[SIMULATED_SIGWINCH] == 0) {
      OS::wait(changed_);
    }
    if (stopping_) return;

    // Windows reports resize records through the console input buffer.
    // Reading those records here would race with the stdin event source and
    // could consume keyboard input, so the size is polled instead.
    while (!stopping_ && counts_[SIMULATED_SIGWINCH] > 0) {
      OS::wait_us(changed_, 50 * 1000);
      if (stopping_) return;
      TerminalDimensions current;
      if (!read_console_dimensions(&current)) continue;
      if (current == dimensions_) continue;
      dimensions_ = current;
      deliver(locker, 1u << SIMULATED_SIGWINCH);
    }
  }
}

}  // namespace toit

#endif  // TOIT_WINDOWS
