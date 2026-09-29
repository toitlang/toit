// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Support for interacting with the JavaScript host.

This library is only available on the Wasm platform, when the VM runs in a
  browser or in Node.js.

Values cross the boundary as JSON: Toit values are converted with
  $json.stringify, and JavaScript values with `JSON.stringify`. Values
  that JSON can't represent, like functions and `undefined`, become null.

# Examples
```
import js

main:
  print (js.eval "navigator.userAgent")
  js.eval "document.title = 'Hello from Toit'"
  // Blocks the current task until the promise settles.
  text := js.call "fetchText" ["https://example.com"]
```
*/

import encoding.json
import monitor show ResourceState_

/**
Evaluates the JavaScript $code in the global scope and returns the result.

Throws the error message if the evaluation throws.
*/
eval code/string -> any:
  return decode-result_ (js-call-result_ (js-eval_ resource-group_ code))

/**
Calls the JavaScript function with the given $name and $arguments, and
  returns the result.

The function is first looked up in the functions the embedder provided when
  it started the VM, and then in the global scope. The $name may be a
  dotted path, like "Math.max" or "console.log", in which case the function
  is called with the object that contains it as receiver.

If the function returns a promise, then the current task is blocked until
  the promise settles. Other tasks keep running.

Throws the error message if the function throws, or if the promise is
  rejected.
*/
call name/string arguments/List=[] -> any:
  resource := js-call-start_ resource-group_ name (json.stringify arguments)
  state := ResourceState_ resource-group_ resource
  try:
    state.wait
    return decode-result_ (js-call-result_ resource)
  finally:
    state.dispose

decode-result_ result/Array_ -> any:
  value := json.parse result[1]
  if result[0]: throw value
  return value

resource-group_ ::= js-init_

js-init_:
  #primitive.js.init

js-eval_ group code/string:
  #primitive.js.eval

js-call-start_ group name/string arguments/string:
  #primitive.js.call-start

js-call-result_ resource -> Array_:
  #primitive.js.call-result
