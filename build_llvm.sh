#!/usr/bin/env bash
set -euo pipefail

LLVM_SRC=llvm-project
BUILD="llvm_build"
RUNTIMES_BUILD="runtimes_build"
PREFIX="$(pwd)/llvm_toolchain"

CC="${CC:-clang}"
CXX="${CXX:-clang++}"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    TRIPLE=x86_64-unknown-linux-gnu
    LLVM_TARGET=X86
    NATIVE_FLAG=-march=native
    ;;
  aarch64)
    TRIPLE=aarch64-unknown-linux-gnu
    LLVM_TARGET=AArch64
    NATIVE_FLAG=-mcpu=native
    ;;
esac

rm -rf "$BUILD" "$RUNTIMES_BUILD" "$PREFIX"

# Drop qsort/qsort_r from llvm-libc: in overlay mode with -static-pie
# we collide with glibc.
cat > "$LLVM_SRC/libc/config/linux/$ARCH/exclude.txt" <<'EOF'
list(APPEND TARGET_LLVMLIBC_REMOVED_ENTRYPOINTS
  libc.src.stdlib.qsort
  libc.src.stdlib.qsort_r
)
EOF

# Need -flto here too, for -fwhole-program-vtables, because
# LLVM_ENABLE_LTO doesn't add the flag early enough.
LTO_FLAGS=(
  -flto=full
)

RUNTIMES_FLAGS=(
  "$NATIVE_FLAG"
  -fstack-protector-all
)
if [ "$ARCH" = aarch64 ]; then
  RUNTIMES_FLAGS+=(-mbranch-protection=standard)
fi
RUNTIMES_CXX_FLAGS=(
  -fwhole-program-vtables
  -fstrict-vtable-pointers
  -fforce-emit-vtables
)

cmake -S "$LLVM_SRC/llvm" -B "$BUILD" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_FLAGS="$NATIVE_FLAG" \
  -DCMAKE_CXX_FLAGS="$NATIVE_FLAG" \
  -DCMAKE_AR="$(command -v llvm-ar)" \
  -DCMAKE_RANLIB="$(command -v llvm-ranlib)" \
  -DLLVM_CCACHE_BUILD=ON \
  -DLLVM_ENABLE_LLD=ON \
  -DLLVM_ENABLE_LTO=Thin \
  -DLLVM_THINLTO_CACHE_PATH="$(pwd)/thinlto_cache" \
  -DCMAKE_LINKER_TYPE=LLD \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--thinlto-cache-policy=cache_size_bytes=20g" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--thinlto-cache-policy=cache_size_bytes=20g" \
  -DLLVM_ENABLE_PROJECTS='bolt;clang;lld' \
  -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGET"

cmake --build "$BUILD" --target install

cmake -S "$LLVM_SRC/runtimes" -B "$RUNTIMES_BUILD" -G Ninja \
  -DCMAKE_C_COMPILER="$PREFIX/bin/clang" \
  -DCMAKE_CXX_COMPILER="$PREFIX/bin/clang++" \
  -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$TRIPLE" \
  -DCMAKE_ASM_COMPILER_TARGET="$TRIPLE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_ASM_FLAGS="${RUNTIMES_FLAGS[*]}" \
  -DCMAKE_C_FLAGS="${LTO_FLAGS[*]} ${RUNTIMES_FLAGS[*]}" \
  -DCMAKE_CXX_FLAGS="${LTO_FLAGS[*]} ${RUNTIMES_FLAGS[*]} ${RUNTIMES_CXX_FLAGS[*]}" \
  -DCMAKE_AR="$PREFIX/bin/llvm-ar" \
  -DCMAKE_RANLIB="$PREFIX/bin/llvm-ranlib" \
  -DCMAKE_LINKER_TYPE=LLD \
  -DLLVM_ENABLE_LTO=Full \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
  -DLLVM_ENABLE_RUNTIMES='libc;libcxx;libcxxabi;libunwind;compiler-rt' \
  -DLIBCXX_ENABLE_SHARED=OFF \
  -DLIBCXX_ENABLE_STATIC=ON \
  -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXXABI_ENABLE_STATIC=ON \
  -DLIBUNWIND_ENABLE_SHARED=OFF \
  -DLIBUNWIND_ENABLE_STATIC=ON \
  -DLIBCXX_HERMETIC_STATIC_LIBRARY=ON \
  -DLIBCXXABI_HERMETIC_STATIC_LIBRARY=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXX_HARDENING_MODE=none \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_CRT=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=ON \
  -DCOMPILER_RT_SANITIZERS_TO_BUILD=scudo_standalone \
  -DCOMPILER_RT_SCUDO_STANDALONE_BUILD_SHARED=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=ON \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF

cmake --build "$RUNTIMES_BUILD" --target install

# With LLVM_ENABLE_PER_TARGET_RUNTIME_DIR, compiler-rt installs its archives
# alongside libc++ in lib/<triple>/, but the driver's own default/--rtlib=/
# -fprofile-generate resolution still only looks under the versioned clang
# resource dir (lib/clang/<ver>/lib/<triple>/). Symlink each one into place
# there so every caller of this clang (not just consumers of
# llvm_toolchain.cmake) finds it.
RESOURCE_DIR="$("$PREFIX/bin/clang++" -print-resource-dir)"
mkdir -p "$RESOURCE_DIR/lib/$TRIPLE"
for lib in "$PREFIX/lib/$TRIPLE"/libclang_rt.*.a; do
  ln -sf "$lib" "$RESOURCE_DIR/lib/$TRIPLE/$(basename "$lib")"
done

rm -rf "$BUILD" "$RUNTIMES_BUILD"
