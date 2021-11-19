# Toit language implementation

This repository contains the Toit language implementation. It is fully open source and consists of the compiler,
virtual machine, and standard libraries that together enable Toit programs to run on an ESP32.

We use [GitHub Discussions](htts://github.com/toitlang/toit/discussions) to discuss and learn and
we follow a [code of conduct](CODE_OF_CONDUCT.md) in all our community interactions.

## References

The Toit language is the foundation for the [Toit platform](https://toit.io/) that brings robust serviceability
to your ESP32-based devices. You can read more about the language and the standard libraries in the platform
documentation:

* [Language basics](https://docs.toit.io/language)
* [Standard libraries](https://libs.toit.io/)

## Licenses

The Toit compiler, the virtual machine, and all the supporting infrastructure is licensed under
the [LGPL-2.1](LICENSE) license. The standard libraries contained in the `lib/` directory
are licensed under the [MIT](lib/LICENSE) license. The examples contained in the `examples/`
directory are licensed under the [0BSD](examples/LICENSE) license.

Certain subdirectories are under their own open source licenses, detailed
in those directories.  These subdirectories are:

* Every subdirectory under `src/third_party`
* Every subdirectory under `src/compiler/third_party`
* Every subdirectory under `lib/font/x11_100dpi`
* The subdirectory `lib/font/matthew_welch`

## Dependencies

### ESP-IDF

The VM has a requirement to ESP-IDF, both for Linux and ESP32 builds (for Linux it's for the MBedTLS implementation).

We recommend you use Toitware's [ESP-IDF fork](https://github.com/toitware/esp-idf) that comes with a few changes:

* Custom malloc implementation.
* Allocation-fixes for UART, etc.
* LWIP fixes.

``` sh
git clone https://github.com/toitware/esp-idf.git
pushd esp-idf/
git checkout patch-head-4.3-3
git submodule update --init --recursive
popd
```

Remember to add it to your ENV as `IDF_PATH`:

``` sh
export IDF_PATH=...
```

### ESP32 tools

Install the ESP32 tools, if you want to build an image for an ESP32.

On Linux:
``` sh
$IDF_PATH/install.sh
```

For other platforms see https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/index.html#step-3-set-up-the-tools

Update your environment variables:

``` sh
. $IDF_PATH/export.sh
```

## Build for Linux

Make sure `IDF_PATH` is set, as described above.

Then run the following commands at the root of your checkout.

``` sh
make build/host/bin/toitvm
```

You should then be able to execute a toit file:

``` sh
build/host/bin/toitvm examples/hello.toit
```

## Build for ESP32

Make sure the environment variables for the ESP32 tools are set, as
described in the [dependencies](#dependencies) section.

Build an image for your ESP32 device that can be flashed using `esptool.py`.

``` sh
make esp32
```

By default, the image boots up and runs `examples/hello.toit`. You can use your
own entry point and specify it through the `ESP32_ENTRY` make variable:

``` sh
make esp32 ESP32_ENTRY=examples/mandelbrot.toit
```

### Configuring WiFi for the ESP32

You can easily configure the ESP32's builtin WiFi by setting the `ESP32_WIFI_SSID` and
`ESP32_WIFI_PASSWORD` make variables:

``` sh
make esp32 ESP32_ENTRY=examples/http.toit ESP32_WIFI_SSID=myssid ESP32_WIFI_PASSWORD=mypassword
```

This allows the WiFi to automatically start up when a network interface is opened.


## Contributing

We welcome and value your [open source contributions](CONTRIBUTING.md).
