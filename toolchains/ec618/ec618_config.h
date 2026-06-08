// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Toit-owned build-time configuration for the EC618 port.
//
// This header is force-included (via -include) by both the CMake/ninja
// build that produces libtoit_vm.a and the xmake build that links the
// final PLAT image, so every translation unit sees the same defaults.
//
// Each knob is wrapped in #ifndef, so downstream projects can override
// an individual value by defining it on the compiler command line
// (e.g. -DCONFIG_TOIT_EC618_PRINT_UART=0) without having to patch this
// file.

#ifndef TOIT_EC618_CONFIG_H_
#define TOIT_EC618_CONFIG_H_

// Whether printf / Toit's `print` output should be routed to a UART at
// all. When disabled, all three UART controllers are free for
// application use; diagnostic output still goes to whatever the PLAT
// configures (USB CDC, unilog, ...).
#ifndef CONFIG_TOIT_EC618_PRINT_UART
// Temporarily 1 to surface [toit] printf() output (e.g. the slot
// primitives' debug prints) while the OTA path is still being
// brought up. Output mixes with the protocol bytes on UART1 — the
// host strips status lines but raw [toit] log noise around an ack
// can confuse it. Disable again once the receiver is stable.
#define CONFIG_TOIT_EC618_PRINT_UART 1
#endif

// Which UART controller takes the print redirect when
// CONFIG_TOIT_EC618_PRINT_UART is 1. Valid values: 0, 1, 2.
//
// Defaults to UART0 — the conventional debug port. The bootloader / PLAT
// unilog stream already comes out UART0, so consolidating Toit's `print`
// onto the same channel keeps all debug output on one wire, and leaves
// UART1 (the AT-style "user" port on most modules) free by default.
//
// Known issue with _ID=1: setting print to UART1 produces one garbled
// line at the start of every cold-boot ("boot.rom"-shaped fragment).
// Diagnosis: our SetPrintUart path is the only project in the PLAT that
// initialises Driver_USART1 directly via the CMSIS USART API; every
// other example uses unilog. The CMSIS init flushes some chip-level TX
// state that's normally invisible because nothing else triggers it.
// ARM_USART_ABORT_SEND in SetPrintUart reduces the noise from many
// bytes to one, but the remaining byte is in the shift register and we
// have not found a way to kill it from software. A warm reset is clean.
// Pick _ID=0 or _ID=2, or set CONFIG_TOIT_EC618_PRINT_UART=0, to avoid.
#ifndef CONFIG_TOIT_EC618_PRINT_UART_ID
// Which UART carries `print` + the mini-jag control protocol. This is
// rig-specific: the quirky-plenty dev rig breaks out UART1, the modest-affair
// test rig breaks out UART0 (set this to 0 there). The mini-jag agent follows
// this value (via ec618.print-uart-id), so a rig switch only changes this line
// — not the agent. The shared wire needs CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE
// below. (Known cosmetic issue with _ID=1: one garbled line on cold boot.)
#define CONFIG_TOIT_EC618_PRINT_UART_ID 0
#endif

// Baud rate used for the print UART when the redirect is enabled.
#ifndef CONFIG_TOIT_EC618_PRINT_UART_BAUD
#define CONFIG_TOIT_EC618_PRINT_UART_BAUD 115200
#endif

// Allow opening a `uart.Port` on the same UART controller that print
// output is going to. By default the UART primitive rejects this with
// `ALREADY_IN_USE` because mixed TX is surprising at runtime; the
// dual-slot OTA path needs to receive on the print UART (only one
// wire on quirky-plenty), so this knob exists to lift the check. We
// have verified empirically that concurrent TX+RX on this chip works
// — there's no driver-level fight — but interleaved bytes on TX are
// up to the application to manage.
#ifndef CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE
// 1 while the dual-slot OTA receiver shares UART1 with print output.
#define CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE 1
#endif

// Whether to silence the PLAT "unilog" debug stream at startup. The PLAT
// SDK normally pumps unilog out UART0 (at 3 Mbaud) and/or USB CDC. With
// no consumer of that stream we just want it gone — saves CPU/DMA, and
// frees UART0 so application code can drive it via `uart.Port`.
//
// When enabled (default), `BSP_CustomInit` calls
//   soc_uart0_set_log_off(1)
//   BSP_SetPlatConfigItemValue(PLAT_CONFIG_ITEM_LOG_CONTROL, 0)
// early, which tells the unilog subsystem to stop writing.
//
// Note: the bootloader / mask-ROM banner on UART0 TX (GPIO15) at chip
// reset is in ROM and cannot be suppressed from software.
#ifndef CONFIG_TOIT_EC618_DISABLE_UNILOG
#define CONFIG_TOIT_EC618_DISABLE_UNILOG 1
#endif

// VM-liveness watchdog. When enabled (default), the always-on (AON) hardware
// watchdog is kept running and fed from the Toit scheduler loop
// (OS::feed_watchdog). If the VM wedges with the CPU busy — a stuck primitive,
// a scheduler/GC deadlock — the scheduler stops cycling, the feed stops, and
// the device is reset (~27 s) so it recovers instead of hanging forever. The
// AON timeout is fixed in hardware (~27 s, no configuration API) and the AON
// is gated while the chip sleeps, so it guards busy hangs, not idle sleep, and
// never disturbs a legitimately sleeping device.
//
// Note: on this chip the AON reset is reported as RESET-POWER-ON, not AONWDT
// (the reset reason is not preserved), and it may clear RTC memory like a cold
// boot. The cost is one watchdog kick per second from the scheduler.
//
// When disabled, BSP_CustomInit stops the AON watchdog at boot (the original
// behavior) and the scheduler feed becomes a no-op.
#ifndef CONFIG_TOIT_EC618_VM_WATCHDOG
#define CONFIG_TOIT_EC618_VM_WATCHDOG 1
#endif

// Reset the chip when the boot program's VM exits "done" (all processes
// finished) instead of deep-sleeping with no wakeup timer. Deep-sleep-without-
// wakeup leaves the device dead until an external reset, which a rig with no
// remote reset (e.g. the mini-jag test rig) cannot provide — and the watchdogs
// are gated while the chip sleeps, so they cannot recover it either. A VM "done"
// exit only happens on a full-VM teardown (e.g. a crash in a shared system
// service brings the whole VM down); a long-running agent or a finishing test
// *container* never triggers it, so this only fires on the unrecoverable case
// and turns it into a reboot that lands straight back in the program.
//
// Set to 0 for the upstream/ESP32 behaviour (a finished program sleeps forever),
// e.g. a genuine one-shot app that wants to power down until an external wake.
#ifndef CONFIG_TOIT_EC618_RESET_ON_VM_EXIT
#define CONFIG_TOIT_EC618_RESET_ON_VM_EXIT 1
#endif

#endif  // TOIT_EC618_CONFIG_H_
