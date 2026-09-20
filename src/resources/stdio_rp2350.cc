// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_RP2350

#include "../event_sources/stdio_rp2350.h"
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
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }
};

MODULE_IMPLEMENTATION(stdio, MODULE_STDIO)

PRIMITIVE(stdin_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Rp2350StdinEventSource* event_source = Rp2350StdinEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  auto group = _new StdinResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

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

  Rp2350StdinEventSource* event_source = Rp2350StdinEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  int size = event_source->data_size();
  if (size == 0) return Smi::from(-1);

  // The event source owns the bytes until allocation succeeds. An allocation
  // failure therefore leaves the complete input available for the retry.
  ByteArray* result = process->allocate_byte_array(size, true);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);
  int read = event_source->read(bytes.address(), size);
  if (read == 0) return Smi::from(-1);
  if (read < size) result->resize_external(process, read);
  return result;
}

}  // namespace toit

#endif  // TOIT_RP2350
