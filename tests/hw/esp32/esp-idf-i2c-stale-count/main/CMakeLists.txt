# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

idf_component_register(
  SRCS "i2c_stale_count_main.c"
  INCLUDE_DIRS "."
  PRIV_INCLUDE_DIRS
    "${IDF_PATH}/components/esp_driver_i2c"
  REQUIRES driver esp_driver_gpio esp_driver_i2c esp_hw_support
)

target_compile_definitions(${COMPONENT_LIB} PRIVATE I2C_STALE_COUNT_TEST_ONLY=1)
