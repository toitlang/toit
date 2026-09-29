// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Emscripten JavaScript library with the JavaScript side of the 'js'
// primitives (src/resources/js_wasm.cc). All values are passed as JSON, so
// strings that cross the boundary are always valid UTF-8.

addToLibrary({
  $toitJsonStringify: (value) => {
    // JSON.stringify returns undefined for undefined and functions.
    return JSON.stringify(value) ?? 'null';
  },

  $toitErrorJson: (error) => {
    return JSON.stringify(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
  },

  toit_js_eval__deps: ['$UTF8ToString', '$stringToNewUTF8', '$lengthBytesUTF8',
                       '$toitJsonStringify', '$toitErrorJson'],
  toit_js_eval: (code, codeLength, resultLengthPtr, isErrorPtr) => {
    let json;
    let isError = 0;
    try {
      // Indirect eval, so the code runs in the global scope.
      const value = (0, eval)(UTF8ToString(code, codeLength));
      json = toitJsonStringify(value);
    } catch (e) {
      json = toitErrorJson(e);
      isError = 1;
    }
    {{{ makeSetValue('resultLengthPtr', 0, 'lengthBytesUTF8(json)', '*') }}};
    {{{ makeSetValue('isErrorPtr', 0, 'isError', 'i32') }}};
    return stringToNewUTF8(json);
  },

  toit_js_call_start__deps: ['$UTF8ToString', '$stringToNewUTF8', '$lengthBytesUTF8',
                             '$callUserCallback', '$toitJsonStringify', '$toitErrorJson',
                             'toit_js_call_complete'],
  toit_js_call_start: (id, name, nameLength, args, argsLength) => {
    const complete = (json, isError) => {
      callUserCallback(() => {
        _toit_js_call_complete(id, stringToNewUTF8(json), lengthBytesUTF8(json), isError);
      });
    };
    let promise;
    try {
      const functionName = UTF8ToString(name, nameLength);
      // Functions provided by the embedder take precedence over globals.
      // Dotted names, like 'Math.max', are resolved property by property,
      // and the function is called with its parent object as receiver.
      const functions = Module['toitFunctions'] ?? {};
      let receiver = undefined;
      let fn = functions[functionName];
      if (fn === undefined) {
        const path = functionName.split('.');
        fn = path[0] in functions ? functions : globalThis;
        for (const key of path) {
          receiver = fn;
          fn = fn?.[key];
        }
      }
      if (typeof fn !== 'function') {
        throw new TypeError(`'${functionName}' is not a function`);
      }
      const argsArray = JSON.parse(UTF8ToString(args, argsLength));
      promise = Promise.resolve(fn.apply(receiver, argsArray));
    } catch (e) {
      promise = Promise.reject(e);
    }
    // The result is always delivered asynchronously, after the primitive
    // has returned.
    promise.then((value) => {
      let json;
      try {
        json = toitJsonStringify(value);
      } catch (e) {
        complete(toitErrorJson(e), 1);
        return;
      }
      complete(json, 0);
    }, (error) => complete(toitErrorJson(error), 1));
  },
});
