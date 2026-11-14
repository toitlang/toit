// Copyright (C) 2026 Toit contributors.
//
// Map the emulator's anchor buffer to its real EC618 physical address.
// The separate address-only base-id symbol uses the same translation.
#pragma once
#include <stdint.h>
extern uint8_t __toit_anchor_start[];
#define AP_FLASH_XIP_ADDR ((uint32_t)(uintptr_t)__toit_anchor_start - 0x1b1000u)
