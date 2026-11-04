// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if defined(TOIT_POSIX) || defined(TOIT_WINDOWS)

#include "../event_sources/signal.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

class SignalResourceGroup : public ResourceGroup {
 public:
  TAG(SignalResourceGroup);

  SignalResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }
};

MODULE_IMPLEMENTATION(signal, MODULE_SIGNAL)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  SignalEventSource* event_source = SignalEventSource::instance();
  if (!event_source->use()) FAIL(ERROR);

  auto group = _new SignalResourceGroup(process, event_source);
  if (group == null) {
    event_source->unuse();
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

// Takes platform signal numbers. State bit `i` reports numbers[i].
PRIMITIVE(watch) {
  ARGS(SignalResourceGroup, group, Array, numbers);
  int count = numbers->length();
  if (count <= 0 || count > SignalResource::MAX_COUNT) FAIL(INVALID_ARGUMENT);
  uint8 checked[SignalResource::MAX_COUNT];
  SignalEventSource* event_source = SignalEventSource::instance();
  for (int i = 0; i < count; i++) {
    Object* number = numbers->at(i);
    if (!is_smi(number)) FAIL(WRONG_OBJECT_TYPE);
    if (!event_source->is_catchable(Smi::value(number))) FAIL(INVALID_ARGUMENT);
    checked[i] = Smi::value(number);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto resource = _new SignalResource(group, checked, count);
  if (resource == null) FAIL(MALLOC_FAILED);
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unwatch) {
  ARGS(SignalResource, resource, SignalResourceGroup, group);
  if (resource->resource_group() != group) FAIL(WRONG_OBJECT_TYPE);

  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(reset) {
  ARGS(int, number);
  SignalEventSource* event_source = SignalEventSource::instance();
  if (!event_source->is_catchable(number)) FAIL(INVALID_ARGUMENT);
  event_source->set_disposition(number, SIGNAL_DISPOSITION_DEFAULT);
  return process->null_object();
}

PRIMITIVE(ignore) {
  ARGS(int, number);
  SignalEventSource* event_source = SignalEventSource::instance();
  if (!event_source->is_catchable(number)) FAIL(INVALID_ARGUMENT);
  event_source->set_disposition(number, SIGNAL_DISPOSITION_IGNORE);
  return process->null_object();
}

PRIMITIVE(raise) {
  ARGS(int, number);
  SignalEventSource* event_source = SignalEventSource::instance();
  if (!event_source->is_supported(number)) FAIL(INVALID_ARGUMENT);
  int error = event_source->raise(number);
  if (error != 0) return Primitive::os_error(error, process);
  return process->null_object();
}

// Returns the platform's signal number for a name such as "INT", or null if
// the platform has no signal with that name.
PRIMITIVE(number) {
  ARGS(cstring, name);
  int number = SignalEventSource::instance()->number(name);
  if (number == 0) return process->null_object();
  return Smi::from(number);
}

}  // namespace toit

#endif  // defined(TOIT_POSIX) || defined(TOIT_WINDOWS)
