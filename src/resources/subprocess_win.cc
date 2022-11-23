// Copyright (C) 2022 Toitware ApS.
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

#if defined(TOIT_WINDOWS)

#include <windows.h>
#include "../event_sources/event_win.h"
#include "../objects_inline.h"
#include "../process_group.h"
#include "../vm.h"
#include "subprocess.h"
namespace toit {

static const int PROCESS_EXITED = 1;
static const int PROCESS_SIGNALLED = 2;
static const int PROCESS_EXIT_CODE_SHIFT = 2;
static const int PROCESS_EXIT_CODE_MASK = 0xff;
static const int PROCESS_SIGNAL_SHIFT = 10;

uint32_t SubprocessResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  return reinterpret_cast<WindowsResource*>(resource)->on_event(
      reinterpret_cast<HANDLE>(data),
      state);
}

void SubprocessResource::do_close() {
  CloseHandle(handle_);
}

uint32_t SubprocessResource::on_event(HANDLE event, uint32_t state) {
  if (stopped_state_ != 0) return stopped_state_; // This is a one off event.

  DWORD exit_code;
  GetExitCodeProcess(handle_, &exit_code);

  if (killed()) state |= PROCESS_SIGNALLED | (9 << PROCESS_SIGNAL_SHIFT);
  else state |= PROCESS_EXITED | ((exit_code & PROCESS_EXIT_CODE_MASK) << PROCESS_EXIT_CODE_SHIFT);

  stopped_state_ = state;
  return state;
}

std::vector<HANDLE> SubprocessResource::events() {
  return std::vector<HANDLE>( { handle_ } );
}

MODULE_IMPLEMENTATION(subprocess, MODULE_SUBPROCESS)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto  resource_group = _new SubprocessResourceGroup(process, WindowsEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(wait_for) {
  // On Windows we always add an event to get notified when a subprocess ends. So this primitive is intentionally just
  // returning null.
  return process->program()->null_object();
}

PRIMITIVE(dont_wait_for) {
  // On Windows we always add an event to get notified when a subprocess ends. So this primitive is intentionally just
  // returning null.
  return process->program()->null_object();
}

PRIMITIVE(kill) {
  ARGS(SubprocessResource, subprocess, int, signal);
  if (signal != 9) INVALID_ARGUMENT;

  subprocess->set_killed();
  TerminateProcess(subprocess->handle(), signal);
  return process->program()->null_object();
}

PRIMITIVE(strsignal) {
  ARGS(int, signal);
  if (signal == 9) return process->allocate_string_or_error("SIGKILL");
  INVALID_ARGUMENT;
}

} // namespace toit

#endif // TOIT_WINDOWS
