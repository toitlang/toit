// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#ifndef TOIT_PICO_W_2023_BOARD_H
#define TOIT_PICO_W_2023_BOARD_H

// The W-2023 clone uses the original Pico layout with an ESP8285 on UART0.
// It must not select the official Pico W CYW43 SPI driver.
#define TOIT_PICO_W_2023 1
#include "boards/pico.h"

// Leave GP0/GP1 for the onboard modem. The rig's external UART uses GP16/GP17.
#define TOIT_RP2040_RECOVERY_PIN 17
#endif
