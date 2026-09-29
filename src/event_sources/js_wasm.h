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

#pragma once

#include "../top.h"

#ifdef TOIT_WASM

#include "../resource.h"

namespace toit {

// A call to a JavaScript function. The function may return a promise, so
// the result arrives asynchronously, through JsEventSource::complete.
class JsCallResource : public IntResource {
 public:
  TAG(JsCallResource);
  JsCallResource(ResourceGroup* group, word id) : IntResource(group, id) {}

  ~JsCallResource() override {
    free(result_);
  }

  bool is_done() const { return done_; }
  bool is_error() const { return is_error_; }
  const uint8* result() const { return result_; }
  word result_length() const { return result_length_; }

  // Takes over the malloced result.
  void set_result(uint8* result, word length, bool is_error) {
    free(result_);
    result_ = result;
    result_length_ = length;
    is_error_ = is_error;
    done_ = true;
  }

 private:
  bool done_ = false;
  bool is_error_ = false;
  uint8* result_ = null;
  word result_length_ = 0;
};

// Receives the results of calls to JavaScript functions.
class JsEventSource : public EventSource {
 public:
  static JsEventSource* instance() { return instance_; }

  JsEventSource();
  ~JsEventSource() override;

  // Returns a fresh id for a call.
  word next_id();

  // Completes the call with the given id. Takes over the malloced result.
  // Called from JavaScript (through toit_js_call_complete), when the
  // function has returned or its promise has settled.
  void complete(word id, uint8* result, word length, bool is_error);

 private:
  static JsEventSource* instance_;
  word next_id_ = 1;
};

}  // namespace toit

#endif  // TOIT_WASM
