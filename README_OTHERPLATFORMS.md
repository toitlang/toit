# Compiling for other platforms (RISC-V, ARM32, ARM64, WIN32, WIN64)

| STATUS | |
| ------------- | ------------- |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | Linux environment |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | IDF environment |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | IDF compile sources |
| ![](https://img.shields.io/static/v1?label=&message=FAILURE&color=red) | IDF export > [fails on RISC-V host](https://github.com/dsobotta/toit/issues/4) |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green)| Toit generate build files |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | Toit compile sources |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green)| Toit generate boot snapshot |
| ![](https://img.shields.io/static/v1?label=&message=SUCCESS&color=green) | Toit run examples |
| ![](https://img.shields.io/static/v1?label=&message=PARTIAL&color=yellow) | Cross-compile > [fails to link on Arch](https://github.com/dsobotta/toit/issues/6)|
| ![](https://img.shields.io/static/v1?label=&message=TODO&color=orange) | Embedded support |


## 1) Environment setup (RISC-V example)
Install a Debian-based Linux distro (choose one)
- SiFive Unmatched: [Ubuntu Server 20.04](https://ubuntu.com/tutorials/how-to-install-ubuntu-on-risc-v-hifive-boards#1-overview)
- Virtual Machine: [RISC-V VM with QEMU](https://colatkinson.site/linux/riscv/2021/01/27/riscv-qemu/)

## 2) Install dependencies
``` sh
apt update
apt install git build-essential bc cmake python3 python3-pip python-is-python3 libffi-dev libssl-dev cargo golang ninja-build
```

## 3) Clone sources 
``` sh
#Toit
git clone https://github.com/toitlang/toit.git
cd toit/

#ESP-IDF
git submodule update --init --recursive
```

## 4) Compile Toit SDK
``` sh
#Add IDF path to environment
export IDF_PATH=`pwd`/third_party/esp-idf

make tools
```

## 5) Run examples
``` sh
build/host/bin/toit.run examples/hello.toit
build/host/bin/toit.run examples/bubble_sort.toit
build/host/bin/toit.run examples/mandelbrot.toit
```
</br>
</br>

# Cross-compiling
How to compile the Toit binaries (toitc and toit.run) for another architecture (ie. RISC-V) from an amd64 host

## 1) Compile host tools
>Note: This is necessary to generate run_boot.snapshot, a dependency for the toit.run runtime. </br> 
Follow [steps 2-4 above](README_OTHERPLATFORMS.md#2-install-dependencies) on the host.

## 2) Install cross-compile dependencies
``` sh
apt update

#RISC-V 64 (fails to link on Arch Linux)
apt install g++-riscv64-linux-gnu gcc-riscv64-linux-gnu

#ARM 32 (template warnings on compile, but works)
apt install g++-arm-linux-gnueabihf gcc-arm-linux-gnueabihf

#ARM 64
apt install g++-aarch64-linux-gnu gcc-aarch64-linux-gnu

#WIN 32
apt install g++-mingw-w64-i686 gcc-mingw-w64-i686

#WIN 64
apt install g++-mingw-w64-x86-64 gcc-mingw-w64-x86-64
```

## 3) Cross-compile Toit SDK
``` sh
#Substitute <TARGET> with one of [arm32, arm64, riscv64, win32, win64]
make tools-cross CROSS_ARCH=<TARGET>
```

## 4) Deploy
A complete Toit environment should now be ready for use on the target architecture
``` sh
ubuntu@ubuntu:~/git/toit$ ls -l build/riscv64/sdk/bin/
total 4112
lrwxrwxrwx 1 ubuntu ubuntu      31 Dec  4 07:48 lib -> /home/ubuntu/git/toit/lib
drwxrwxr-x 7 ubuntu ubuntu    4096 Dec  4 11:19 mbedtls
-rwxrwxr-x 1 ubuntu ubuntu 1806496 Dec  4 07:49 toitc
-rwxrwxr-x 1 ubuntu ubuntu 2189584 Dec  4 07:49 toit.run
-rw-rw-r-- 1 ubuntu ubuntu  202320 Dec  4 11:19 run_boot.snapshot
```
</br>
</br>
