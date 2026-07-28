#!/usr/bin/env bash
set -euo pipefail

TOOLCHAIN="$(pwd)/llvm_toolchain"

export CC="$TOOLCHAIN/bin/clang"
export CXX="$TOOLCHAIN/bin/clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export NM="$TOOLCHAIN/bin/llvm-nm"
export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
export OBJDUMP="$TOOLCHAIN/bin/llvm-objdump"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    NATIVE_FLAG=-march=native
    ;;
  aarch64)
    NATIVE_FLAG=-mcpu=native
    ;;
esac

CFLAGS=(
  -O2
  -flto=full
  "$NATIVE_FLAG"
)

CXXFLAGS=(
  -fwhole-program-vtables
  -fstrict-vtable-pointers
  -fforce-emit-vtables
  -fassume-nothrow-exception-dtor
  )

LDFLAGS=(
  -fuse-ld=lld
)

make -C bitcoin/depends/ \
  NO_IPC=1 \
  NO_QT=1 \
  NO_USDT=1 \
  NO_WALLET=1 \
  NO_ZMQ=1 \
  CFLAGS="${CFLAGS[*]}" \
  CXXFLAGS="${CFLAGS[*]} ${CXXFLAGS[*]}" \
  LDFLAGS="${LDFLAGS[*]}"
