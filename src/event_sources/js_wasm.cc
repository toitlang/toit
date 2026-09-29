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

#include "js_wasm.h"

namespace toit {

JsEventSource* JsEventSource::instance_ = null;

JsEventSource::JsEventSource() : EventSource("JS") {
  ASSERT(instance_ == null);
  instance_ = this;
}

JsEventSource::~JsEventSource() {
  instance_ = null;
}

word JsEventSource::next_id() {
  Locker locker(mutex());
  return next_id_++;
}

void JsEventSource::complete(word id, uint8* result, word length, bool is_error) {
  Locker locker(mutex());
  IntResource* resource = find_resource_by_id(locker, id);
  if (resource == null) {
    // The call was abandoned, for example because the calling process
    // terminated.
    free(result);
    return;
  }
  static_cast<JsCallResource*>(resource)->set_result(result, length, is_error);
  dispatch(locker, resource, 0);
}

}  // namespace toit

#endif  // TOIT_WASM
