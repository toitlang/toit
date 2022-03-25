// Copyright (C) 2022 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include "driver/rmt.h"
#include "driver/gpio.h"

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"


namespace toit {

MODULE_IMPLEMENTATION(one_wire, MODULE_OW);

PRIMITIVE(config_pin) {
  ARGS(int, pin, int, tx);

  if (pin < 32) {
      GPIO.enable_w1ts = (0x1 << pin);
  } else {
      GPIO.enable1_w1ts.data = (0x1 << (pin - 32));
  }

  rmt_set_pin(static_cast<rmt_channel_t>(tx), RMT_MODE_TX, static_cast<gpio_num_t>(pin));

  PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);

  GPIO.pin[pin].pad_driver = 1;

  return process->program()->null_object();
}

}  // namespace toit

#endif
