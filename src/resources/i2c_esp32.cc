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
#include <cmath>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../utils.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

namespace toit {

const int kI2CTransactionTimeout = 10;
const i2c_port_t kInvalidPort = i2c_port_t(-1);

ResourcePool<i2c_port_t, kInvalidPort> i2c_ports(
   I2C_NUM_0
#if SOC_I2C_NUM >= 2
 , I2C_NUM_1
#endif
);

class I2CResourceGroup : public ResourceGroup {
 public:
  TAG(I2CResourceGroup);
  I2CResourceGroup(Process* process, i2c_port_t port)
    : ResourceGroup(process)
    , port_(port) { }

  ~I2CResourceGroup() {
    SystemEventSource::instance()->run([&]() -> void {
      FATAL_IF_NOT_ESP_OK(i2c_driver_delete(port_));
    });
    i2c_ports.put(port_);
  }

  i2c_port_t port() const { return port_; }

 private:
  i2c_port_t port_;
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
#ifdef CONFIG_IDF_TARGET_ESP32S3
    i2c_set_timeout(port, (int)(log2(I2C_APB_CLK_FREQ / 1000.0 * kI2CTransactionTimeout)));
#else
    i2c_set_timeout(port, I2C_APB_CLK_FREQ / 1000 * kI2CTransactionTimeout);
#endif
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

static Object* write_i2c(Process* process, I2CResourceGroup* i2c, int i2c_address, const uint8* address, int address_length, Blob buffer) {

  const uint8* data = buffer.address();
  int length = buffer.length();
  if (!esp_ptr_internal(data)) {
    // Copy buffer to malloc heap, if the buffer is not in memory.
    uint8* copy = unvoid_cast<uint8*>(malloc(length));
    if (copy == null) MALLOC_FAILED;
    memcpy(copy, data, length);
    data = copy;
  }
  Defer release_copy { [&]() { if (data != buffer.address()) free(const_cast<uint8*>(data)); } };

  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  if (cmd == null) MALLOC_FAILED;
  Defer release_cmd_handle { [&]() { i2c_cmd_link_delete(cmd); } };

  // NOTE:
  // 'i2c_master_X' functions allocate data, but return `ESP_FAIL` if that allocation
  // fails. There is no way to differentiate the kind of error.

  // Initiate the sequence by issuing a `start`. That will notify slaves to
  // listen (if possible) and promote self to current master, in case of
  // multi-master setup.
  if (i2c_master_start(cmd) != ESP_OK) MALLOC_FAILED;

  // Write the i2c address with the write-bit. The device must ack.
  if (i2c_master_write_byte(cmd, (i2c_address << 1) | I2C_MASTER_WRITE, true) != ESP_OK) MALLOC_FAILED;

  // First we notify the slave about the register/address we will use.
  if (address != null) {
    // Write the register address. Each byte must be acked.
    if (address_length > 1 && esp_ptr_internal(address)) {
      if (i2c_master_write(cmd, address, address_length, true) != ESP_OK) MALLOC_FAILED;
    } else {
      for (int i = 0; i < address_length; i++) {
        if (i2c_master_write_byte(cmd, address[i], true) != ESP_OK) MALLOC_FAILED;
      }
    }
  }

  // Queue up all the bytes to be written. Each byte must be acked.
  if (buffer.length() > 0) {
    if (i2c_master_write(cmd, data, length, true) != ESP_OK) MALLOC_FAILED;
  }

  // Finally issue the stop. That will allow other masters to communicate.
  if (i2c_master_stop(cmd) != ESP_OK) MALLOC_FAILED;

  // Ship the built command.
  esp_err_t err = i2c_master_cmd_begin(i2c->port(), cmd, 1000 / portTICK_RATE_MS);
  if (err != ESP_OK) return Smi::from(err);

  return process->program()->null_object();
}

static Object* read_i2c(Process* process, I2CResourceGroup* i2c, int i2c_address, const uint8* address, int address_length, int length) {
  ByteArray* array = process->allocate_byte_array(length);
  if (array == null) ALLOCATION_FAILED;
  uint8* data = ByteArray::Bytes(array).address();

  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  if (cmd == null) MALLOC_FAILED;
  Defer release_cmd_handle { [&]() { i2c_cmd_link_delete(cmd); } };

  // NOTE:
  // 'i2c_master_X' functions allocate data, but return `ESP_FAIL` if that allocation
  // fails. There is no way to differentiate the kind of error.

  // Initiate the sequence by issuing a `start`. That will notify slaves to
  // listen (if possible) and promote self to current master, in case of
  // multi-master setup.
  if (i2c_master_start(cmd) != ESP_OK) MALLOC_FAILED;

  if (address != null) {
    // First we notify the slave about the register/address we will use.

    // Write the i2c address with the write-bit. The device must ack.
    if (i2c_master_write_byte(cmd, (i2c_address << 1) | I2C_MASTER_WRITE, true) != ESP_OK) MALLOC_FAILED;

    // Write the register address. Each byte must be acked.
    if (address_length > 1 && esp_ptr_internal(address)) {
      if (i2c_master_write(cmd, address, address_length, true) != ESP_OK) MALLOC_FAILED;
    } else {
      for (int i = 0; i < address_length; i++) {
        if (i2c_master_write_byte(cmd, address[i], true) != ESP_OK) MALLOC_FAILED;
      }
    }

    // Prepare the slave for the next command.
    if (i2c_master_start(cmd) != ESP_OK) MALLOC_FAILED;
  }

  // Write the address with the read-bit set. The slave must ack.
  if (i2c_master_write_byte(cmd, (i2c_address << 1) | I2C_MASTER_READ, true) != ESP_OK) MALLOC_FAILED;

  // Queue up all the bytes that must be read.
  if (length > 0) {
    if (i2c_master_read(cmd, data, length, I2C_MASTER_LAST_NACK) != ESP_OK) MALLOC_FAILED;
  }

  // Finally issue the stop. That will allow other masters to communicate.
  if (i2c_master_stop(cmd) != ESP_OK) MALLOC_FAILED;

  // Ship the built command.
  esp_err_t err = i2c_master_cmd_begin(i2c->port(), cmd, 1000 / portTICK_RATE_MS);
  // TODO(florian): we could return the error code here: Smi::from(err).
  // We would need to type-dispatch on the Toit side to know whether it was an error or not.
  if (err != ESP_OK) return null;

  return array;
}

PRIMITIVE(write) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, Blob, buffer);

  return write_i2c(process, i2c, i2c_address, null, 0, buffer);
}

PRIMITIVE(write_reg) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, int, reg, Blob, buffer);

  if (!(0 <= reg && reg < 256)) INVALID_ARGUMENT;

  uint8 reg_address[1] = { static_cast<uint8>(reg) };
  return write_i2c(process, i2c, i2c_address, reg_address, 1, buffer);
}

PRIMITIVE(write_address) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, Blob, address, Blob, buffer);

  return write_i2c(process, i2c, i2c_address, address.address(), address.length(), buffer);
}

PRIMITIVE(read) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, int, length);

  return read_i2c(process, i2c, i2c_address, null, 0, length);
}


PRIMITIVE(read_reg) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, int, reg, int, length)

  if (!(0 <= reg && reg < 256)) INVALID_ARGUMENT;

  uint8 address[1] = { static_cast<uint8>(reg) };
  return read_i2c(process, i2c, i2c_address, address, 1, length);
}

PRIMITIVE(read_address) {
  ARGS(I2CResourceGroup, i2c, int, i2c_address, Blob, address, int, length);

  return read_i2c(process, i2c, i2c_address, address.address(), address.length(), length);
}

} // namespace toit

#endif // TOIT_FREERTOS
