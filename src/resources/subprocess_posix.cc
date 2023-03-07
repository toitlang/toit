// Copyright (C) 2018 Toitware ApS.
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

#if defined(TOIT_LINUX) || defined(TOIT_BSD)

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include "../event_sources/subprocess.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process_group.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"
#include "subprocess.h"

namespace toit {

uint32_t SubprocessResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
    // Commands are single-shots.
    ASSERT(state == 0);
    // Exit status data is never 0, since it always contains either a flag for
    // a normal exit or for a signal exit.
    ASSERT(data != 0);
    return data;
}

MODULE_IMPLEMENTATION(subprocess, MODULE_SUBPROCESS)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  SubprocessResourceGroup* resource_group = _new SubprocessResourceGroup(process, SubprocessEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(wait_for) {
  ARGS(IntResource, subprocess);
  if (subprocess->resource_group()->event_source() != SubprocessEventSource::instance()) WRONG_TYPE;
  subprocess->resource_group()->register_resource(subprocess);
  return process->program()->null_object();
}

PRIMITIVE(dont_wait_for) {
  ARGS(IntResource, subprocess);
  if (subprocess->resource_group()->event_source() != SubprocessEventSource::instance()) WRONG_TYPE;
  bool success = SubprocessEventSource::instance()->ignore_result(subprocess);
  if (!success) MALLOC_FAILED;
  subprocess->resource_group()->unregister_resource(subprocess);  // Also deletes subprocess.
  subprocess_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(kill) {
  ARGS(IntResource, subprocess, int, signal);
  if (subprocess->resource_group()->event_source() != SubprocessEventSource::instance()) WRONG_TYPE;
  kill(subprocess->id(), signal);
  return process->program()->null_object();
}

PRIMITIVE(strsignal) {
  ARGS(int, signal);
  const char* name = strsignal(signal);
  return process->allocate_string_or_error(name, strlen(name));
}

} // namespace toit

#endif // TOIT_LINUX or TOIT_BSD
