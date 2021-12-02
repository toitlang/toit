# Toit language implementation

This repository contains the Toit language implementation. It is fully open source and consists of the compiler,
virtual machine, and standard libraries that together enable Toit programs to run on an ESP32.

We use [GitHub Discussions](https://github.com/toitlang/toit/discussions) to discuss and learn and
we follow a [code of conduct](CODE_OF_CONDUCT.md) in all our community interactions.

## References

The Toit language is the foundation for the [Toit platform](https://toit.io/) that brings robust serviceability
to your ESP32-based devices. You can read more about the language and the standard libraries in the platform
documentation:

* [Language basics](https://docs.toit.io/language)
* [Standard libraries](https://libs.toit.io/)

## Contributing

We welcome and value your [open source contributions](CONTRIBUTING.md) to the language implementation
and the broader ecosystem. Building or porting drivers to the Toit language is a great place to start.
Read about [how to get started building I2C-based drivers](https://github.com/toitlang/toit/discussions/22) and
get ready to publish your new driver to the [package registry](https://pkg.toit.io).

If you're interested in pitching in, we could use your help with
[these drivers](https://github.com/toitlang/toit/issues?q=is%3Aissue+is%3Aopen+label%3Adriver+label%3A%22help+wanted%22)
and more!

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

# Building

## Dependencies

### Build system

To build Toit and its dependencies the build host requires:

* [GNU Make](https://www.gnu.org/software/make/)
* [CMake >= 3.13.3](https://cmake.org/)
* [Ninja](https://ninja-build.org/)
* [GCC](https://gcc.gnu.org/)
* [Go](https://go.dev/)

If you are using a Linux distribution with `apt` capabilities, you can
issue the following command to install these:

``` sh
sudo apt install build-essential cmake ninja-build golang
```

For builds targeting ESP32 hardware additional requirements might be in effect
depending on the build host's architecture, see paragraph [ESP32 tools](#esp32-tools).

### ESP-IDF

The VM has a requirement to ESP-IDF, both for Linux and ESP32 builds (for Linux it's for the [Mbed TLS](https://www.trustedfirmware.org/projects/mbed-tls/) implementation).

We recommend you use Toitware's [ESP-IDF fork](https://github.com/toitware/esp-idf) that comes with a few changes:

* Custom malloc implementation.
* Allocation-fixes for UART, etc.
* LWIP fixes.

This repository has been added as as submodule reference, so doing a recursive init & update will establish everything nedded:

``` sh
git submodule update --init --recursive

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

For other platforms, see [Espressif's documentation](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/index.html#step-3-set-up-the-tools).

Remember to update your environment variables:

``` sh
. $IDF_PATH/export.sh
```

The build system will automatically use a 32-bit build of the Toit compiler to produce the correct executable image for the ESP32.
Your build might fail if you're on a 64-bit Linux machine and you don't have the support for compiling 32-bit executables installed.
You can install this support on most Linux distributions by installing the `gcc-multilib` and `g++-multilib` packages. If you
use `apt`, you can use the following command:

``` sh
sudo apt install gcc-multilib g++-multilib
```

## Build for Linux and macOS

Make sure `IDF_PATH` is set, and the required build tools are installed as described in dependency sections [ESP-IDF](#esp-idf) and [Build system](#build-system) above.

Then run the following commands at the root of your checkout.

``` sh
make tools
```

This builds the Toit VM, the compiler, the language server and the package manager.

You should then be able to execute a toit file:

``` sh
build/host/bin/toitvm examples/hello.toit
```

The package manager is found at `build/toitpkg`:

``` sh
build/toitpkg pkg init --project-root=<some-directory>
build/toitpkg pkg install --project-root=<some-directory> <package-id>
```

The language server can be started with:

``` sh
build/toitlsp --toitc=build/host/bin/toitc
```

See the instructions of your IDE on how to integrate the language server.

For VSCode you can also use the [published extension](https://marketplace.visualstudio.com/items?itemName=toit.toit).

### Notes for macOS

The support for building on macOS is still work in progress. For now, it isn't possible
to build firmware images for the ESP32, because it requires compiling and
running 32-bit executables. We are working on
[addressing this](https://github.com/toitlang/toit/issues/24).

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
