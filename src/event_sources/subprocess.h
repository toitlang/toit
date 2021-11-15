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

#pragma once

#include "../resource.h"
#include "../os.h"

namespace toit {

class ProcessWaitResult;

typedef LinkedList<ProcessWaitResult> ProcessWaitResultList;

// Sometimes processes terminate with a status before we have registered a
// resource to wait for it.  In that case we put the result in a
// ProcessWaitResult and queue it up for later.
class ProcessWaitResult : public ProcessWaitResultList::Element {
 public:
  ProcessWaitResult(pid_t pid, int wstatus)
    : _pid(pid)
    , _wstatus(wstatus) {}

  pid_t pid() const { return _pid; }
  pid_t wstatus() const { return _wstatus; }

 private:
  pid_t _pid;
  int _wstatus;
};

// An EventSource that spends most of its time waiting in the waitpid() system
// call for the termination status of subprocesses.  Not used on embedded
// platforms.
class SubprocessEventSource : public EventSource, public Thread {
 public:
  static SubprocessEventSource* instance() { return _instance; }

  SubprocessEventSource();
  ~SubprocessEventSource();

  // Returns true on success, false if an allocation failed.
  virtual bool ignore_result(IntResource* r);

 private:
  void on_register_resource(Locker& locker, Resource* r) override;
  void on_unregister_resource(Locker& locker, Resource* r) override;

  void entry() override;

  static SubprocessEventSource* _instance;
  // Subprocesses that already terminated but we didn't wait for them yet.
  ProcessWaitResultList _results;
  // Subprocesses that we should ignore when they terminate.
  ProcessWaitResultList _ignores;
  ConditionVariable* _subprocess_waits_changed;
  bool _running;
  bool _stop;
};

} // namespace toit
