// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.
#pragma once

#include <assert.h>

#define configUSE_PREEMPTION 1
#define configUSE_TIME_SLICING 1
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0
#define configUSE_CO_ROUTINES 0
// This file is also included while Pico's config headers are being built;
// hardware headers here would create an include cycle.
#define configCPU_CLOCK_HZ (clock_get_hz(clk_sys))
#define configTICK_RATE_HZ 1000
#define configMAX_PRIORITIES 5
#define configMINIMAL_STACK_SIZE 256
#define configMAX_TASK_NAME_LEN 16
#define configTICK_TYPE_WIDTH_IN_BITS TICK_TYPE_WIDTH_32_BITS
#define configIDLE_SHOULD_YIELD 1
#define configUSE_MUTEXES 1
#define configUSE_RECURSIVE_MUTEXES 1
#define configUSE_COUNTING_SEMAPHORES 1
#define configUSE_TASK_NOTIFICATIONS 1
#define configNUM_THREAD_LOCAL_STORAGE_POINTERS 1
#define configSUPPORT_STATIC_ALLOCATION 1
#define configKERNEL_PROVIDED_STATIC_MEMORY 1
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configUSE_NEWLIB_REENTRANT 1
#define configCHECK_FOR_STACK_OVERFLOW 2
#define configUSE_MALLOC_FAILED_HOOK 0
#define configUSE_TIMERS 1
#define configTIMER_TASK_PRIORITY 2
#define configTIMER_QUEUE_LENGTH 8
#define configTIMER_TASK_STACK_DEPTH 512
#define configNUMBER_OF_CORES 1
#define configTICK_CORE 0
#define configRUN_MULTIPLE_PRIORITIES 1
#define configUSE_CORE_AFFINITY 0
#define configSUPPORT_PICO_SYNC_INTEROP 1
#define configSUPPORT_PICO_TIME_INTEROP 1
#define configENABLE_FPU 1
#define configENABLE_MPU 0
#define configENABLE_TRUSTZONE 0
#define configRUN_FREERTOS_SECURE_ONLY 1
#define configMAX_SYSCALL_INTERRUPT_PRIORITY 0x80
#define configASSERT(x) do { if (!(x)) panic("FreeRTOS assertion: %s (%s:%d)", #x, __FILE__, __LINE__); } while (0)
#define INCLUDE_vTaskDelay 1
#define INCLUDE_vTaskDelete 1
#define INCLUDE_vTaskSuspend 1
#define INCLUDE_xTaskGetSchedulerState 1
#define INCLUDE_xTaskGetCurrentTaskHandle 1
#define INCLUDE_uxTaskGetStackHighWaterMark 1
#define INCLUDE_xSemaphoreGetMutexHolder 1
#define INCLUDE_xTimerPendFunctionCall 1
