// Copyright (C) 2026 Toit contributors.
//
// Board-specific initialization for the Toit project on EC618.

#include <stdio.h>
#include <string.h>

#include "bsp.h"
#include "bsp_custom.h"
#include "clock.h"
#include "slpman.h"
#include "plat_config.h"

#include "Driver_USART.h"

#include "anchor.h"

#if CONFIG_TOIT_EC618_DISABLE_UNILOG
// Defined in the prebuilt PLAT library — turns off the bottom-level UART0
// log so the controller can be repurposed.
extern void soc_uart0_set_log_off(uint8_t is_off);
#endif

extern ARM_DRIVER_USART Driver_USART0;
extern ARM_DRIVER_USART Driver_USART1;
extern ARM_DRIVER_USART Driver_USART2;

#if CONFIG_TOIT_EC618_PRINT_UART

// The console UART is RUNTIME state from the anchor record (per-device
// provisioning, gen-anchor --console-uart), so ONE base image serves
// every rig — a compile-time id would fork the base fingerprint per
// debug wire. Known issue with console=1: one garbled line at the start
// of every cold boot ("boot.rom"-shaped fragment). Our SetPrintUart path
// is the only code in the PLAT that initialises Driver_USART1 directly
// via the CMSIS USART API; the init flushes chip-level TX state that is
// otherwise invisible. ARM_USART_ABORT_SEND below reduces the noise from
// many bytes to one; the last byte sits in the shift register and we
// have not found a way to kill it from software. A warm reset is clean.
static ARM_DRIVER_USART* const print_uart_drivers[3] = {
    &Driver_USART0, &Driver_USART1, &Driver_USART2,
};
static const ClockId_e print_uart_clocks[3] = {FCLK_UART0, FCLK_UART1, FCLK_UART2};
static const ClockSelect_e print_uart_clksrcs[3] = {
    FCLK_UART0_SEL_26M, FCLK_UART1_SEL_26M, FCLK_UART2_SEL_26M,
};
static const ClockResetId_e print_uart_resets[3] = {
    RST_FCLK_UART0, RST_FCLK_UART1, RST_FCLK_UART2,
};

// Newlib _write syscall: printf -> UART SendPolling on the print driver.
//
// SendPolling returns ARM_DRIVER_ERROR_BUSY while an asynchronous DMA
// Send from the Toit uart driver is in flight on the SAME controller
// (the agent shares the console UART). Without a retry, console bytes
// are silently clipped exactly when the agent transmits — and the test
// rig parses console lines. Spin bounded by roughly one staging-buffer
// drain (2 KiB at 115200 ~= 180 ms); the SEND_COMPLETE irq that clears
// the busy state keeps firing while we spin in task context.
int _write(int file, char *ptr, int len) {
    (void)file;
    if (UsartPrintHandle == NULL) return len;
    for (volatile int spin = 0; spin < 30000000; spin++) {
        int32_t status = UsartPrintHandle->SendPolling((const uint8_t*)ptr, len);
        if (status != ARM_DRIVER_ERROR_BUSY) break;
    }
    return len;
}

static void SetPrintUart(void) {
    uint8_t console = anchor_console();
    if (console > 2) return;  // ANCHOR_CONSOLE_OFF: no redirect.
    ARM_DRIVER_USART* driver = print_uart_drivers[console];

    GPR_setClockSrc(print_uart_clocks[console], print_uart_clksrcs[console]);
    GPR_clockEnable(print_uart_clocks[console]);
    GPR_swReset(print_uart_resets[console]);

    driver->Initialize(NULL);
    driver->PowerControl(ARM_POWER_FULL);
    driver->Control(ARM_USART_MODE_ASYNCHRONOUS |
                    ARM_USART_DATA_BITS_8 |
                    ARM_USART_PARITY_NONE |
                    ARM_USART_STOP_BITS_1 |
                    ARM_USART_FLOW_CONTROL_NONE,
                    CONFIG_TOIT_EC618_PRINT_UART_BAUD);
    // Best-effort mitigation for the cold-boot TX garbage described above:
    // drop any bytes already in the controller's TX path.
    driver->Control(ARM_USART_ABORT_SEND, 0);
    driver->Control(ARM_USART_CONTROL_TX, 1);

    UsartPrintHandle = driver;
}

#else  // CONFIG_TOIT_EC618_PRINT_UART

// Print redirect disabled: keep printf output wherever the PLAT put it
// (unilog / USB CDC / ...). We still provide a _write stub so newlib
// doesn't drag in the default one.
int _write(int file, char *ptr, int len) {
    (void)file;
    (void)ptr;
    return len;
}

#endif  // CONFIG_TOIT_EC618_PRINT_UART

void BSP_CustomInit(void) {
#if CONFIG_TOIT_EC618_VM_WATCHDOG
    // Leave the always-on (AON) watchdog running: it is the platform's
    // whole-chip liveness guard, armed by the boot ROM (~27s) and auto-fed by
    // the CP core whenever a healthy CP runs. Feed it once here to refresh
    // the window from early boot, covering the time until the CP is up.
    // The deep-sleep path stops it before hibernating (toit_ec618.cc), where
    // the CP stops feeding.
    slpManAonWdtFeed();
#else
    // CP-less debugging (bring-up, missing/mismatched CP image): nothing
    // would feed the AON, so stop it before it reboots the device (~27s).
    slpManAonWdtStop();
#endif

#if CONFIG_TOIT_EC618_DISABLE_UNILOG
    // Silence the PLAT debug log stream. soc_uart0_set_log_off(1) detaches
    // the bottom-level driver from UART0 so the controller is free for our
    // use; setting LOG_CONTROL=0 stops the unilog scheduler from doing
    // background work even when no UART is wired up.
    soc_uart0_set_log_off(1);
    BSP_SetPlatConfigItemValue(PLAT_CONFIG_ITEM_LOG_CONTROL, 0);
#endif

#if CONFIG_TOIT_EC618_PRINT_UART
    SetPrintUart();
    setvbuf(stdout, NULL, _IONBF, 0);

    // Test: write directly via SendPolling (synchronous).
    const char *msg = "[toit] BSP_CustomInit reached\r\n";
    UsartPrintHandle->SendPolling((const uint8_t*)msg, 31);
#else
    // Print redirect disabled. With no SetPrintUart() and nothing else
    // referencing the CMSIS USART driver, the linker (--gc-sections)
    // drops Driver_USART* and everything reachable from them — including
    // the per-controller USARTx_IRQHandler symbols that live in the same
    // bsp_usart.c TU. Something in the precompiled PLAT path then ends
    // up dispatching a UART interrupt (likely UART0, left in a
    // half-initialised state by the bootROM / bootloader) to an
    // undefined handler, hard-faulting the AP and locking the device in
    // a cold-boot loop.
    //
    // Force-link Driver_USART2 to keep the whole driver TU alive. The
    // address is stored in a volatile pointer so the compiler can't
    // optimise the reference away; we never actually use the driver.
    static ARM_DRIVER_USART * volatile keep_usart_driver_linked_ = &Driver_USART2;
    (void)keep_usart_driver_linked_;

    setvbuf(stdout, NULL, _IONBF, 0);
#endif
}
