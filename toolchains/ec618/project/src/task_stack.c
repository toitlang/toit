// Copyright (C) 2026 Toit contributors.

#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

extern StackType_t* __real_pxPortInitialiseStack(StackType_t* top,
                                                TaskFunction_t entry,
                                                void* argument);

// The prebuilt kernel rounds stack tops to four bytes. AAPCS requires eight
// at C call boundaries; otherwise newlib reads variadic doubles at the wrong
// address. Align before the port constructs the initial exception frame, for
// both dynamically and statically allocated tasks.
StackType_t* __wrap_pxPortInitialiseStack(StackType_t* top,
                                        TaskFunction_t entry,
                                        void* argument) {
  top = (StackType_t*)((uintptr_t)top & ~(uintptr_t)7);
  return __real_pxPortInitialiseStack(top, entry, argument);
}
