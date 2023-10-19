# Cross compiling for other platforms on Linux.

## Non-native Linux targets.

You need to install clang (version 16.0.6 works).  It will fetch the
back ends that it needs.

You also need lld.

## Windows targets.

For cross compiling Windows you need the mingw toolchain, 32 or 64 bit.
Wine is also a good idea.

## Compiling.

```shell
make clean && make      # Build the host version.
make disable-auto-sync  # Optional - faster builds.
make TARGET=win64
make TARGET=win32
make TARGET=aarch64     # 64 bit ARM.
make TARGET=armv7       # 32 bit ARM.
make TARGET=riscv64
make TARGET=riscv32
```

The binaries are in build/TARGET/sdk/bin directory.
