# Toit configuration for mbedtls

This directory contains the configuration for building mbedtls with Toit.
When compiling for the ESP32 family, these files are ignored and the
ESP-IDF configuration is used. (The ESP-IDF configuration is located in
`./third_party/esp-idf/components/mbedtls/port/include/mbedtls/esp_config.h`.)

This directory contains two files: [default_config.h](default_config.h)
and [toit_config.h](toit_config.h). The default config is unused and
serves as a reference for the configuration options. It makes it possible to
easily see which configurations have changed.

## Updating mbedtls

When updating mbedtls to a new version, the configuration files should be
updated to match the new version.

Use the current `default_config.h` as a reference to see which configurations
were changed. It's likely we want the same changes in the new version.

Then replace the `default_config.h` with the new version located at
third_party/esp-idf/components/mbedtls/mbedtls/include/mbedtls/mbedtls_config.h.

Use it as a base for a new updated `toit_config.h`.
