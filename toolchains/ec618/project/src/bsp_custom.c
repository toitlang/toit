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

#if CONFIG_TOIT_EC618_DISABLE_UNILOG
// Defined in the prebuilt PLAT library — turns off the bottom-level UART0
// log so the controller can be repurposed.
extern void soc_uart0_set_log_off(uint8_t is_off);
#endif

extern ARM_DRIVER_USART Driver_USART0;
extern ARM_DRIVER_USART Driver_USART1;
extern ARM_DRIVER_USART Driver_USART2;

#if CONFIG_TOIT_EC618_PRINT_UART

#if CONFIG_TOIT_EC618_PRINT_UART_ID == 0
#  define TOIT_PRINT_UART_DRIVER Driver_USART0
#  define TOIT_PRINT_UART_CLOCK  FCLK_UART0
#  define TOIT_PRINT_UART_CLKSRC FCLK_UART0_SEL_26M
#  define TOIT_PRINT_UART_RESET  RST_FCLK_UART0
#elif CONFIG_TOIT_EC618_PRINT_UART_ID == 1
#  define TOIT_PRINT_UART_DRIVER Driver_USART1
#  define TOIT_PRINT_UART_CLOCK  FCLK_UART1
#  define TOIT_PRINT_UART_CLKSRC FCLK_UART1_SEL_26M
#  define TOIT_PRINT_UART_RESET  RST_FCLK_UART1
#elif CONFIG_TOIT_EC618_PRINT_UART_ID == 2
#  define TOIT_PRINT_UART_DRIVER Driver_USART2
#  define TOIT_PRINT_UART_CLOCK  FCLK_UART2
#  define TOIT_PRINT_UART_CLKSRC FCLK_UART2_SEL_26M
#  define TOIT_PRINT_UART_RESET  RST_FCLK_UART2
#else
#  error "CONFIG_TOIT_EC618_PRINT_UART_ID must be 0, 1 or 2"
#endif

// Newlib _write syscall: bridges printf -> io_putchar -> UART SendPolling.
extern int io_putchar(int ch);

int _write(int file, char *ptr, int len) {
    (void)file;
    for (int i = 0; i < len; i++) {
        io_putchar(*ptr++);
    }
    return len;
}

static void SetPrintUart(void) {
    GPR_setClockSrc(TOIT_PRINT_UART_CLOCK, TOIT_PRINT_UART_CLKSRC);
    GPR_clockEnable(TOIT_PRINT_UART_CLOCK);
    GPR_swReset(TOIT_PRINT_UART_RESET);

    TOIT_PRINT_UART_DRIVER.Initialize(NULL);
    TOIT_PRINT_UART_DRIVER.PowerControl(ARM_POWER_FULL);
    TOIT_PRINT_UART_DRIVER.Control(ARM_USART_MODE_ASYNCHRONOUS |
                                   ARM_USART_DATA_BITS_8 |
                                   ARM_USART_PARITY_NONE |
                                   ARM_USART_STOP_BITS_1 |
                                   ARM_USART_FLOW_CONTROL_NONE,
                                   CONFIG_TOIT_EC618_PRINT_UART_BAUD);
    // Best-effort mitigation for the UART1-cold-boot garbage described in
    // toolchains/ec618/ec618_config.h: drop any bytes that were already
    // in the controller's TX path. Reduces the count from many to one;
    // we have not found a way to kill the remaining shift-register byte
    // from software.
    TOIT_PRINT_UART_DRIVER.Control(ARM_USART_ABORT_SEND, 0);
    TOIT_PRINT_UART_DRIVER.Control(ARM_USART_CONTROL_TX, 1);

    UsartPrintHandle = &TOIT_PRINT_UART_DRIVER;
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
