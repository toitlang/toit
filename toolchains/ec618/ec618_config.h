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
#define CONFIG_TOIT_EC618_PRINT_UART 1
#endif

// Which UART controller takes the print redirect when
// CONFIG_TOIT_EC618_PRINT_UART is 1. Valid values: 0, 1, 2.
//
// Defaults to UART0 — the conventional debug port. The bootloader / PLAT
// unilog stream already comes out UART0, so consolidating Toit's `print`
// onto the same channel keeps all debug output on one wire, and leaves
// UART1 (the AT-style "user" port on most modules) free by default.
#ifndef CONFIG_TOIT_EC618_PRINT_UART_ID
#define CONFIG_TOIT_EC618_PRINT_UART_ID 0
#endif

// Baud rate used for the print UART when the redirect is enabled.
#ifndef CONFIG_TOIT_EC618_PRINT_UART_BAUD
#define CONFIG_TOIT_EC618_PRINT_UART_BAUD 115200
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

#endif  // TOIT_EC618_CONFIG_H_
