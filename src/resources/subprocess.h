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

#include "../top.h"

#if defined(TOIT_WINDOWS)
#include "../event_sources/event_win.h"
#endif

namespace toit {

class SubprocessResourceGroup : public ResourceGroup {
 public:
  TAG(SubprocessResourceGroup);
  SubprocessResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}
  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

 private:
};

#if defined(TOIT_WINDOWS)
class SubprocessResource : public WindowsResource {
 public:
  TAG(SubprocessResource);
  SubprocessResource(ResourceGroup* resource_group, HANDLE handle)
    : WindowsResource(resource_group)
    , handle_(handle) {}

  std::vector<HANDLE> events() override;

  void do_close() override;

  uint32_t on_event(HANDLE event, uint32_t state) override;

  void set_killed() { killed_ = true; }
  bool killed() const { return killed_; }
  HANDLE handle() const { return handle_; }
  bool is_event_enabled(HANDLE event) override { return stopped_state_ == 0; }

 private:
  HANDLE handle_;
  bool killed_ = false;
  word stopped_state_ = 0;
};
#endif // defined(TOIT_WINDOWS)
} // namespace toit
