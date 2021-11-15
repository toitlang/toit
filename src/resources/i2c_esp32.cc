// Copyright (C) 2018 Toitware ApS.
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

#include <driver/i2c.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

namespace toit {

const int kI2CTransactionTimeout = 10;
const i2c_port_t kInvalidPort = i2c_port_t(-1);

ResourcePool<i2c_port_t, kInvalidPort> i2c_ports(
  I2C_NUM_0,
  I2C_NUM_1
);

class I2CResourceGroup : public ResourceGroup {
 public:
  TAG(I2CResourceGroup);
  I2CResourceGroup(Process* process, i2c_port_t port)
    : ResourceGroup(process)
    , _port(port) { }

  ~I2CResourceGroup() {
    SystemEventSource::instance()->run([&]() -> void {
      FATAL_IF_NOT_ESP_OK(i2c_driver_delete(_port));
    });
    i2c_ports.put(_port);
  }

  i2c_port_t port() const { return _port; }

 private:
  i2c_port_t _port;
};

MODULE_IMPLEMENTATION(i2c, MODULE_I2C);

PRIMITIVE(init) {
  ARGS(int, frequency, int, sda, int, scl);

  i2c_port_t port = i2c_ports.any();
  if (port == kInvalidPort) OUT_OF_RANGE;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    i2c_ports.put(port);
    ALLOCATION_FAILED;
  }

  i2c_config_t conf;
  memset(&conf, 0, sizeof(conf));
  conf.mode = I2C_MODE_MASTER;
  conf.sda_io_num = (gpio_num_t)sda;
  conf.sda_pullup_en = GPIO_PULLUP_DISABLE;
  conf.scl_io_num = (gpio_num_t)scl;
  conf.scl_pullup_en = GPIO_PULLUP_DISABLE;
  conf.master.clk_speed = frequency;
  int result = i2c_param_config(port, &conf);
  if (result != ESP_OK) INVALID_ARGUMENT;
  result = ESP_FAIL;
  SystemEventSource::instance()->run([&]() -> void {
    result = i2c_driver_install(port, I2C_MODE_MASTER, 0, 0, 0);
    i2c_set_timeout(port, I2C_APB_CLK_FREQ / 1000 * kI2CTransactionTimeout);
  });
  if (result != ESP_OK) {
    i2c_ports.put(port);
    return Primitive::os_error(result, process);
  }

  I2CResourceGroup* i2c = _new I2CResourceGroup(process, port);
  if (!i2c) {
    SystemEventSource::instance()->run([&]() -> void {
      i2c_driver_delete(port);
    });
    i2c_ports.put(port);
    MALLOC_FAILED;
  }

  proxy->set_external_address(i2c);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(I2CResourceGroup, i2c);
  i2c->tear_down();
  i2c_proxy->clear_external_address();
  return process->program()->null_object();
}

static bool build_command(i2c_cmd_handle_t cmd, uint8 address, int reg, bool write, uint8* data, size_t length) {
  // Initiate the sequence by issuing a `start`. That will notify slaves to
  // listen (if possible) and promote self to current master, in case of
  // multi-master setup.
  if (i2c_master_start(cmd) != ESP_OK) return false;

  if (reg != -1) {
    // First we notify the slave about the register we will use.

    // First write the address. That will notify our targeted slave to
    // read. It's an error if the slave doesn't ack.
    if (i2c_master_write_byte(cmd, (address << 1) | I2C_MASTER_WRITE, true) != ESP_OK) {
      return false;
    }

    // Now write the register we want to address. Likewise, it's an error
    // if the slave doesn't pick up all the bytes.
    if (length > 0) {
      if (i2c_master_write_byte(cmd, (uint8)reg, true) != ESP_OK) {
        return false;
      }
    }

    // The slave now knows the register we will use. Send a start to let
    // them, know about the next command.
    if (i2c_master_start(cmd) != ESP_OK) return false;
  }

  if (write) {
    // First write the address. That will notify our targeted slave to
    // read. It's an error if the slave doesn't ack.
    if (i2c_master_write_byte(cmd, (address << 1) | I2C_MASTER_WRITE, true) != ESP_OK) {
      return false;
    }

    // Now queue up all the bytes to be written. Likewise, it's an error
    // if the slave doesn't pick up all the bytes.
    if (length > 0) {
      if (i2c_master_write(cmd, data, length, true) != ESP_OK) {
        return false;
      }
    }
  } else {
    // First write the address. That will notify our targeted slave to
    // write. It's an error if the slave doesn't ack.
    if (i2c_master_write_byte(cmd, (address << 1) | I2C_MASTER_READ, true) != ESP_OK) {
      return false;
    }

    // Now queue up all the bytes to be read. Likewise, it's an error
    // if the slave doesn't pick up all the bytes.
    if (length > 0) {
      if (i2c_master_read(cmd, data, length, I2C_MASTER_LAST_NACK) != ESP_OK) {
        return false;
      }
    }
  }

  // Finally issue the stop. That will allow other masters to communicate.
  if (i2c_master_stop(cmd) != ESP_OK) return false;

  return true;
}

PRIMITIVE(write) {
  ARGS(I2CResourceGroup, i2c, int, address, Blob, buffer);

  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  if (cmd == null) MALLOC_FAILED;

  // TODO(florian): we are using `const_cast` here, as the `build_command` is
  // written for both reads and writes. The buffer here is only read, so the
  // cast is safe, but it would be better if we could avoid it.
  uint8* data = const_cast<uint8*>(buffer.address());

  // Copy buffer to stack, if the buffer is not in memory.
  uint8 copy[buffer.length()];
  if (!esp_ptr_internal(data)) {
    memmove(copy, data, buffer.length());
    data = copy;
  }

  if (!build_command(cmd, address, -1, true, data, buffer.length())) {
    i2c_cmd_link_delete(cmd);
    MALLOC_FAILED;
  }

  esp_err_t err = i2c_master_cmd_begin(i2c->port(), cmd, 1000 / portTICK_RATE_MS);
  i2c_cmd_link_delete(cmd);
  if (err != ESP_OK) return Smi::from(err);

  return process->program()->null_object();
}

PRIMITIVE(read) {
  ARGS(I2CResourceGroup, i2c, int, address, int, length);

  Error* error = null;
  ByteArray* array = process->allocate_byte_array(length, &error);
  if (array == null) return error;

  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  if (cmd == null) MALLOC_FAILED;

  if (!build_command(cmd, address, -1, false, ByteArray::Bytes(array).address(), length)) {
    i2c_cmd_link_delete(cmd);
    MALLOC_FAILED;
  }

  esp_err_t err = i2c_master_cmd_begin(i2c->port(), cmd, 1000 / portTICK_RATE_MS);
  i2c_cmd_link_delete(cmd);
  if (err != ESP_OK) return process->program()->null_object();

  return array;
}


PRIMITIVE(read_reg) {
  ARGS(I2CResourceGroup, i2c, int, address, int, reg, int, length)

  if (!(0 <= reg && reg < 256)) INVALID_ARGUMENT;

  Error* error = null;
  ByteArray* array = process->allocate_byte_array(length, &error);
  if (array == null) return error;

  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  if (cmd == null) MALLOC_FAILED;

  if (!build_command(cmd, address, reg, false, ByteArray::Bytes(array).address(), length)) {
    i2c_cmd_link_delete(cmd);
    MALLOC_FAILED;
  }

  esp_err_t err = i2c_master_cmd_begin(i2c->port(), cmd, 1000 / portTICK_RATE_MS);
  i2c_cmd_link_delete(cmd);
  if (err != ESP_OK) return process->program()->null_object();

  return array;
}


} // namespace toit

#endif // TOIT_FREERTOS
