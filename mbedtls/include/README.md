# Toit configuration for mbedtls

This directory contains the configuration for building mbedtls with Toit.
When compiling for the ESP32 family, the ESP-IDF configuration is used.

This directory contains two files: [default_config.h](default_config.h)
and [toit_config.h](toit_config.h). The default config is unused and
serves as a reference for the configuration options. It makes it possible to
easily see which configurations have changed.

## Updating mbedtls

When updating mbedtls to a new version, the configuration files should be
updated to match the new version. Replace the `default_config.h` with the
new version and update the `toit_config.h` to match the changes.
