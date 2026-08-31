// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_ESP32

#include "../primitive.h"

namespace toit {

MODULE_IMPLEMENTATION(terminal, MODULE_TERMINAL)

PRIMITIVE(init) { FAIL(UNSUPPORTED); }
PRIMITIVE(is_terminal) { FAIL(UNSUPPORTED); }
PRIMITIVE(enter_raw) { FAIL(UNSUPPORTED); }
PRIMITIVE(restore) { FAIL(UNSUPPORTED); }
PRIMITIVE(size) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_init) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_watch) { FAIL(UNSUPPORTED); }
PRIMITIVE(resize_unwatch) { FAIL(UNSUPPORTED); }

}  // namespace toit

#endif  // TOIT_ESP32
