// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_FREERTOS

#include "../primitive.h"

namespace toit {

MODULE_IMPLEMENTATION(signal, MODULE_SIGNAL)

PRIMITIVE(init) { FAIL(UNSUPPORTED); }
PRIMITIVE(watch) { FAIL(UNSUPPORTED); }
PRIMITIVE(unwatch) { FAIL(UNSUPPORTED); }
PRIMITIVE(reset) { FAIL(UNSUPPORTED); }
PRIMITIVE(ignore) { FAIL(UNSUPPORTED); }
PRIMITIVE(raise) { FAIL(UNSUPPORTED); }
// No signals here, so the constants in the host package's signal library
// resolve to null.
PRIMITIVE(number) { return process->null_object(); }

}  // namespace toit

#endif  // TOIT_FREERTOS
