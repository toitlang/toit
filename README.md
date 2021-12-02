------
# RISC-V GETTING STARTED
------

This fork is an experiment in getting Toit running on RISC-V 64-bit hardware.  Below is a list of **WIP** steps required to get Toit running on a SiFive Unmatched dev board or RISC-V VM with QEMU. 

| STATUS | STEP |
| ------------- | ------------- |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | RISC-V environment |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | IDF environment |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | IDF compile sources |
| ![](https://img.shields.io/static/v1?label=&message=FAILURE&color=red) | IDF export [ERROR](https://github.com/dsobotta/toit-riscv/issues/4) |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green)| Toit generate build files |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | Toit compile sources |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green)| Toit generate snapshot |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | Toit run examples |

## 1) RISC-V Environment Setup
Install a Debian-based Linux distro (choose one)
- SiFive Unmatched: [Ubuntu Server 20.04](https://ubuntu.com/tutorials/how-to-install-ubuntu-on-risc-v-hifive-boards#1-overview)
- Virtual Machine: [RISC-V VM with QEMU](https://colatkinson.site/linux/riscv/2021/01/27/riscv-qemu/)
``` sh
#install dependencies
apt update
apt install git build-essential cmake python python3-pip libffi-dev libssl-dev cargo golang ninja-build
```

## 2) Clone Sources 
``` sh
#ESP-IDF
git clone https://github.com/dsobotta/esp-idf-riscv.git
pushd esp-idf-riscv/
git checkout patch-head-4.3-3
git submodule update --init --recursive
popd

#Toit
git clone https://github.com/dsobotta/toit-riscv.git

#Add IDF path to environment
export IDF_PATH=PATH_TO_ESP_IDF_RISCV
```

## 3) Compiling ESP-IDF
> TIP: If you don't wish to deploy to an ESP32 device, you can skip to step 4
``` sh
$IDF_PATH/install.sh
. $IDF_PATH/export.sh
```
  
## 4) Compiling Toit
``` sh
export GO111MODULE=on
cd toit-riscv
make tools
```

------
# ORIGINAL DOCUMENTATION
------

# Toit language implementation

This repository contains the Toit language implementation. It is fully open source and consists of the compiler,
virtual machine, and standard libraries that together enable Toit programs to run on an ESP32.

## Community

Use this [invite](https://discord.gg/ugjgGbW6) to join our Discord server, and follow the development and get help.
We're eager to hear of your experience building with Toit.

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
in those directories and the files they contain. These subdirectories are:

* The subdirectory `lib/font/matthew_welch/`
* Every subdirectory under `lib/font/x11_100dpi/`
* Every subdirectory under `src/compiler/third_party/`
* Every subdirectory under `src/third_party/`
* Every subdirectory under `third_party/`

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

For builds targeting RISC-V, ARM32, or ARM64 hardware, see the [Other platforms README](README_OTHERPLATFORMS.md).

### ESP-IDF

The Toit VM has a requirement for the [Espressif IoT Development Framework](https://idf.espressif.com/), both for Linux and ESP32 builds (for Linux it's for the [Mbed TLS](https://www.trustedfirmware.org/projects/mbed-tls/) implementation).

We recommend you use Toitware's [ESP-IDF fork](https://github.com/toitware/esp-idf) that comes with a few changes:

* Custom malloc implementation.
* Allocation-fixes for UART, etc.
* LWIP fixes.

The fork's repository has been added as a submodule reference to this repository, so doing a recursive submodule init & update will establish everything nedded:

``` sh
git submodule update --init --recursive

```

For the build to succeed, you will need to add its path to your ENV as `IDF_PATH`:

``` sh
export IDF_PATH=`pwd`/third_party/esp-idf
```

To use the [offical ESP-IDF](https://github.com/espressif/esp-idf), or [any other variation](https://github.com/espressif/esp-idf/network/members), make sure it is available in your file system and point IDF_PATH to its path instead before building.

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

## Build for host machine

Make sure `IDF_PATH` is set, and the required build tools are installed as described in dependency sections [ESP-IDF](#esp-idf) and [Build system](#build-system) above.

Then run the following commands at the root of your checkout.

``` sh
make tools
```

---
*NOTE*

These instructions have been tested on Linux and macOS.

Windows support is still [preliminary](https://github.com/toitlang/toit/discussions/33), and
the build instructions may differ for Windows. Let us know on the
[discussions forum](https://github.com/toitlang/toit/discussions) how we can improve
this README.

---

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

## IDE integration

Toit has a [VS Code](https://code.visualstudio.com/) extension. You can either use the
[published extension](https://marketplace.visualstudio.com/items?itemName=toit.toit) or
build it yourself from the
[sources](https://github.com/toitware/ide-tools).

In the VS Code extension (version 1.3.7+) set the `toitLanguageServer.command` setting to
`["PATH_TO_TOIT/build/toitlsp", "--toitc=PATH_TO_TOIT/build/host/bin/toitc"]`, where
`PATH_TO_TOIT` is the path to your Toit checkout.

This makes the extension use the language server that was compiled in the [build step](#build-for-host-machine).

### Other IDEs

The Toit language server is independent of VSCode and can be used with other IDEs.
It can be started with:

``` sh
build/toitlsp --toitc=build/host/bin/toitc
```

See the instructions of your IDE on how to integrate the language server.

There are syntax highlighters for VIM and CodeMirror in the
[ide-tools repository](https://github.com/toitware/ide-tools).

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

Build an image and flash it to your ESP32 device. You must specify the device port
with the `ESP32_PORT` make variable. You can also use all the `make esp32` make variables.

``` sh
make flash ESP32_ENTRY=examples/mandelbrot.toit ESP32_PORT=/dev/ttyUSB0
```

### Configuring WiFi for the ESP32

You can easily configure the ESP32's builtin WiFi by setting the `ESP32_WIFI_SSID` and
`ESP32_WIFI_PASSWORD` make variables:

``` sh
make esp32 ESP32_ENTRY=examples/http.toit ESP32_WIFI_SSID=myssid ESP32_WIFI_PASSWORD=mypassword
```

This allows the WiFi to automatically start up when a network interface is opened.
