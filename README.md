# Toit programming language

This repository contains the Toit language implementation. It consists of the compiler,
virtual machine, and standard libraries that together enable Toit programs to run on an ESP32.

## Jaguar: Live reloading for the ESP32

If you are developing for the ESP32, we recommend to use [Jaguar](https://github.com/toitlang/jaguar). It
automatically downloads the Toit SDK. For host development, see below.

With Jaguar you can use Toit to develop, update, and restart your ESP32 applications in less
than two seconds. Once set up, it is as easy as:

``` sh
jag watch examples/hello.toit
```

It is also straightforward to install extra drivers and services that can extend the core functionality
of your device. Add automatic [NTP](https://en.wikipedia.org/wiki/Network_Time_Protocol)-based time
synchronization without having to write a single line of code:

``` sh
jag container install ntp examples/ntp/ntp.toit
```

You can watch a short video that shows how you can experience Jaguar on your ESP32 in less two minutes:

<a href="https://youtu.be/cU7zr6_YBbQ"><img width="543" alt="Jaguar demonstration" src="https://user-images.githubusercontent.com/133277/146210503-24811800-bb26-4244-817d-6422b20e6786.png"></a>

## Community

Use this [invite](https://discord.gg/Q7Y9VQ5nh2) to join our Discord server, and follow the development and get help.
We're eager to hear of your experience building with Toit. The Discord
chat is publicly accessible through our [Linen](https://linen.dev/d/toit).

We also use [GitHub Discussions](https://github.com/toitlang/toit/discussions) to discuss and learn.

We follow a [code of conduct](CODE_OF_CONDUCT.md) in all our community interactions.

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
* Every subdirectory under `packages/`
* Every subdirectory under `lib/font/x11_100dpi/`
* Every subdirectory under `src/compiler/third_party/`
* Every subdirectory under `src/third_party/`
* Every subdirectory under `third_party/`

# Installation

The instructions in this section don't cover the IDE integration. Follow the instructions
[below](#ide-integration) to set up Toit support for your editor.

## Arch Linux

For [Arch Linux](https://archlinux.org/) (or variants such as [Manjaro](https://manjaro.org/))
use your favorite [AUR helper](https://wiki.archlinux.org/title/AUR_helpers) to
install the [toit](https://aur.archlinux.org/packages/toit/) or
[toit-git](https://aur.archlinux.org/packages/toit-git/) package.

For example:
```
yay -S toit
```

## Other Linux distributions

We are actively working on providing packages for other Linux distributions. In the meantime,
you can use the 'tar.gz' file from the [release](https://github.com/toitlang/toit/releases)
page.

## Windows

On Windows 10+ you can use the [Windows package manager](https://docs.microsoft.com/en-us/windows/package-manager/winget/):
```
winget install --id=Toit.Toit -e
```

Remember to run `winget upgrade --id=Toit.Toit -e` (or simply `winget upgrade`) from
time to time to keep Toit up to date.

## MacOS

We hope to have a Toit package available for [Homebrew](https://brew.sh/) soon. In the meantime,
you can use the DMG or tar.gz file from the [release](https://github.com/toitlang/toit/releases)
page.

# Building

## Dependencies

### Build system

#### Linux and Mac
To build Toit and its dependencies the build host requires:

* [GNU Make](https://www.gnu.org/software/make/)
* [CMake >= 3.13.3](https://cmake.org/)
* [Ninja](https://ninja-build.org/)
* [GCC](https://gcc.gnu.org/)
* [Go >= 1.19](https://go.dev/)
* python-is-python3: on Ubuntu machines
* glibc-tools: optional and only available on newer Ubuntus

If you are using a Linux distribution with `apt` capabilities, you can
issue the following command to install these:

``` sh
sudo apt install build-essential cmake ninja-build golang
```

You can then build Toit by running the following commands in a checkout of this repository:

``` bash
git submodule update --init --recursive
make
```

For builds targeting ESP32 hardware additional requirements might be in effect
depending on the build host's architecture, see paragraph [ESP32 tools](#esp32-tools).

For builds targeting RISC-V, ARM32, or ARM64 hardware, see the [Other platforms README](README_OTHERPLATFORMS.md).

#### Windows

If you are using Windows you can use Chocolatey to install the required dependencies.

After [installing Chocolatey](https://docs.chocolatey.org/en-us/choco/setup), you can
install the required dependencies by running the following command in an elevated shell
(usually the same you just used to install Chocolatey):

``` powershell
choco install git ninja mingw make golang ccache
choco install cmake.install --installargs '"ADD_CMAKE_TO_PATH=System"'
```

After that you can use the bash that comes with Git ('git-bash') and compile Toit
in a checkout of this repository by running the following commands:

``` bash
git submodule update --init --recursive
make
```

### ESP-IDF

The Toit VM has a requirement for the [Espressif IoT Development Framework](https://idf.espressif.com/), both for Linux and ESP32 builds (for Linux it's for the [Mbed TLS](https://www.trustedfirmware.org/projects/mbed-tls/) implementation).

We recommend you use Toitware's [ESP-IDF fork](https://github.com/toitware/esp-idf) that comes with a few changes:

* Custom malloc implementation
* Allocation-fixes for UART, etc.
* LWIP fixes

The fork's repository has been added as a submodule reference to this repository, so doing a recursive submodule init & update will establish everything nedded:

``` sh
git submodule update --init --recursive

```

If the `submodule update` step fails with:

```
Submodule path 'esp-idf/components/coap/libcoap': checked out '98954eb30a2e728e172a6cd29430ae5bc999b585'
fatal: remote error: want 7f8c86e501e690301630029fa9bae22424adf618 not valid
Fetched in submodule path 'esp-idf/components/coap/libcoap/ext/tinydtls', but it did not contain 7f8c86e501e690301630029fa9bae22424adf618. Direct fetching of that commit failed.
```

try following the steps outlined [here](https://github.com/toitlang/toit/issues/88). It is an issue in the upstream ESP-IDF repository
caused by the `tinydtls` component having changed its remote URL.

To use the [offical ESP-IDF](https://github.com/espressif/esp-idf), or [any other variation](https://github.com/espressif/esp-idf/network/members), you need to add the Toit specific patches first.

Then make sure it is available in your file system and point IDF_PATH to its path instead before building.

``` sh
export IDF_PATH=<A_DIFFERENT_ESP_IDF>
```

### ESP32 tools

If you want to build an image for the ESP32, install the ESP32 tools.

On Linux:
``` sh
$IDF_PATH/install.sh
```

The default location of $IDF_PATH is under ```./third_party/esp-idf```

For other platforms, see [Espressif's documentation](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/index.html#step-3-set-up-the-tools).

Remember to update your environment variables:

``` sh
source $IDF_PATH/export.sh
```

## Build for host machine

Make sure the required build tools are installed as described in dependency sections [ESP-IDF](#esp-idf) and [Build system](#build-system) above.

Then run the following commands at the root of your checkout.

``` sh
make all
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
build/host/sdk/bin/toit examples/hello.toit
```

The `toit` executable also serves as the package manager:

``` sh
build/host/sdk/bin/toit pkg init --project-root=<some-directory>
build/host/sdk/bin/toit pkg install --project-root=<some-directory> <package-id>
```

### Debugging
See https://github.com/toitlang/toit/wiki/Debugging.

## IDE integration

Toit has a [VS Code](https://code.visualstudio.com/) extension. You can either use the
[published extension](https://marketplace.visualstudio.com/items?itemName=toit.toit) or
build it yourself from the
[sources](https://github.com/toitware/ide-tools).

In the VS Code extension (version 1.3.7+) set the `toitLanguageServer.command` setting to
`["PATH_TO_SDK/bin/toit", "tool", "lsp"]`, where
`PATH_TO_SDK` is the path to your `build/host/sdk/` folder in the Toit repository.

This makes the extension use the language server that was compiled in the [build step](#build-for-host-machine).

### Other IDEs

The Toit language server is independent of VSCode and can be used with other IDEs.
It can be started with:

``` sh
build/host/sdk/bin/toit.lsp --toitc=build/host/sdk/bin/toit.compile
```

See the instructions of your IDE on how to integrate the language server.

There are syntax highlighters for VIM and CodeMirror in the
[ide-tools repository](https://github.com/toitware/ide-tools).

## Build for ESP32

Make sure the environment variables for the ESP32 tools are set, as
described in the [dependencies](#dependencies) section. Typically this
consists of running the following command:

``` bash
# On Linux and Mac OS X:
third_party/esp-idf/install.sh
```
``` powershell
# On Windows:
third_party\esp-idf\install.bat
```

Build firmware that can be flashed onto your ESP32 device. The firmware is generated
in `build/esp32/firmware.envelope`:

``` sh
make esp32
```

If you want to flash the generated firmware on your device, you can use the `firmware`
too. Internally, the `firmware` tool calls out to
[esptool](https://github.com/espressif/esptool)
so you need to install that one first.
You can also set the environment variable `ESPTOOL_PATH` to point
to a valid esptool (for example the one in the shipped esp-idf:
`export ESPTOOL_PATH=$PWD/third_party/esp-idf/components/esptool_py/esptool/esptool.py`).
Assuming your device is connected through `/dev/ttyUSB0`
you can then flash a device as follows:

``` sh
build/host/sdk/lib/toit/tool firmware -e build/esp32/firmware.envelope \
    flash --port /dev/ttyUSB0 --baud 921600
```

By default, the image boots up but does not run any application code. You can use your
own entry point by installing it into the firmware envelope before flashing:

``` sh
build/host/sdk/bin/toit compile --snapshot -o hello.snapshot examples/hello.toit
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    container install hello hello.snapshot
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    flash --port /dev/ttyUSB0 --baud 921600
```

### Adding multiple containers

You can add more containers before you flash, so you firmware
envelope can have any number of containers. Be aware that adding the NTP
example below requires you to [configure the WiFi on the ESP32](#configuring-wifi-for-the-esp32) when you
flash.

``` sh
build/host/sdk/bin/toit compile --snapshot -o hello.snapshot examples/hello.toit
build/host/sdk/bin/toit compile --snapshot -o ntp.snapshot examples/ntp/ntp.toit

# Typically we set the output envelope the first time we change it.
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    -o custom.envelope \
    container install hello hello.snapshot
build/host/sdk/bin/toit tool firmware -e custom.envelope \
    container install ntp ntp.snapshot
```

You can list the containers in a given firmware envelope:

``` sh
build/host/sdk/bin/toit tool firmware -e custom.envelope container list
```

The listing shows the containers that are installed.

```
system:
  Kind: snapshot
  Id: bf14aa94-4b7e-3ddd-94a9-a22f5d1ec92c
  Size: 242104
  Flags:
    - trigger=boot
    - critical
hello:
  Kind: snapshot
  Id: adc2babc-d89a-2301-98a1-3a1dfe34f144
  Size: 141852
  Flags:
    - trigger=boot
ntp:
  Kind: snapshot
  Id: 8d8ff2f0-3c51-13e8-6876-84a70fa359b5
  Size: 187330
  Flags:
    - trigger=boot
```

You can use the `--output-format=json` flag to get the output in JSON format.

### Adding container assets

Containers have associated assets that they can access at runtime. Add the
following code to a file named `assets.toit`:

```
import system.assets

main:
  print assets.decode
```

If you run this on an ESP32, you'll get an empty map printed becase you
haven't associated any assets with the container that holds the code.

To associate assets with the container, we first construct an encoded
assets file and add this `README.md` file to it.

``` sh
build/host/sdk/bin/toit tool assets -e encoded.assets create
build/host/sdk/bin/toit tool assets -e encoded.assets add readme README.md
```

Now we can add the `encoded.assets` to the `assets` container at
install time:

``` sh
build/host/sdk/bin/toit compile --snapshot -o assets.snapshot assets.toit
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    container install assets assets.snapshot \
    --assets=encoded.assets
```

If you update the source code in `assets.toit` slightly, the
printed information will be more digestible:

```
import system.assets

main:
  readme := assets.decode["readme"]
  // Guard against splitting a unicode character by
  // making this non-throwing.
  print readme[0..80].to_string_non_throwing
```

You'll need to reinstall the container after this by recompiling
the `assets.toit` file to `assets.snapshot` and re-running:

``` sh
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    container install assets assets.snapshot \
    --assets=encoded.assets
```

### Configuring WiFi for the ESP32

You can easily configure the ESP32's builtin WiFi passing it as configuration
when you flash:

``` sh
echo '{ "wifi": { "wifi.ssid": "myssid", "wifi.password": "mypassword" } }' > wifi.json
build/host/sdk/bin/toit tool firmware -e build/esp32/firmware.envelope \
    flash --config wifi.json \
    --port /dev/ttyUSB0 --baud 921600
```

This allows the WiFi to automatically start up when a network interface is opened.

---
*NOTE*

To access the device `/dev/ttyUSB0` on Linux you probably need to be a member
of some group, normally either `uucp` or `dialout`.  To see which groups you are
a member of and which group owns the device, plug in an ESP32 to the USB port
and try:

``` sh
groups
ls -g /dev/ttyUSB0
```

If you lack a group membership, you can add it with

``` sh
sudo usermod -aG dialout $USER
```

You will have to log out and log back in for this to take effect.
