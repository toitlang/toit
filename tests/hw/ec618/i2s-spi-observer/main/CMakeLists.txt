# Copyright (C) 2026 Toit contributors.
idf_component_register(SRCS "observer.c" INCLUDE_DIRS "."
  REQUIRES esp_driver_spi esp_driver_gpio esp_driver_uart esp_driver_i2s esp_driver_pcnt esp_timer vfs)
