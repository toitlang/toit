// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include "third_party/dartino/cmpctmalloc.h"

#ifdef __cplusplus
extern "C" {
#endif
void toit_rp2040_heap_info(multi_heap_info_t *info);
#ifdef __cplusplus
}
#endif
