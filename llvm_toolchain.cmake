set(LLVM_TOOLCHAIN_PREFIX "${CMAKE_CURRENT_LIST_DIR}/llvm_toolchain" CACHE PATH "")

execute_process(
  COMMAND "${CMAKE_CURRENT_LIST_DIR}/bitcoin/depends/config.guess"
  OUTPUT_VARIABLE DEPENDS_HOST_TRIPLE
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

set(DEPENDS_TOOLCHAIN_FILE "${CMAKE_CURRENT_LIST_DIR}/bitcoin/depends/${DEPENDS_HOST_TRIPLE}/toolchain.cmake" CACHE FILEPATH "")

include("${DEPENDS_TOOLCHAIN_FILE}")

# Compile and link with the just-built toolchain.
set(CMAKE_C_COMPILER   "${LLVM_TOOLCHAIN_PREFIX}/bin/clang")
set(CMAKE_CXX_COMPILER "${LLVM_TOOLCHAIN_PREFIX}/bin/clang++")
set(CMAKE_AR           "${LLVM_TOOLCHAIN_PREFIX}/bin/llvm-ar")
set(CMAKE_RANLIB       "${LLVM_TOOLCHAIN_PREFIX}/bin/llvm-ranlib")
set(CMAKE_STRIP        "${LLVM_TOOLCHAIN_PREFIX}/bin/llvm-strip")
set(CMAKE_OBJCOPY      "${LLVM_TOOLCHAIN_PREFIX}/bin/llvm-objcopy")
set(CMAKE_OBJDUMP      "${LLVM_TOOLCHAIN_PREFIX}/bin/llvm-objdump")
set(CMAKE_LINKER_TYPE LLD)

# Locate the installed runtime archives. With LLVM_ENABLE_RUNTIMES they land
# in the per-target runtime directory (lib/<triple>/)
file(GLOB _llvm_libcxx
  "${LLVM_TOOLCHAIN_PREFIX}/lib/libc++.a"
  "${LLVM_TOOLCHAIN_PREFIX}/lib/*/libc++.a")
list(GET _llvm_libcxx 0 _llvm_libcxx)
get_filename_component(LLVM_RUNTIME_LIBDIR "${_llvm_libcxx}" DIRECTORY)

# Compile against the toolchain's libc++ headers; the C++ runtime itself is
# linked explicitly (and statically) below, hence -nostdlib++ at link time.
string(APPEND CMAKE_CXX_FLAGS_INIT " -stdlib=libc++")

# The single quotes around the pass list survive into the ninja rule
set(_opt_record_passes
  inline
  licm
  loop-unroll
  loop-vectorize
  regalloc
  slp-vectorizer
  stack-frame-layout
  wholeprogramdevirt
)
list(JOIN _opt_record_passes "|" _opt_record_passes)

# -Wl,--opt-remarks-with-hotness, needs PGO
# keep -fuse-ld=lld until CMAKE_LINKER_TYPE is in every CMake we use
string(JOIN " " CMAKE_EXE_LINKER_FLAGS
  -fuse-ld=lld
  -flto=full
  -fwhole-program-vtables
  -fstrict-vtable-pointers
  -nostdlib++
  -Wl,--icf=safe
  -Wl,-O2
  -Wl,--lto-O3
  -Wl,--lto-whole-program-visibility
  -Wl,--pack-dyn-relocs=relr
  -Wl,--save-temps
  -fsave-optimization-record
  "-foptimization-record-passes='${_opt_record_passes}'"
)

# LLVM libc in overlay mode: link libllvmlibc.a ahead of the system libc
# https://libc.llvm.org/overlay_mode.html
# libclang_rt.builtins.a is linked explicitly rather than via --rtlib=compiler-rt.
# Scudo is linked ahead of glibc the same way, so its malloc/free/etc. win over
# glibc's (overlay mode: unresolved refs it doesn't provide still fall through).
string(JOIN " " CMAKE_C_STANDARD_LIBRARIES
  -L${LLVM_RUNTIME_LIBDIR}
  -Wl,--start-group
  -lllvmlibc
  "${LLVM_RUNTIME_LIBDIR}/libclang_rt.scudo_standalone.a"
  "${LLVM_RUNTIME_LIBDIR}/libclang_rt.builtins.a"
  -Wl,--end-group
)

string(JOIN " " CMAKE_CXX_STANDARD_LIBRARIES
  -L${LLVM_RUNTIME_LIBDIR}
  -Wl,--start-group
  -lllvmlibc
  "${LLVM_RUNTIME_LIBDIR}/libc++.a"
  "${LLVM_RUNTIME_LIBDIR}/libc++abi.a"
  "${LLVM_RUNTIME_LIBDIR}/libunwind.a"
  "${LLVM_RUNTIME_LIBDIR}/libclang_rt.scudo_standalone.a"
  "${LLVM_RUNTIME_LIBDIR}/libclang_rt.scudo_standalone_cxx.a"
  "${LLVM_RUNTIME_LIBDIR}/libclang_rt.builtins.a"
  -Wl,--end-group
)
