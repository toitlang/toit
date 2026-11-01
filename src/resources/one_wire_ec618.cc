// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the top level directory.

#include "../top.h"

#ifdef TOIT_EC618

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource_pool.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "clock.h"
  #include "driver_gpio.h"
  #include "ec618.h"
  #include "ic.h"
  #include "slpman.h"
}

namespace toit {

// The controller provides standard-speed bit/byte slots. The package owns
// ROM search, CRC, serialization and operation deadlines. No vendor busy-wait
// routines are used: each operation ends with an interrupt, or is aborted by
// the package's deadline/cancellation cleanup.
static int pad_mux(int pad) {
  switch (pad) {
    case 19: return 3;
    case 17: case 22: case 48: return 4;
    default: return -1;
  }
}

static ResourcePool<int, -1> controllers(0);
static uint32_t next_generation = 0;
static uint8_t sleep_handle = 0xff;

class OneWireResource;
static OneWireResource* current = null;
static void one_wire_irq();

class OneWireResource : public EventResource {
 public:
  TAG(OneWireResource);
  OneWireResource(ResourceGroup* group, int pad)
    : EventResource(group, Event::one_wire_type()), pad_(pad) {}

  ~OneWireResource() override {
    abort();
    current = null;
    OW->ECR = 0;
    GPR_clockDisable(PCLK_ONEW);
    slpManPlatVoteEnableSleep(sleep_handle, SLP_SLP1_STATE);
    // Release the PAD before powering off its AON rail or releasing the
    // controller for another container.
    pads_.release();
    if (pad_is_aon(pad_)) pad_aon_power_release();
    controllers.put(0);
  }

  void adopt_pad(const PadReserver& pads) { pads_.adopt(pads); }

  void initialize(bool pullup) {
    if (pad_is_aon(pad_)) pad_aon_power_acquire();
    slpManPlatVoteDisableSleep(sleep_handle, SLP_SLP1_STATE);
    GPR_clockEnable(PCLK_ONEW);
    GPR_swReset(RST_PCLK_ONEW);
    OW->IER = 0;
    OW->IIR = OW_IIR_INT_CLR_Msk;
    OW->IOR = 0;  // Hardware owns the open-drain line.
    OW->DFR = 0;  // LSB first, non-inverted.
    // Keep the reset clock divider and standard-speed timing, as in the
    // vendor's owInit/owSetMode(STANDARD). GPR_getClockFreq does not report
    // this peripheral's clock (it returns zero even while enabled).
    OW->ECR = OW_ECR_ENABLE_Msk | OW_ECR_CLK_EN_Msk;
    GPIO_IomuxEC618(pad_, pad_mux(pad_), 0, 1);
    GPIO_PullConfig(pad_, pullup ? 1 : 0, pullup ? 1 : 0);
    current = this;
    XIC_SetVector(PXIC0_ONEW_IRQn, one_wire_irq);
    XIC_ClearPendingIRQ(PXIC0_ONEW_IRQn);
  }

  bool active() const { return active_; }
  bool done() const { return done_; }
  uint32_t generation() const { return generation_; }
  uint32_t result() const { return result_; }

  // Called with the controller IRQ disabled. Commands are never queued: an
  // unfinished operation must be collected or aborted before the next one.
  void start(int operation, int value, int count) {
    operation_ = operation;
    value_ = value;
    count_ = count;
    completed_ = 0;
    result_ = 0;
    generation_ = ++next_generation;
    active_ = true;
    done_ = false;
    issue();
    XIC_EnableIRQ(PXIC0_ONEW_IRQn);
  }

  void abort() {
    XIC_DisableIRQ(PXIC0_ONEW_IRQn);
    OW->IER = 0;
    OW->OCR = OW_OCR_CMD_FLUSH_Msk;
    OW->IIR = OW_IIR_INT_CLR_Msk;
    XIC_ClearPendingIRQ(PXIC0_ONEW_IRQn);
    active_ = false;
    done_ = false;
  }

  void interrupt() {
    uint32_t status = OW->IIR;
    // RESET is the completion interrupt, including when no device answers.
    // RESET_PD can report presence separately; retain it until completion.
    if (active_ && !done_ && operation_ == 0) {
      result_ |= (status & OW_IIR_RESET_PD_RES_Msk) != 0;
    }
    uint32_t expected = operation_ == 0 ? OW_IIR_INT_RESET_Msk
        : operation_ == 1 ? OW_IIR_INT_WRITE_Msk : OW_IIR_INT_READ_Msk;
    if (!active_ || done_ || !(status & expected)) {
      OW->IIR = OW_IIR_INT_CLR_Msk;
      return;
    }
    if (operation_ == 2) {
      result_ |= (OW->RBR & (count_ == 8 ? 0xff : 1)) << completed_;
    }
    OW->IER = 0;
    OW->OCR = OW_OCR_CMD_FLUSH_Msk;
    OW->IIR = OW_IIR_INT_CLR_Msk;
    completed_ += count_ == 8 ? 8 : 1;
    if (operation_ != 0 && completed_ < count_) {
      issue();
      return;
    }
    done_ = true;
    Ec618EventSource::send_event_from_isr(Event::one_wire_type(), generation_);
  }

 private:
  void issue() {
    OW->IIR = OW_IIR_INT_CLR_Msk;
    OW->DFR = count_ == 8 ? OW_DFR_MODE_BYTE_Msk : 0;
    if (operation_ == 0) {
      OW->IER = OW_IER_INTEN_RESET_Msk | OW_IER_INTEN_RESET_PD_Msk;
      OW->OCR = OW_OCR_CMD_RESET_Msk;
    } else if (operation_ == 1) {
      OW->TBR = (value_ >> completed_) & (count_ == 8 ? 0xff : 1);
      OW->IER = OW_IER_INTEN_WRITE_Msk;
      OW->OCR = OW_OCR_CMD_WRITE_Msk;
    } else {
      OW->IER = OW_IER_INTEN_READ_Msk;
      OW->OCR = OW_OCR_CMD_READ_Msk;
    }
  }

  int pad_;
  Pads pads_;
  volatile bool active_ = false;
  volatile bool done_ = false;
  uint32_t generation_ = 0;
  volatile uint32_t result_ = 0;
  int operation_ = 0;
  int value_ = 0;
  int count_ = 0;
  int completed_ = 0;
};

static void one_wire_irq() {
  if (current != null) current->interrupt();
}

class OneWireResourceGroup : public ResourceGroup {
 public:
  TAG(OneWireResourceGroup);
  OneWireResourceGroup(Process* process, EventSource* source)
    : ResourceGroup(process, source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    auto bus = static_cast<OneWireResource*>(r);
    // Reject completions left in the shared event queue by an aborted
    // operation or a previously closed instance of the controller.
    if (!bus->active() || !bus->done() ||
        static_cast<uint32_t>(data) != bus->generation()) return state;
    return state | 1;
  }
};

MODULE_IMPLEMENTATION(one_wire, MODULE_ONE_WIRE)

PRIMITIVE(capabilities) {
  ARGS(int, pad);
  // Bit 0: standard-speed controller. Strong pull-up is not yet supported.
  return Smi::from(pad_mux(pad) < 0 ? 0 : 1);
}

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  auto source = Ec618EventSource::instance();
  if (source == null) FAIL(ALREADY_CLOSED);
  auto group = _new OneWireResourceGroup(process, source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(OneWireResourceGroup, group, int, pad, bool, pullup);
  if (pad_mux(pad) < 0) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  if (sleep_handle == 0xff) {
    slpManApplyPlatVoteHandle("TOITONEW", &sleep_handle);
    if (sleep_handle == 0xff) FAIL(MALLOC_FAILED);
  }
  PadReserver pads;
  if (!pads.take(pad)) FAIL(ALREADY_IN_USE);
  if (!controllers.take(0)) FAIL(ALREADY_IN_USE);
  auto bus = _new OneWireResource(group, pad);
  if (bus == null) {
    controllers.put(0);
    FAIL(MALLOC_FAILED);
  }
  bus->adopt_pad(pads);
  pads.keep();
  bus->initialize(pullup);
  group->register_resource(bus);
  proxy->set_external_address(bus);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(OneWireResourceGroup, group, OneWireResource, bus);
  if (bus->resource_group() != group) FAIL(INVALID_ARGUMENT);
  group->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(start) {
  ARGS(OneWireResource, bus, int, operation, int, value, int, count);
  if (operation < 0 || operation > 2 ||
      (operation == 0 ? count != 0 : count < 1 || count > 8) ||
      value < 0 || value > 255) FAIL(INVALID_ARGUMENT);
  if (bus->active()) FAIL(ALREADY_IN_USE);
  XIC_DisableIRQ(PXIC0_ONEW_IRQn);
  bus->start(operation, value, count);
  return process->null_object();
}

PRIMITIVE(finish) {
  ARGS(OneWireResource, bus);
  if (!bus->active() || !bus->done()) FAIL(INVALID_STATE);
  uint32_t result = bus->result();
  bus->abort();
  return Smi::from(result);
}

PRIMITIVE(abort) {
  ARGS(OneWireResource, bus);
  bus->abort();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
