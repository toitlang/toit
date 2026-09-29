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

#ifdef TOIT_WASM

#include "../event_sources/js_wasm.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"

// Implemented in JavaScript, in src/wasm/library_toit.js. All values are
// passed as JSON.
extern "C" {
  // Evaluates the code and returns the malloced JSON result, or the JSON
  // encoded error message if the evaluation threw.
  uint8* toit_js_eval(const uint8* code, word code_length, word* result_length, int* is_error);
  // Calls the function with the given name. The result is delivered
  // asynchronously with toit_js_call_complete.
  void toit_js_call_start(word id,
                          const uint8* name, word name_length,
                          const uint8* arguments, word arguments_length);
}

namespace toit {

class JsResourceGroup : public ResourceGroup {
 public:
  TAG(JsResourceGroup);
  JsResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return state | 1;
  }
};

MODULE_IMPLEMENTATION(js, MODULE_JS)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  JsResourceGroup* group = _new JsResourceGroup(process, JsEventSource::instance());
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

// Evaluates JavaScript code synchronously. The result is stored in a call
// resource, which is read with call_result. This way, the evaluation itself
// never has to be retried because of an allocation failure.
PRIMITIVE(eval) {
  ARGS(JsResourceGroup, group, Blob, code);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  JsCallResource* resource = _new JsCallResource(group, JsEventSource::instance()->next_id());
  if (resource == null) FAIL(MALLOC_FAILED);

  // From here on, the primitive must not fail, since that would evaluate
  // the code again.
  word length = 0;
  int is_error = 0;
  uint8* result = toit_js_eval(code.address(), code.length(), &length, &is_error);
  resource->set_result(result, length, is_error != 0);
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(call_start) {
  ARGS(JsResourceGroup, group, Blob, name, Blob, arguments);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  JsCallResource* resource = _new JsCallResource(group, JsEventSource::instance()->next_id());
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  toit_js_call_start(resource->id(),
                     name.address(), name.length(),
                     arguments.address(), arguments.length());
  return proxy;
}

// Returns an array with a boolean that tells whether the call threw, and a
// JSON string with the result or the error message. Closes the resource.
PRIMITIVE(call_result) {
  ARGS(JsCallResource, resource);
  if (!resource->is_done()) FAIL(INVALID_STATE);

  Array* result = process->object_heap()->allocate_array(2, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);
  // Without a result, JavaScript failed to allocate the JSON string.
  bool is_error = resource->is_error() || resource->result() == null;
  String* json = resource->result() == null
      ? process->allocate_string("\"MALLOC_FAILED\"")
      : process->allocate_string(char_cast(resource->result()), resource->result_length());
  if (json == null) FAIL(ALLOCATION_FAILED);
  result->at_put(0, BOOL(is_error));
  result->at_put(1, json);

  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return result;
}

}  // namespace toit

#endif  // TOIT_WASM
