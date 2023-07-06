// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.ubjson

// To confuse the clever type propagator, we encode the literal false as
// ubjson. We branch on the decoded value and convince the type propagator
// that we might read anything from a hypothetical decoded list.
CONFUSED_UBJSON ::= #[0x46]
CONFUSED_DECODED ::= ubjson.decode CONFUSED_UBJSON

confuse x/any -> any:
  if CONFUSED_DECODED: return CONFUSED_DECODED[0]
  return x
