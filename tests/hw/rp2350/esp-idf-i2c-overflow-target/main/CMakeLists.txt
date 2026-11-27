# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

idf_component_register(
  SRCS "i2c_overflow_target_main.c"
  INCLUDE_DIRS "."
  REQUIRES driver esp_driver_i2c esp_hw_support
)

target_compile_definitions(${COMPONENT_LIB} PRIVATE I2C_OVERFLOW_TARGET_TEST_ONLY=1)
