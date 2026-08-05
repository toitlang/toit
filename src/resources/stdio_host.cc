// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if !defined(TOIT_FREERTOS)

#ifdef TOIT_WINDOWS
#include "../error_win.h"
#endif

#include "../event_sources/stdio_host.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

class StdinResource : public Resource {
 public:
  TAG(StdinResource);

  explicit StdinResource(ResourceGroup* group) : Resource(group) {}
};

class StdinResourceGroup : public ResourceGroup {
 public:
  TAG(StdinResourceGroup);

  StdinResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return state | static_cast<uint32_t>(data);
  }
};

MODULE_IMPLEMENTATION(stdio, MODULE_STDIO)

PRIMITIVE(stdin_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  StdinEventSource* event_source = StdinEventSource::instance();
  if (!event_source->use()) FAIL(ERROR);

  auto group = _new StdinResourceGroup(process, event_source);
  if (group == null) {
    event_source->unuse();
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(stdin_open) {
  ARGS(StdinResourceGroup, group)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto resource = _new StdinResource(group);
  if (resource == null) FAIL(MALLOC_FAILED);
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(stdin_read) {
  ARGS(StdinResource, resource)
  USE(resource);

  StdinEventSource* event_source = StdinEventSource::instance();
  int error = 0;
  int size = event_source->data_size(&error);
  if (error != 0) {
#ifdef TOIT_WINDOWS
    return windows_error(process, error);
#else
    return Primitive::os_error(error, process);
#endif
  }
  if (size < 0) return Smi::from(-1);
  if (size == 0) return process->null_object();

  ByteArray* result = process->allocate_byte_array(size, true);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);
  int read = event_source->read(bytes.address(), size, &error);
  if (error != 0) {
#ifdef TOIT_WINDOWS
    return windows_error(process, error);
#else
    return Primitive::os_error(error, process);
#endif
  }
  if (read < 0) return Smi::from(-1);
  if (read == 0) return process->null_object();
  if (read < size) result->resize_external(process, read);
  return result;
}

}  // namespace toit

#endif  // !defined(TOIT_FREERTOS)
