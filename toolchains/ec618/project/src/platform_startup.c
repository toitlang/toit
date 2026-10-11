// Copyright (C) 2026 Toit contributors.
//
// Toit-owned replacement for libcore_airm2m.a's main_entry. Keep the
// platform initialization order, but do not require the module-specific
// APNV4 string (32 characters beginning with "20"). QCX216 boards can
// lack that value; the vendor entry then halts before starting the kernel.
// No NVRAM contents are changed or fabricated here.
//
// Link with --wrap=main_entry because the vendor object also provides BSP
// functions we still need. Startup calls this entry instead of the vendor
// main, while those other functions remain available.

#include <stdio.h>

#include "bsp.h"
#include "cmsis_os2.h"
#include "ostask.h"

// Platform entry points exported by the precompiled LuatOS support library.
extern void am_sys_low_init(void);
extern void am_service_init(void);
extern void user_hardware_init(void);
extern void user_task_init(void);

#if defined(TOIT_EC618_BOOT_DIAGNOSTICS)
extern void toit_boot_diagnostic_console_init(void);
#define BOOT_TRACE(message) printf("[boot-diag] %s\n", message)
#else
#define BOOT_TRACE(message) ((void)0)
#endif

// The vendor entry registers an empty callback at this stage. Application
// tasks, including the Toit dispatcher, are created by user_task_init.
static void platform_app_init(void *argument) {
    (void)argument;
}

void __wrap_main_entry(void) {
    BSP_CommonInit();
#if defined(TOIT_EC618_BOOT_DIAGNOSTICS)
    toit_boot_diagnostic_console_init();
#endif
    BOOT_TRACE("Toit platform entry; BSP ready");
    am_sys_low_init();
    BOOT_TRACE("low-level init complete; module NVRAM gate omitted");
    am_service_init();
    BOOT_TRACE("platform services initialized");
    user_hardware_init();
    BOOT_TRACE("hardware initialized; starting kernel setup");

    osStatus_t status = osKernelInitialize();
    if (status == osOK) {
        registerAppEntry(platform_app_init, NULL);
        user_task_init();
        BOOT_TRACE("tasks initialized; starting scheduler");
        if (osKernelGetState() == osKernelReady) {
            status = osKernelStart();
        }
    }

    // Reaching here means that kernel setup or scheduler startup failed.
    printf("[toit] ERROR: kernel startup returned (status=%d, state=%d)\n",
           (int)status, (int)osKernelGetState());
    while (1) {}
}
