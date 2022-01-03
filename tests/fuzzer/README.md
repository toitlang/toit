# Fuzzing

This document describes the steps necessary to fuzz the toit compiler with
AFL (American Fuzzy Lop).

## Prerequisites
Install the fuzzer [0], and, optionally, afl-utils [1].

For Archlinux:
```
pacman -S afl afl-utils
```

[0] https://lcamtuf.coredump.cx/afl/
[1] https://gitlab.com/rc0r/afl-utils

## Compilation
We need to compile the executable using `afl-g++`:
Furthermore, we want to run the compiler in optimized mode (with `-Os`), but
still with `ASSERT`s enabled (and not just using the release build).

```
rm -rf build/debug  # Optional if `debug` wasn't built before
LOCAL_CXXFLAGS="-Os" CC=/usr/bin/afl-gcc CXX=/usr/bin/afl-g++  make debug
```

## Running
We are using the directory `afl-findings` as output for the fuzzer. This can be configured.

A single fuzzer instance can be started as follows:
```
afl-fuzz -i tests/fuzzer/afl-tests -o afl-findings build/debug/sdk/bin/toitc --analyze -Xno_fork -Xlib_path=tests/fuzzer @@
```

Without `afl-utils`, multiple instances can be started as follows (in different shells):
```
afl-fuzz -M fuzzer1 -i tests/fuzzer/afl-tests -o afl-findings build/debug/sdk/bin/toitc --analyze -Xno_fork -Xlib_path=tests/fuzzer @@
afl-fuzz -S fuzzer2 -i tests/fuzzer/afl-tests -o afl-findings build/debug/sdk/bin/toitc --analyze -Xno_fork -Xlib_path=tests/fuzzer @@
afl-fuzz -S fuzzer3 -i tests/fuzzer/afl-tests -o afl-findings build/debug/sdk/bin/toitc --analyze -Xno_fork -Xlib_path=tests/fuzzer @@
...
```

### afl-utils
With `afl-utils`, one can also use `afl-multicore`:
```
afl-multicore -c tests/fuzzer/afl.conf start 8  # where 8 is the number of jobs.
```

Use `afl-whatsup` to see the status of the runners:
```
afl-whatsup afl-out  # The directory specified in the afl.conf file.
```

Use `afl-multikill` to stop all runners:
```
afl-multikill -S toit-fuzzer  # The session name specified in the afl.conf file.
```
