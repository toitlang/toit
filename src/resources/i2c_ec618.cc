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

#include "../top.h"

#ifdef TOIT_EC618

#include <string.h>

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "FreeRTOS.h"
  #include "queue.h"
  #include "task.h"
  #include "bsp_common.h"
  #include "clock.h"         // GPR_setClockSrc: pin the I2C functional clock.
  #include "driver_gpio.h"   // GPIO_PullConfig / GPIO_IomuxEC618.
  #include "gpio.h"          // OEM GPIO_pinConfig/pinRead, for the bus peek.
  #include "ic.h"            // XIC_SetVector: slot-resident IRQ handlers.
  // The base driver owns only stable power/clock lifecycle operations. The
  // transfer state machine and IRQ handlers live in this OTA-updatable slot.
  #include "Driver_I2C.h"
  extern ARM_DRIVER_I2C Driver_I2C0;
  extern ARM_DRIVER_I2C Driver_I2C1;
  extern void delay_us(uint32_t us);  // PLAT busy-wait exported by the base.
}

namespace toit {

// Pin arguments are PAD numbers (the EC618 addressing model). Controller
// routings, all iomux ALT2 (from the SDK's luat_i2c_ec618.c and the
// LuatOS Air780E iomux docs):
//   I2C0: SDA/SCL = 14/13 (the Air780E's I2C0 pins), 27/28 or 31/32
//   I2C1: SDA/SCL = 19/20 or 23/24 (the Air780E's I2C1 pins)
static int pads_to_controller(int sda, int scl) {
  if (sda == 14 && scl == 13) return 0;
  if (sda == 27 && scl == 28) return 0;
  if (sda == 31 && scl == 32) return 0;
  if (sda == 19 && scl == 20) return 1;
  if (sda == 23 && scl == 24) return 1;
  return -1;
}

static ARM_DRIVER_I2C* const kI2cDrivers[2] = { &Driver_I2C0, &Driver_I2C1 };
static I2C_TypeDef* const kI2cRegs[2] = { I2C0, I2C1 };
static const IRQn_Type kI2cIrqs[2] = { PXIC0_I2C0_IRQn, PXIC0_I2C1_IRQn };
static const ClockResetVector_t kI2cResetVectors[2] = {
  I2C0_RESET_VECTOR,
  I2C1_RESET_VECTOR,
};
// Runtime Environment (RTE) pins muxed by Driver_I2C::Initialize. bus_create
// releases these when the user selects another route.
static const uint8_t kRteSda[2] = { 27, 19 };
static const uint8_t kRteScl[2] = { 28, 20 };

enum class I2cStage : uint8_t {
  IDLE,
  SINGLE,
  WRITE_PENDING_READ,
  READING,
};

enum class I2cResult : int {
  OK = 0,
  ADDRESS_NACK,
  BUS_ERROR,
  ARBITRATION_LOST,
  INCOMPLETE,
  CANCELED = -1,
};

class I2cDeviceResource;

// Per-controller state. The async transfer buffers are driver-owned
// copies: an asynchronous transfer outlives the primitive call, and the GC
// moves Toit heap objects, so the hardware must never see a Toit buffer.
struct I2cState {
  bool in_use;
  bool initialized;          // Our Initialize() ran (Initialize is a
                             // no-op on an initialized driver, and
                             // Uninitialize requires a prior Initialize).
  uint32_t current_hz;       // Programmed wire pace once SETUP ran; 0 =
                             // must rerun (cleared by quiesce/power
                             // cycles).
  uint32_t src_hz;           // Selected functional-clock source (26 MHz
                             // or 51.2 MHz); 0 = not yet pinned.
  uint32_t bus_hz;           // Pace for bus-level probes: the most recent
                             // device transfer's frequency (sticky across
                             // quiesce), else kBusDefaultHz.
  volatile bool transfer_active;
  volatile bool hardware_busy;
  bool dedicated_mode;
  volatile I2cStage stage;
  volatile uint32_t count;
  volatile bool notify_toit;     // Async transfer: completion must wake the
                                 // Toit event state. A spin-consumed probe
                                 // must not leave a queued notification.
  volatile uint32_t last_event;  // ARM_I2C_EVENT_* bits; 0 = running.
  volatile uint16_t seq;         // Transfer sequence, bumped at every
                                 // start; the completion dispatch carries
                                 // it so on_event can DISCARD dispatches
                                 // from earlier transfers (e.g. a transfer
                                 // canceled by an outer with-timeout,
                                 // whose late completion would otherwise
                                 // claim the NEXT transfer's wait).
  uint8_t address;               // Target, for the chained read leg.
  I2cDeviceResource* active_device;  // Null for a bus-level probe.
  bool owns_buffers;             // Async transfer (malloc'd) vs probe (stack).
  uint8_t* tx;
  uint32_t tx_len;
  uint8_t* rx;
  uint32_t rx_len;
};

static I2cState i2c_states[2] = {};

static int32_t start_receive(int controller);

enum class I2cTaskAction : uint8_t {
  COMPLETE,
};

struct I2cTaskRequest {
  uint8_t controller;
  uint16_t seq;
  I2cTaskAction action;
};

static QueueHandle_t i2c_chain_queue = null;
static bool i2c_chain_task_created = false;

static bool reserve_controller(int controller) {
  Locker locker(OS::global_mutex());
  I2cState* state = &i2c_states[controller];
  if (state->in_use) return false;
  state->in_use = true;
  return true;
}

static void release_controller(int controller) {
  Locker locker(OS::global_mutex());
  ASSERT(i2c_states[controller].in_use);
  i2c_states[controller].in_use = false;
}

static void send_i2c_completion(int id, I2cState* state, uint32_t event,
                                bool from_isr) {
  state->last_event = event;
  if (!state->notify_toit) return;
  word data = event | (static_cast<uint32_t>(state->seq) << 16);
  if (from_isr) {
    Ec618EventSource::send_event_from_isr(Event::i2c_type(id), data);
  } else {
    Ec618EventSource::send_event(Event::i2c_type(id), data);
  }
}

static void i2c_chain_task(void*) {
  I2cTaskRequest request;
  while (true) {
    if (xQueueReceive(i2c_chain_queue, &request, portMAX_DELAY) != pdTRUE) {
      continue;
    }
    int id = request.controller;
    I2cState* state = &i2c_states[id];
    I2C_TypeDef* regs = kI2cRegs[id];
    for (int wait = 0;
         wait < 2 &&
         state->transfer_active &&
         state->seq == request.seq &&
         (regs->STR & I2C_STR_BUSY_Msk);
         wait++) {
      vTaskDelay(1);
    }
    if (state->transfer_active &&
        state->seq == request.seq &&
        (regs->STR & I2C_STR_BUSY_Msk)) {
      // Dedicated mode puts the STOP on the wire but leaves STR.BUSY
      // latched. The wire has had two scheduler ticks to reach idle; reset
      // just the command engine before publishing completion or beginning a
      // chained read. Preserve the programmed pace and the base driver's
      // stable power/setup lifecycle.
      uint32_t pace = regs->TPR;
      regs->IER = 0;
      GPR_swResetModule(&kI2cResetVectors[id]);
      regs->TPR = pace;
    }

    taskENTER_CRITICAL();
    bool current =
        state->transfer_active && state->seq == request.seq;
    bool notify_completion = false;
    if (current && request.action == I2cTaskAction::COMPLETE) {
      state->hardware_busy = false;
      state->last_event = ARM_I2C_EVENT_TRANSFER_DONE;
      notify_completion = state->notify_toit;
    }
    taskEXIT_CRITICAL();

    if (notify_completion) {
      word data = ARM_I2C_EVENT_TRANSFER_DONE |
          (static_cast<uint32_t>(request.seq) << 16);
      Ec618EventSource::send_event(Event::i2c_type(id), data);
    }
  }
}

static bool ensure_i2c_chain_task() {
  if (i2c_chain_task_created) return true;
  if (i2c_chain_queue == null) {
    i2c_chain_queue = xQueueCreate(2, sizeof(I2cTaskRequest));
    if (i2c_chain_queue == null) return false;
  }
  if (xTaskCreate(i2c_chain_task, "toit_i2c", 512, null,
                  tskIDLE_PRIORITY + 2, null) != pdPASS) {
    return false;
  }
  i2c_chain_task_created = true;
  return true;
}

// Completion callback registered at Initialize. Combined write/read transfers
// use the slot-owned dedicated engine below and never complete between legs.
static void i2c_cmsis_event(int id, uint32_t event) {
  I2cState* state = &i2c_states[id];
  if (!state->transfer_active) return;  // Stale (aborted under us).
  send_i2c_completion(id, state, event, true);
}

static void i2c0_event(uint32_t event) { i2c_cmsis_event(0, event); }
static void i2c1_event(uint32_t event) { i2c_cmsis_event(1, event); }
static const ARM_I2C_SignalEvent_t kI2cCallbacks[2] = { i2c0_event, i2c1_event };

static const uint32_t kKnownLengthMax = 512;

static bool is_transmit(const I2cState* state) {
  return state->stage == I2cStage::WRITE_PENDING_READ ||
      (state->stage == I2cStage::SINGLE && state->tx != null);
}

static bool is_receive(const I2cState* state) {
  return state->stage == I2cStage::READING ||
      (state->stage == I2cStage::SINGLE && state->tx == null);
}

static uint32_t transfer_length(const I2cState* state) {
  return is_transmit(state) ? state->tx_len : state->rx_len;
}

static void start_repeated_receive(I2cState* state, I2C_TypeDef* regs) {
  state->stage = I2cStage::READING;
  state->count = 0;
  regs->IER =
      I2C_IER_DETECT_STOP_Msk |
      I2C_IER_ARBITRATATION_LOST_Msk |
      I2C_IER_BUS_ERROR_Msk |
      I2C_IER_RX_NACK_Msk |
      I2C_IER_RX_ONE_DATA_Msk;
  // Dedicated mode is still holding the bus after the write byte. RESTART
  // queues SLA+R without releasing SDA high while SCL is high.
  regs->SCR =
      ((state->address << 1) & I2C_SCR_TARGET_SLAVE_ADDR_Msk) |
      I2C_SCR_TARGET_RWN_Msk |
      I2C_SCR_START_Msk |
      I2C_SCR_RESTART_Msk;
}

static void i2c_irq(int controller) {
  I2cState* state = &i2c_states[controller];
  I2C_TypeDef* regs = kI2cRegs[controller];
  uint32_t status = regs->ISR;
  regs->ISR = status;  // Write one to clear.
  if (!state->hardware_busy) {
    regs->IER = 0;
    return;
  }

  bool transmit = is_transmit(state);
  bool receive = is_receive(state);
  uint32_t length = transfer_length(state);
  bool dedicated = state->dedicated_mode;
  bool unknown_length = length > kKnownLengthMax;
  bool stop_detected = (status & I2C_ISR_DETECT_STOP_Msk) != 0;
  uint32_t count_before = state->count;
  uint32_t event = 0;
  bool dedicated_done = false;

  if (dedicated && transmit &&
      (status & I2C_ISR_TX_ONE_DATA_Msk)) {
    if (state->count < length) {
      regs->TDR = state->tx[state->count++];
      if (state->count >= length) {
        regs->IER &= ~I2C_IER_TX_ONE_DATA_Msk;
        if (state->stage == I2cStage::WRITE_PENDING_READ) {
          start_repeated_receive(state, regs);
        } else {
          regs->SCR = I2C_SCR_STOP_Msk;
          dedicated_done = true;
        }
      }
    } else {
      regs->IER &= ~I2C_IER_TX_ONE_DATA_Msk;
      if (state->stage == I2cStage::WRITE_PENDING_READ) {
        start_repeated_receive(state, regs);
      } else {
        regs->SCR = I2C_SCR_STOP_Msk;
        dedicated_done = true;
      }
    }
  }

  if (dedicated && receive &&
      (status & I2C_ISR_RX_ONE_DATA_Msk)) {
    state->rx[state->count++] = regs->RDR;
    if (state->count < length) {
      regs->SCR = I2C_SCR_ACK_Msk;
    } else {
      regs->IER &= ~I2C_IER_RX_ONE_DATA_Msk;
      regs->SCR =
          I2C_SCR_ACK_Msk | I2C_SCR_ACK_VALUE_Msk | I2C_SCR_STOP_Msk;
      dedicated_done = true;
    }
  }

  if (receive && !dedicated) {
    uint32_t available =
        EIGEN_FLD2VAL(I2C_FSR_RX_FIFO_DATA_NUM, regs->FSR);
    while (available-- > 0 && state->count < length) {
      state->rx[state->count++] = regs->RDR;
    }
    if (unknown_length && !stop_detected && state->count >= length) {
      regs->IER &=
          ~(I2C_IER_RX_FIFO_FULL_Msk | I2C_IER_WAIT_RX_FIFO_Msk);
      regs->SCR = I2C_SCR_STOP_Msk;
      dedicated_done = true;
    }
  }

  if (transmit && !dedicated) {
    uint32_t free =
        EIGEN_FLD2VAL(I2C_FSR_TX_FIFO_FREE_NUM, regs->FSR);
    while (free-- > 0 && state->count < length) {
      regs->TDR = state->tx[state->count++];
    }
    if (state->count >= length) {
      regs->IER &=
          ~(I2C_IER_TX_FIFO_EMPTY_Msk | I2C_IER_WAIT_TX_FIFO_Msk);
      if (unknown_length && !stop_detected) {
        regs->SCR = I2C_SCR_STOP_Msk;
        dedicated_done = true;
      }
    }
  }

  if (status & I2C_ISR_RX_NACK_Msk) {
    event |= ARM_I2C_EVENT_ADDRESS_NACK | ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }
  if (status & I2C_ISR_BUS_ERROR_Msk) {
    event |= ARM_I2C_EVENT_BUS_ERROR | ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }
  if (status & I2C_ISR_ARBITRATATION_LOST_Msk) {
    event |= ARM_I2C_EVENT_ARBITRATION_LOST |
        ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }
  uint32_t fifo_errors =
      status & (I2C_ISR_TX_FIFO_OVERFLOW_Msk |
                I2C_ISR_RX_FIFO_OVERFLOW_Msk |
                I2C_ISR_TX_FIFO_UNDERRUN_Msk);
  if (fifo_errors != 0) {
    event |= ARM_I2C_EVENT_BUS_ERROR | ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }

  uint32_t service_requests =
      status & (I2C_ISR_TX_FIFO_EMPTY_Msk |
                I2C_ISR_WAIT_TX_FIFO_Msk |
                I2C_ISR_RX_FIFO_FULL_Msk |
                I2C_ISR_WAIT_RX_FIFO_Msk);
  if (event == 0 && state->count < length &&
      state->count == count_before && service_requests != 0) {
    event |= ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }
  if (status & I2C_ISR_TRANSFER_DONE_Msk) {
    event |= ARM_I2C_EVENT_TRANSFER_DONE;
    if (state->count < length) {
      event |= ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
    }
  }
  if (stop_detected && (dedicated || unknown_length) &&
      state->count >= length) {
    event |= ARM_I2C_EVENT_TRANSFER_DONE;
  }

  if (dedicated_done && event == 0) {
    regs->IER = 0;
    I2cTaskRequest request = {
      static_cast<uint8_t>(controller),
      state->seq,
      I2cTaskAction::COMPLETE,
    };
    BaseType_t woken = pdFALSE;
    if (xQueueSendFromISR(i2c_chain_queue, &request, &woken) == pdTRUE) {
      portYIELD_FROM_ISR(woken);
      return;
    }
    event = ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }

  if (event != 0 && state->hardware_busy) {
    regs->IER = 0;
    state->hardware_busy = false;
    i2c_cmsis_event(controller, event);
  }
}

static void i2c0_irq() { i2c_irq(0); }
static void i2c1_irq() { i2c_irq(1); }
static const ISRFunc_T kI2cIrqHandlers[2] = { i2c0_irq, i2c1_irq };

static int32_t power_full(int controller) {
  int32_t result =
      kI2cDrivers[controller]->PowerControl(ARM_POWER_FULL);
  if (result != ARM_DRIVER_OK) return result;
  // PowerControl installs the base driver's handler. Replace it immediately
  // with this slot's handler; the XIC callback table accepts RAM/slot code.
  XIC_SetVector(kI2cIrqs[controller], kI2cIrqHandlers[controller]);
  XIC_EnableIRQ(kI2cIrqs[controller]);
  return ARM_DRIVER_OK;
}

static int32_t start_transmit(int controller) {
  I2cState* state = &i2c_states[controller];
  I2C_TypeDef* regs = kI2cRegs[controller];
  uint32_t length = state->tx_len;
  if (state->hardware_busy || (regs->STR & I2C_STR_BUSY_Msk)) {
    return ARM_DRIVER_ERROR_BUSY;
  }

  state->count = 0;
  state->hardware_busy = true;
  bool dedicated = state->stage == I2cStage::WRITE_PENDING_READ;
  if (dedicated) {
    regs->MCR = 0;
    regs->MCR = I2C_MCR_I2C_EN_Msk;
    state->dedicated_mode = true;
    regs->ISR = regs->ISR;
    regs->TDR = state->tx[state->count++];
    regs->IER =
        I2C_IER_DETECT_STOP_Msk |
        I2C_IER_ARBITRATATION_LOST_Msk |
        I2C_IER_BUS_ERROR_Msk |
        I2C_IER_RX_NACK_Msk |
        I2C_IER_TX_ONE_DATA_Msk;
    regs->SCR =
        ((state->address << 1) & I2C_SCR_TARGET_SLAVE_ADDR_Msk) |
        I2C_SCR_START_Msk;
    return ARM_DRIVER_OK;
  }
  if (state->dedicated_mode) regs->MCR = 0;
  regs->MCR =
      EIGEN_VAL2FLD(I2C_MCR_TX_FIFO_THRESHOLD, 8) |
      EIGEN_VAL2FLD(I2C_MCR_RX_FIFO_THRESHOLD, 8) |
      I2C_MCR_CONTROL_MODE_Msk |
      I2C_MCR_I2C_EN_Msk;
  state->dedicated_mode = false;
  regs->ISR = regs->ISR;
  regs->SCR =
      ((state->address << 1) & I2C_SCR_TARGET_SLAVE_ADDR_Msk) |
      (length > kKnownLengthMax
          ? I2C_SCR_BYTE_NUM_UNKNOWN_Msk
          : ((length - 1) << I2C_SCR_BYTE_NUM_Pos)) |
      I2C_SCR_START_Msk;

  uint32_t free =
      EIGEN_FLD2VAL(I2C_FSR_TX_FIFO_FREE_NUM, regs->FSR);
  while (free-- > 0 && state->count < length) {
    regs->TDR = state->tx[state->count++];
  }
  regs->IER =
      I2C_IER_TRANSFER_DONE_Msk |
      I2C_IER_ARBITRATATION_LOST_Msk |
      I2C_IER_BUS_ERROR_Msk |
      I2C_IER_RX_NACK_Msk |
      I2C_IER_TX_FIFO_UNDERRUN_Msk |
      I2C_IER_TX_FIFO_OVERFLOW_Msk |
      (length > kKnownLengthMax ? I2C_IER_DETECT_STOP_Msk : 0) |
      (state->count < length
          ? I2C_IER_TX_FIFO_EMPTY_Msk | I2C_IER_WAIT_TX_FIFO_Msk
          : 0);
  return ARM_DRIVER_OK;
}

static int32_t start_receive(int controller) {
  I2cState* state = &i2c_states[controller];
  I2C_TypeDef* regs = kI2cRegs[controller];
  uint32_t length = state->rx_len;
  if (state->hardware_busy || (regs->STR & I2C_STR_BUSY_Msk)) {
    return ARM_DRIVER_ERROR_BUSY;
  }

  state->count = 0;
  state->hardware_busy = true;
  if (state->dedicated_mode) regs->MCR = 0;
  bool unknown_length = length > kKnownLengthMax;
  regs->MCR =
      EIGEN_VAL2FLD(I2C_MCR_TX_FIFO_THRESHOLD, 8) |
      EIGEN_VAL2FLD(
          I2C_MCR_RX_FIFO_THRESHOLD, unknown_length ? 1 : 8) |
      I2C_MCR_CONTROL_MODE_Msk |
      I2C_MCR_I2C_EN_Msk;
  state->dedicated_mode = false;
  regs->ISR = regs->ISR;
  regs->IER =
      I2C_IER_TRANSFER_DONE_Msk |
      I2C_IER_ARBITRATATION_LOST_Msk |
      I2C_IER_BUS_ERROR_Msk |
      I2C_IER_RX_NACK_Msk |
      I2C_IER_RX_FIFO_OVERFLOW_Msk |
      (unknown_length ? I2C_IER_DETECT_STOP_Msk : 0) |
      I2C_IER_RX_FIFO_FULL_Msk |
      I2C_IER_WAIT_RX_FIFO_Msk;
  regs->SCR =
      ((state->address << 1) & I2C_SCR_TARGET_SLAVE_ADDR_Msk) |
      (unknown_length
          ? I2C_SCR_BYTE_NUM_UNKNOWN_Msk
          : ((length - 1) << I2C_SCR_BYTE_NUM_Pos)) |
      I2C_SCR_TARGET_RWN_Msk |
      I2C_SCR_START_Msk;
  return ARM_DRIVER_OK;
}

// The automatic/control-mode engine counts SCL phases at the full functional
// clock and honors TPR. In its bounded linear region:
//   period_ticks = 2 * SCLx + kPaceOverheadTicks
//
// The 26 MHz source (always running with the AP) covers ~49..206 kHz; the
// gate-enabled 51.2 MHz root covers intermediate fast requests. Source
// switches use the SDK LCD driver's CLOCK_clockEnable(CLK_HF51M) recipe.
// A 400 kHz request uses the fastest validated timing word on 26 MHz:
// approximately 363 kHz. Requests above 400 kHz use the same ceiling;
// requests below the floor are rejected.
static const uint32_t kPaceOverheadTicks = 20;
static const uint32_t kSrc26M = 26000000;
static const uint32_t kSrc51M = 51200000;
static const uint32_t kFastRequestHz = 400000;
// Validated divisor floors for each functional-clock source.
static const uint32_t kMinScl26 = 53;
static const uint32_t kMinScl51 = 62;
// Above this the 51.2 MHz source is selected: the fastest pace where the
// 26 MHz source keeps SCLH=SCLL >= kMinScl26. ~206 kHz.
static const uint32_t kMax26MHz =
    kSrc26M / (2 * kMinScl26 + kPaceOverheadTicks);
// The floor: SCLH=SCLL=255 at 26 MHz. Round up so the generated wire clock
// never exceeds the requested maximum, even at the lowest accepted value.
static const uint32_t kMinHz =
    (kSrc26M + 510 + kPaceOverheadTicks - 1) /
    (510 + kPaceOverheadTicks);
// Pace for bus-level operations before a device transfer makes its pace
// sticky. This is the slowest round standard value the engine can honor.
static const uint32_t kBusDefaultHz = 50000;

// Programs the controller for the requested pace: functional-clock source
// (26 vs 51.2 MHz), the driver's internal SETUP flag (gates Master*; must
// rerun after every power cycle), and the TPR SCLH/SCLL divisor.
static void ensure_setup(int controller, uint32_t hz) {
  I2cState* state = &i2c_states[controller];
  if (state->current_hz == hz) return;
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  // Keep the setup/hold/filter fields while selecting the fastest validated
  // phase divisor: 1.25 us high + 1.50 us low, approximately 363 kHz.
  bool luat_fast = hz >= kFastRequestHz;
  bool fast_src = !luat_fast && hz > kMax26MHz;
  uint32_t src = fast_src ? kSrc51M : kSrc26M;
  if (src != state->src_hz) {
    // Switch the source while the peripheral is unclocked. Gate the
    // 51.2 MHz root before selecting it.
    driver->PowerControl(ARM_POWER_OFF);
    if (fast_src) CLOCK_clockEnable(CLK_HF51M);
    if (controller == 0) {
      GPR_setClockSrc(FCLK_I2C0, fast_src ? FCLK_I2C0_SEL_51M : FCLK_I2C0_SEL_26M);
    } else {
      GPR_setClockSrc(FCLK_I2C1, fast_src ? FCLK_I2C1_SEL_51M : FCLK_I2C1_SEL_26M);
    }
    power_full(controller);
    state->src_hz = src;
  }
  driver->Control(ARM_I2C_BUS_SPEED, ARM_I2C_BUS_SPEED_STANDARD);
  I2C_TypeDef* regs = kI2cRegs[controller];
  if (luat_fast) {
    static const uint32_t kFastScl = 30;
    regs->TPR = 0x01880000
              | (kFastScl << I2C_TPR_SCLH_Pos)
              | (kFastScl << I2C_TPR_SCLL_Pos);
    state->current_hz = hz;
    return;
  }
  // Round the divisor upward: I2C frequency is an upper bound, so an
  // inexact hardware divisor must make the wire slower, never faster.
  uint32_t period = (src + hz - 1) / hz;
  uint32_t scl = period > kPaceOverheadTicks
      ? (period - kPaceOverheadTicks + 1) / 2
      : (fast_src ? kMinScl51 : kMinScl26);
  uint32_t min_scl = fast_src ? kMinScl51 : kMinScl26;
  if (scl < min_scl) scl = min_scl;
  if (scl > 255) scl = 255;
  regs->TPR = (regs->TPR & ~(I2C_TPR_SCLH_Msk | I2C_TPR_SCLL_Msk))
            | (scl << I2C_TPR_SCLH_Pos) | (scl << I2C_TPR_SCLL_Pos);
  state->current_hz = hz;
}

// Hard recovery: the CMSIS abort and bus-clear entries are empty, so reset
// the engine, FIFOs, and SETUP flag with a peripheral power cycle. Reapply
// the functional-clock source while the block is unclocked.
static void quiesce(int controller) {
  I2cState* state = &i2c_states[controller];
  // Make an IRQ that races the abort stale before power-down. In
  // particular, a late write-leg completion must not start the chained
  // read while the block is being reset.
  state->transfer_active = false;
  state->hardware_busy = false;
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  // The completion event can lead the final STOP by one bit-time. Wait for
  // the wire state machine before removing peripheral power.
  I2C_TypeDef* regs = kI2cRegs[controller];
  for (int spin = 20000; (regs->STR & I2C_STR_BUSY_Msk) && spin > 0; spin--) {}
  driver->PowerControl(ARM_POWER_OFF);
  // PowerControl(OFF) gates the clocks and clears the software status, but
  // does not reset the command engine: STR.BUSY can survive and reject every
  // later transfer. Use the same module reset as the vendor's timeout paths.
  GPR_swResetModule(&kI2cResetVectors[controller]);
  // Preserve the current source selection and pace across recovery.
  bool fast_src = state->src_hz == kSrc51M;
  if (fast_src) CLOCK_clockEnable(CLK_HF51M);
  if (controller == 0) {
    GPR_setClockSrc(FCLK_I2C0, fast_src ? FCLK_I2C0_SEL_51M : FCLK_I2C0_SEL_26M);
  } else {
    GPR_setClockSrc(FCLK_I2C1, fast_src ? FCLK_I2C1_SEL_51M : FCLK_I2C1_SEL_26M);
  }
  power_full(controller);
  state->current_hz = 0;
}

// Reads the wire level of an I2C pad: direction input, briefly mux to
// plain GPIO, sample, restore the controller mux (ALT2). The caller holds
// PadGpioLock across the complete probe/recovery sequence.
static bool wire_high(int pad) {
  int gpio_bit = pad_to_gpio(pad);
  ASSERT(gpio_bit >= 0);
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_INPUT;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
  int level = GPIO_pinRead(gpio_bit >> 4, gpio_bit & 0xf) ? 1 : 0;
  GPIO_IomuxEC618(pad, 2, 1, 1);
  return level != 0;
}

// Standard 9-clock bus clear via the pad-GPIO trick: a slave (or an
// abandoned transaction) holding SDA low releases it once it sees enough
// SCL edges to finish whatever byte it believes it is transferring, and
// the closing STOP pattern resets every state machine on the wire. The
// CMSIS ARM_I2C_BUS_CLEAR entry point is an empty stub, so this is ours.
// Open-drain semantics by direction switching (drive low = output-0,
// release = input + pull-ups), so nothing ever fights the pull-ups.
static void drive_low(int pad, int gpio_bit) {
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = 0;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
}

static void release_line(int pad, int gpio_bit) {
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_INPUT;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
}

static void bus_clear(int sda, int scl) {
  int sda_bit = pad_to_gpio(sda);
  int scl_bit = pad_to_gpio(scl);
  ASSERT(sda_bit >= 0 && scl_bit >= 0);
  release_line(sda, sda_bit);
  release_line(scl, scl_bit);
  delay_us(20);
  for (int i = 0; i < 9; i++) {        // ~25 kHz clearing clock.
    drive_low(scl, scl_bit);
    delay_us(20);
    release_line(scl, scl_bit);
    delay_us(20);
  }
  drive_low(sda, sda_bit);             // STOP: SDA low -> high with SCL high.
  delay_us(20);
  release_line(sda, sda_bit);
  delay_us(20);
  GPIO_IomuxEC618(sda, 2, 1, 1);       // Back to the controller (ALT2).
  GPIO_IomuxEC618(scl, 2, 1, 1);
}

// Releases a finished (or aborted) transfer's buffers.
static void release_transfer(I2cState* state) {
  if (state->transfer_active) {
    ASSERT(state->last_event != 0);
    ASSERT(!state->hardware_busy);
  }
  // Make any late IRQ callback stale before releasing memory it could use.
  state->transfer_active = false;
  state->hardware_busy = false;
  if (state->owns_buffers) {
    free(state->tx);
    free(state->rx);
  }
  state->owns_buffers = false;
  state->notify_toit = false;
  state->tx = null;
  state->tx_len = 0;
  state->rx = null;
  state->rx_len = 0;
  state->active_device = null;
  state->stage = I2cStage::IDLE;
}

class I2cBusResource : public EventResource {
 public:
  TAG(I2cBusResource);
  I2cBusResource(ResourceGroup* group, int controller, int sda, int scl)
    : EventResource(group, Event::none_type())
    , controller_(controller)
    , sda_(sda)
    , scl_(scl)
    , device_count_(0) {}

  ~I2cBusResource() override {
    ASSERT(device_count_ == 0);
    I2cState* state = &i2c_states[controller_];
    if (state->transfer_active) {
      quiesce(controller_);
      release_transfer(state);
    }
    if (state->initialized) {
      ARM_DRIVER_I2C* driver = kI2cDrivers[controller_];
      driver->PowerControl(ARM_POWER_OFF);
      driver->Uninitialize();
    }
    state->initialized = false;
    state->current_hz = 0;
    // Hand the pads back disconnected (this also drops the pull-ups the
    // bus may have enabled) — a container must leave the wires the way it
    // found them, even when it is killed without closing the bus.
    pad_release(sda_);
    pad_release(scl_);
    release_controller(controller_);
  }

  int controller() const { return controller_; }
  I2cState* state() const { return &i2c_states[controller_]; }
  int device_count() const { return device_count_; }

  void retain_device() { device_count_++; }

  void release_device() {
    ASSERT(device_count_ > 0);
    device_count_--;
  }

  // Whether both lines idle high. A dead bus (no pull-ups, e.g. the
  // peripheral powered off) fails every transfer; catching it up front
  // gives a clean fast error instead of timeout cascades.
  bool bus_free() const {
    return (wire_high(sda_)) && (wire_high(scl_));
  }

  // bus_free with one recovery attempt: a held-low line gets the standard
  // 9-clock bus clear (stuck slave, or a transaction the engine abandoned
  // mid-STOP) before the verdict.
  bool bus_usable() const {
    // The bus already owns its physical pads. Lock the GPIO-bit pool across
    // every temporary mux/register operation, and proceed only if neither
    // bit is owned by a GPIO pin (including a sibling physical pad).
    PadGpioLock gpio_lock(sda_, scl_);
    if (!gpio_lock.available()) return true;
    if (bus_free()) return true;
    printf("[i2c] bus stuck: sda=%d scl=%d - clearing\n",
           wire_high(sda_) ? 1 : 0, wire_high(scl_) ? 1 : 0);
    bus_clear(sda_, scl_);
    bool ok = bus_free();
    if (!ok) {
      printf("[i2c] clear failed: sda=%d scl=%d\n",
             wire_high(sda_) ? 1 : 0, wire_high(scl_) ? 1 : 0);
    }
    return ok;
  }

 private:
  int controller_;
  int sda_;
  int scl_;
  int device_count_;
};

class I2cDeviceResource : public EventResource {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus, int address,
                    uint32_t frequency)
    : EventResource(group, Event::i2c_type(bus->controller()))
    , bus_(bus)
    , address_(address)
    , frequency_(frequency) {
    bus_->retain_device();
  }

  ~I2cDeviceResource() override {
    I2cState* state = &i2c_states[controller()];
    if (state->transfer_active && state->active_device == this) {
      quiesce(controller());
      release_transfer(state);
    }
    bus_->release_device();
  }

  I2cBusResource* bus() const { return bus_; }
  int controller() const { return bus_->controller(); }
  int address() const { return address_; }
  uint32_t frequency() const { return frequency_; }

 private:
  I2cBusResource* bus_;
  int address_;
  uint32_t frequency_;
};

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    // Only the CURRENT transfer's completion may set the done bit: a
    // dispatch from an earlier (aborted or spin-consumed) transfer
    // arriving late must not wake the next transfer's wait.
    auto device = static_cast<I2cDeviceResource*>(r);
    I2cState* i2c_state = &i2c_states[device->controller()];
    uint16_t dispatch_seq = (data >> 16) & 0xffff;
    if (device != i2c_state->active_device ||
        dispatch_seq != i2c_state->seq) return state;
    return state | 1;  // Transfer-done bit, matching lib/i2c.toit.
  }
};

struct PendingI2cBuffers {
  uint8_t* tx;
  uint8_t* rx;
  bool handed_to_state;

  PendingI2cBuffers() : tx(null), rx(null), handed_to_state(false) {}

  ~PendingI2cBuffers() {
    if (!handed_to_state) {
      free(tx);
      free(rx);
    }
  }
};

// Maps the recorded completion event to the primitive result code
// (0 = clean; the library turns nonzero into HARDWARE_ERROR).
static I2cResult event_to_result(uint32_t event) {
  if (event & ARM_I2C_EVENT_ADDRESS_NACK) return I2cResult::ADDRESS_NACK;
  if (event & ARM_I2C_EVENT_BUS_ERROR) return I2cResult::BUS_ERROR;
  if (event & ARM_I2C_EVENT_ARBITRATION_LOST) return I2cResult::ARBITRATION_LOST;
  if (event & ARM_I2C_EVENT_TRANSFER_INCOMPLETE) return I2cResult::INCOMPLETE;
  if (!(event & ARM_I2C_EVENT_TRANSFER_DONE)) return I2cResult::INCOMPLETE;
  return I2cResult::OK;
}

// Starts the hardware legs for a transfer whose state is already set up.
// Returns false when the driver rejected the start (state released).
static bool start_legs(I2cState* state, int controller) {
  int32_t rc;
  if (state->tx != null && state->rx != null) {
    state->stage = I2cStage::WRITE_PENDING_READ;
    rc = start_transmit(controller);
  } else if (state->tx != null) {
    state->stage = I2cStage::SINGLE;
    rc = start_transmit(controller);
  } else {
    state->stage = I2cStage::SINGLE;
    rc = start_receive(controller);
  }
  if (rc != ARM_DRIVER_OK) {
    quiesce(controller);
    release_transfer(state);
    return false;
  }
  return true;
}

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Ec618EventSource* event_source = Ec618EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  I2cResourceGroup* group = _new I2cResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int controller = pads_to_controller(sda, scl);
  if (controller < 0) FAIL(INVALID_ARGUMENT);
  if (!ensure_i2c_chain_task()) FAIL(MALLOC_FAILED);
  if (!reserve_controller(controller)) FAIL(ALREADY_IN_USE);

  I2cBusResource* bus = _new I2cBusResource(group, controller, sda, scl);
  if (bus == null) {
    release_controller(controller);
    FAIL(MALLOC_FAILED);
  }
  bool handed_to_proxy = false;
  Defer delete_bus {
    [&] {
      if (!handed_to_proxy) delete bus;
    }
  };

  I2cState* state = &i2c_states[controller];

  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  if (state->initialized) {
    driver->Uninitialize();
    state->initialized = false;
  }
  if (driver->Initialize(kI2cCallbacks[controller]) != ARM_DRIVER_OK) {
    FAIL(HARDWARE_ERROR);
  }
  state->initialized = true;
  // Pin the functional clock to the always-running 26 MHz source BEFORE
  // the block gets clocked (PowerControl FULL): an unpinned selection can
  // float to the 51.2 MHz root while that root is gated and stall transfers.
  // ensure_setup elevates to the 51.2 MHz source when a device's pace
  // needs it.
  GPR_setClockSrc(controller == 0 ? FCLK_I2C0 : FCLK_I2C1,
                  controller == 0 ? FCLK_I2C0_SEL_26M : FCLK_I2C1_SEL_26M);
  if (power_full(controller) != ARM_DRIVER_OK) {
    FAIL(HARDWARE_ERROR);
  }
  state->src_hz = kSrc26M;

  // Initialize() muxed the driver's RTE pins; release them when the user
  // chose a different routing, then route the chosen pads (ALT2, input
  // buffer on).
  if (kRteSda[controller] != sda) pad_release(kRteSda[controller]);
  if (kRteScl[controller] != scl) pad_release(kRteScl[controller]);
  GPIO_IomuxEC618(sda, 2, 1, 1);
  GPIO_IomuxEC618(scl, 2, 1, 1);

  if (pullup) {
    GPIO_PullConfig(sda, 1, 1);
    GPIO_PullConfig(scl, 1, 1);
  }

  state->current_hz = 0;
  state->bus_hz = kBusDefaultHz;
  ensure_setup(controller, kBusDefaultHz);

  group->register_resource(bus);
  proxy->set_external_address(bus);
  handed_to_proxy = true;
  return proxy;
}

PRIMITIVE(bus_close) {
  ARGS(I2cBusResource, bus);
  if (bus->device_count() != 0) FAIL(ALREADY_IN_USE);
  bus->resource_group()->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(bus_probe) {
  ARGS(I2cBusResource, bus, uint16, address, int, timeout_ms);
  I2cState* state = bus->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);
  if (address > 0x7f) FAIL(INVALID_ARGUMENT);
  if (!bus->bus_usable()) return BOOL(false);
  // SMBus receive-byte probe: a present device ACKs its address and one
  // byte transfers; an absent one NACKs.
  uint8_t scratch;
  int controller = bus->controller();
  ensure_setup(controller, state->bus_hz != 0 ? state->bus_hz : kBusDefaultHz);
  state->address = address;
  state->active_device = null;
  state->seq++;
  state->notify_toit = false;
  state->owns_buffers = false;
  state->tx = null;
  state->tx_len = 0;
  state->rx = &scratch;
  state->rx_len = 1;
  state->last_event = 0;
  state->transfer_active = true;
  if (!start_legs(state, controller)) return BOOL(false);

  uint16_t clamped_timeout_ms =
      timeout_ms < 1 ? 1 : (timeout_ms > 1000 ? 1000 : timeout_ms);
  int64 deadline_us =
      OS::get_monotonic_time() +
      static_cast<int64>(clamped_timeout_ms) * 1000 * 3;
  while (state->last_event == 0) {
    if (OS::get_monotonic_time() > deadline_us) {
      quiesce(controller);
      release_transfer(state);
      return BOOL(false);
    }
  }
  I2cResult result = event_to_result(state->last_event);
  if (result != I2cResult::OK) quiesce(controller);
  release_transfer(state);
  return BOOL(result == I2cResult::OK);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, bus);
  I2cState* state = bus->state();
  bool had_transfer = state->transfer_active;
  quiesce(bus->controller());
  if (had_transfer) release_transfer(state);
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  // Kept in the common primitive signature for synchronous platforms. EC618
  // transfers are asynchronous and are canceled by the caller.
  USE(timeout_us);
  // 10-bit mode exists in the hardware but is untested; reject until
  // needed.
  if (address_bit_size != 7) FAIL(INVALID_ARGUMENT);
  if (address > 0x7f) FAIL(INVALID_ARGUMENT);
  // The controller always checks ACKs. Do not silently promise the caller
  // the opposite behavior.
  if (disable_ack_check) FAIL(INVALID_ARGUMENT);
  if (frequency_hz == 0) FAIL(INVALID_ARGUMENT);
  // Honorable requests span ~49 kHz upward (see ensure_setup). A nominal
  // A 400 kHz request selects the validated ~363 kHz wire ceiling.
  // Requests above the ceiling run AT the ceiling (slower than asked is
  // I2C-legal), but a request BELOW the floor cannot be honored — a
  // deliberately slow bus may be a hard requirement, so reject instead
  // of silently running faster.
  if (frequency_hz < kMinHz) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cDeviceResource* device = _new I2cDeviceResource(
      bus->resource_group(), bus, address, frequency_hz);
  if (device == null) FAIL(MALLOC_FAILED);

  bus->resource_group()->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, device);
  device->resource_group()->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

// EC618 always starts transfers asynchronously. These primitives remain in
// the common module ABI for platforms whose transfer_start returns false, but
// the EC618 library path cannot reach them.

PRIMITIVE(device_write) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(device_read) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(device_write_read) {
  FAIL(UNIMPLEMENTED);
}

// --- Asynchronous transfers --------------------------------------------------
//
// transfer_start copies the Toit buffers into driver-owned memory, kicks
// off the IRQ-driven legs and returns `true` immediately; the completion
// callback raises the resource state, the library waits for it without
// blocking the VM, and transfer_finish collects the result.

PRIMITIVE(device_transfer_start) {
  ARGS(I2cDeviceResource, device, Blob, tx, int, rx_length);
  if (rx_length < 0) FAIL(OUT_OF_RANGE);
  if (tx.length() == 0 && rx_length == 0) FAIL(INVALID_ARGUMENT);

  I2cState* state = device->bus()->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);

  PendingI2cBuffers buffers;
  if (tx.length() > 0) {
    buffers.tx = unvoid_cast<uint8_t*>(malloc(tx.length()));
    if (buffers.tx == null) FAIL(MALLOC_FAILED);
    memcpy(buffers.tx, tx.address(), tx.length());
  }
  if (rx_length > 0) {
    buffers.rx = unvoid_cast<uint8_t*>(malloc(rx_length));
    if (buffers.rx == null) FAIL(MALLOC_FAILED);
  }

  // All fallible allocation is complete before bus recovery, clock changes,
  // or an address phase can touch the wire.
  if (!device->bus()->bus_usable()) FAIL(HARDWARE_ERROR);
  state->bus_hz = device->frequency();
  ensure_setup(device->controller(), device->frequency());

  state->address = device->address();
  state->active_device = device;
  state->seq++;
  state->notify_toit = true;
  state->owns_buffers = true;
  state->tx = buffers.tx;
  state->tx_len = tx.length();
  state->rx = buffers.rx;
  state->rx_len = rx_length;
  state->last_event = 0;
  state->transfer_active = true;
  buffers.handed_to_state = true;

  if (!start_legs(state, device->controller())) FAIL(HARDWARE_ERROR);
  return process->true_object();
}

PRIMITIVE(device_transfer_finish) {
  ARGS(I2cDeviceResource, device, MutableBlob, rx_out);
  I2cState* state = device->bus()->state();
  if (!state->transfer_active || state->active_device != device) {
    FAIL(INVALID_ARGUMENT);
  }

  uint32_t event = state->last_event;
  if (event == 0) {
    // The caller left its wait before completion (for example, an outer
    // with-timeout canceled it). Stop the engine before releasing buffers.
    quiesce(device->controller());
    release_transfer(state);
    return Primitive::integer(static_cast<int>(I2cResult::CANCELED), process);
  }
  I2cResult result = event_to_result(event);
  if (result == I2cResult::OK && state->rx != null) {
    uint32_t n = state->rx_len;
    if (n > static_cast<uint32_t>(rx_out.length())) n = rx_out.length();
    memcpy(rx_out.address(), state->rx, n);
  }
  if (result != I2cResult::OK) {
    quiesce(device->controller());
  }
  release_transfer(state);
  return Primitive::integer(static_cast<int>(result), process);
}

}  // namespace toit

#endif  // TOIT_EC618
