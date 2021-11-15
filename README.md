# Toit language implementation

This repository contains the Toit language implementation. It is fully open source and consists of the compiler,
virtual machine, and standard libraries that together enable Toit programs to run on an ESP32.

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

```
$ git clone https://github.com/toitware/esp-idf.git
$ cd esp-idf/
$ git checkout patch-head-4.3-3
$ git submodule update --init --recursive
```

Remember to add it to your ENV as `IDF_PATH`:

```
$ export IDF_PATH=...
```

## Build for Linux

Then run the following commands:

```
$ make build/host/bin/toitvm
```

You should then be able to execute a toit file:

```
$ build/host/bin/toitvm examples/hello.toit
```

## Build for ESP32

You can build an image for your ESP32 device that can be flashed using `esptool.py`.

```
$ make build/esp32/toit.bin
```

By default, the image boots up and runs `examples/hello.toit`.
