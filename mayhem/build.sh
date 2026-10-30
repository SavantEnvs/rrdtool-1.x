#!/usr/bin/env bash
#
# mayhem/build.sh — builds rrdtool's two upstream libFuzzer harnesses (fuzz/*.c) against a sanitized
# static librrd, plus the project's own test suite with normal flags. Runs as `mayhem` in /mayhem.
# Nothing here touches the network; re-running on an already-built tree is safe.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Features the harnesses and tests don't need are disabled: bindings, docs, rrdcgi, libdbi/rados/wrap.
COMMON_CONF=(--disable-docs --disable-examples --disable-rrdcgi --disable-perl --disable-ruby
             --disable-lua --disable-tcl --disable-python --disable-libdbi --disable-librados
             --disable-libwrap --disable-nls)

# 0) generated build system (autoreconf output is gitignored; recreated here after a clean tree)
[ -x ./configure ] || ./bootstrap

# 1) sanitized, SanCov-instrumented static librrd (graph code is not reachable from the harnesses)
mkdir -p build/fuzz
(
  cd build/fuzz
  [ -f Makefile ] || "$SRC/configure" "${COMMON_CONF[@]}" --disable-rrd_graph --disable-rrdcached \
      --disable-shared --enable-static CC="$CC" \
      CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
      LDFLAGS="$SANITIZER_FLAGS"
  make -C src -j"$MAYHEM_JOBS" librrd.la
)

# 2) harnesses: libFuzzer binary + run-once standalone reproducer, each with leak detection off
LIB="$SRC/build/fuzz/src/.libs/librrd.a"
SYSLIBS="$(pkg-config --libs libxml-2.0 glib-2.0) -lm -lpthread"
INC="-I$SRC/src -I$SRC/build/fuzz/src $(pkg-config --cflags libxml-2.0 glib-2.0)"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
for h in rrd_open_fuzzer rrd_restore_fuzzer; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC "$SRC/fuzz/$h.c" /tmp/lsan_off.o \
      $LIB $SYSLIBS $LIB_FUZZING_ENGINE -o "$SRC/$h"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC "$SRC/fuzz/$h.c" /tmp/lsan_off.o /tmp/standalone_main.o \
      $LIB $SYSLIBS -o "$SRC/$h-standalone"
done

# 3) the project's own test suite, normal flags, built (not run) for mayhem/test.sh
mkdir -p build/test
(
  cd build/test
  [ -f Makefile ] || env -u CFLAGS -u LDFLAGS "$SRC/configure" "${COMMON_CONF[@]}" CC="$CC" \
      CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  make -j"$MAYHEM_JOBS"
  make -C tests -j"$MAYHEM_JOBS" check TESTS=
)
