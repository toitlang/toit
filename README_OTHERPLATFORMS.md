# Cross compiling for other platforms on Linux.

## Non-native Linux targets.

You need to install clang (version 16.0.6 works).

Our Makefile will fetch the necessary sysroots that it needs.
They are fetched from https://github.com/toitlang/sysroots/releases/latest

You also need lld.

## Windows targets.

For cross compiling Windows you need the mingw toolchain, 32 or 64 bit.
Wine is also a good idea.

## Compiling.

```shell
make clean
make disable-auto-sync  # Optional - faster builds.
make TARGET=win64
make TARGET=win32
# For Linux targets the Makefile has aliases.  The following
# calls are equivalent to `make TARGET=X`
make aarch64     # 64 bit ARM.
make armv7       # 32 bit ARM.
make riscv64
make riscv32
make raspbian    # Sysroot based on 32 bit Raspbian image.
make pi          # Same as raspbian.
make arm-linux-gnueabi
```

The binaries are in build/TARGET/sdk/bin directory.
