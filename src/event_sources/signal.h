// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#include "../top.h"

#if defined(TOIT_POSIX) || defined(TOIT_WINDOWS)

#ifdef TOIT_POSIX
#include <signal.h>
#elif defined(TOIT_WINDOWS)
#include <windows.h>
#include "../resources/terminal.h"
#endif

#include <string.h>

#include "../os.h"
#include "../resource.h"

namespace toit {

struct SignalInfo {
  // Conventional name without the "SIG" prefix, such as "INT".
  const char* name;
  // Platform signal number.
  int number;
  // Whether the signal can be watched or have its disposition changed.
  // Otherwise it can only be raised.
  bool is_catchable;
};

enum SignalDisposition {
  SIGNAL_DISPOSITION_DEFAULT,
  SIGNAL_DISPOSITION_IGNORE,
};

// Watches a given list of signals.
//
// The Toit side passes the list of signals to watch. A caught signal sets the
// state bit matching its index in watched_signals_. Signal numbers can't be
// used as state bits directly: states are limited to 30 bits and numbers go up
// to 31 (SIGUSR2 on macOS).
class SignalResource : public Resource {
 public:
  TAG(SignalResource);
  // We support up to this many watched signals at once (has to fit in a 30-bit
  // SMI).
  static const int MAX_COUNT = 30;

  SignalResource(ResourceGroup* group, const uint8* watched_signals, int count)
      : Resource(group)
      , watched_signals_count_(count) {
    ASSERT(0 < count && count <= MAX_COUNT);
    memcpy(watched_signals_, watched_signals, count);
  }

  bool is_watched(int number) const {
    for (int i = 0; i < watched_signals_count_; i++) {
      if (watched_signals_[i] == number) return true;
    }
    return false;
  }

  // State bits to report for the given set of signals, where bit `n` of
  // $signals is set if signal `n` arrived.
  uint32 bits_for(uint32 signals) const {
    uint32 result = 0;
    for (int i = 0; i < watched_signals_count_; i++) {
      if ((signals & (1u << watched_signals_[i])) != 0) result |= 1u << i;
    }
    return result;
  }

 private:
  friend class SignalEventSource;

  // Which signals are being watched, in the order that the Toit side requested.
  uint8 watched_signals_[MAX_COUNT];
  const int watched_signals_count_;
  // Whether this resource is registered with the event source, and so
  // included in its counts.
  bool installed_ = false;
};

// Installs a handler for a signal while at least one resource watches it and
// restores the base disposition when the last one goes away. The base
// disposition starts as whatever was installed before the first use and can
// be changed with set_disposition.
//
// On Windows there are no signals. Console control events stand in for INT,
// BREAK and TERM, and a poller watching the console size stands in for WINCH.
//
// Lazy, so the thread (and on POSIX the self-pipe) only exist after signal.init
// has been called.
class SignalEventSource : public LazyEventSource, public Thread {
 public:
  // Highest platform signal number.
  static const int MAX_SIGNAL = 31;

  static SignalEventSource* instance() { return instance_; }

  SignalEventSource();
  ~SignalEventSource() override;

  // Whether the platform has the signal and this event source handles it.
  bool is_supported(int number) const { return find(number) != null; }
  // Whether the signal can be watched or have its disposition changed.
  bool is_catchable(int number) const {
    const SignalInfo* info = find(number);
    return info != null && info->is_catchable;
  }
  // Returns the number for a name such as "INT", 0 if the platform doesn't
  // have the signal.
  int number(const char* name) const;

  // Sets the disposition that applies while nothing watches the signal.
  void set_disposition(int number, SignalDisposition disposition);

  // Delivers the signal to this process. Returns an OS error code, 0 on
  // success.
  int raise(int number);

 protected:
  bool start() override;
  void stop() override;

 private:
  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  void entry() override;
  // Delivers the set of signals, bit `n` set for signal `n`, to every
  // resource watching any of them, with one dispatch per resource.
  void deliver(Locker& locker, uint32 signals);
  void install(Locker& locker, int number);
  void restore(Locker& locker, int number);

  static SignalEventSource* instance_;

  // The signals this platform supports, terminated by an entry with a null
  // name. Defined in the platform-specific file.
  static const SignalInfo signals_[];
  // Returns the entry for the signal, null if it isn't supported.
  static const SignalInfo* find(int number);

  // Number of registered resources watching each signal.
  int counts_[MAX_SIGNAL + 1] = {};
  // Set by stop() to make the thread exit.
  bool stopping_ = false;

#ifdef TOIT_POSIX
  // Reads the current disposition of the signal into base_, once.
  void capture_base(Locker& locker, int number);

  // Disposition to restore when the last watcher goes away.
  struct sigaction base_[MAX_SIGNAL + 1];
  // Whether base_ holds the captured disposition for each signal.
  bool base_captured_[MAX_SIGNAL + 1] = {};
  // Self-pipe: the signal handler writes numbers, the thread reads them.
  int wake_pipe_[2] = { -1, -1 };
#elif defined(TOIT_WINDOWS)
  enum Outcome {
    NOT_HANDLED,  // Nothing watches or ignores the signal, so the default action applies.
    IGNORED,
    DELIVERED,
  };
  Outcome handle(int number);
  static BOOL WINAPI ctrl_handler(DWORD type);

  SignalDisposition base_[MAX_SIGNAL + 1] = {};
  ConditionVariable* changed_;
  // Console size the WINCH poller compares against. Read when the first
  // watcher registers, so a resize right after the watch isn't missed.
  TerminalDimensions dimensions_ = {};
#endif
};

}  // namespace toit

#endif  // defined(TOIT_POSIX) || defined(TOIT_WINDOWS)
