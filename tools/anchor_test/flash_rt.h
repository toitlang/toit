// Copyright (C) 2026 Toit contributors.
//
// Host-test stub for the EC618 SDK flash_rt.h. The implementations live in
// test.c so they can operate on the fake flash buffer and inject faults.
#pragma once
#include <stdint.h>

#define QSPI_OK ((uint8_t)0x00)

uint8_t BSP_QSPI_Erase_Safe(uint32_t SectorAddress, uint32_t Size);
uint8_t BSP_QSPI_Write_Safe(uint8_t* pData, uint32_t WriteAddr, uint32_t Size);
