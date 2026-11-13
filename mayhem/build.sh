#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS). EDIT per repo.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
#   - For a FULLY self-contained image (no runtime flag needed) instead vendor:
#       cargo vendor --versioned-dirs vendor   # commit vendor/ + a .cargo/config.toml
#     with [source.crates-io] replace-with = "vendored-sources".
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids
# ASan backtraces. The rlenv PATCH tier prepends `-C debuginfo=2`; we don't fight it.
# ASan for Rust rides RUSTFLAGS (rustc ignores clang's $SANITIZER_FLAGS); an explicit
# empty SANITIZER_FLAGS build-arg disables sanitizers here too.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS-x}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Cdebuginfo=1 -Zdwarf-version=3 -Cforce-frame-pointers"
# DWARF < 4 gate (§6.2 item 10): rustc nightly + clang default to DWARF-5.
# libfuzzer-sys's cc shim gets DWARF-3 via CFLAGS/CXXFLAGS; strip the DWARF-5
# debug info from the bundled ASan runtime archive.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"
# The repo's rust-toolchain.toml pins stable 1.88, which is not installed (and cannot be
# fetched on the air-gapped re-run); -Zsanitizer needs the image's pinned nightly anyway.
# RUSTUP_TOOLCHAIN (set by the Dockerfile) makes every cargo call below use it.
NIGHTLY="${RUSTUP_TOOLCHAIN:-$(rustup toolchain list | awk '/^nightly/{print $1; exit}')}"
export RUSTUP_TOOLCHAIN="$NIGHTLY"
RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
  [ -f "$asan" ] && [ -w "$asan" ] || continue
  objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
  echo "stripped debug info from bundled ASan runtime: $asan"
done

# LeakSanitizer off, at build time (fleet policy): a tiny C object linked into every fuzz binary.
if [ -n "${RUST_SAN}" ]; then
  mkdir -p "$SRC/mayhem/fuzz/target"
  clang ${DEBUG_FLAGS:--g -gdwarf-3} -c mayhem/lsan_off.c -o "$SRC/mayhem/fuzz/target/lsan_off.o"
  export RUSTFLAGS="$RUSTFLAGS -Clink-arg=$SRC/mayhem/fuzz/target/lsan_off.o"
fi

# EDIT: the cargo-fuzz crate directory. Use upstream's own fuzz/ when it builds on
# the pinned nightly; otherwise add an ADDITIVE mayhem/fuzz/ crate (leaves upstream
# untouched) and point --fuzz-dir at it.
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"     # EDIT the output path/name to match your Mayhemfile target:
  echo "built /mayhem/$t"
done

# Build the project's TEST suite too — with the project's NORMAL flags (a clean,
# non-sanitized build) — so mayhem/test.sh only RUNS it. The pyo3 extension-module
# crates (edgeql-parser-python, pgrust, conn_pool, gel-http, pyo3_util, _rust_native)
# cannot link as test binaries; the pure-Rust crates carry the upstream Rust suite.
echo "=== building upstream test suite (normal flags) ==="
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS CARGO_TARGET_DIR="$SRC/target-tests" \
  cargo test --no-run -p edgeql-parser --features edgeql-parser/serde -p edgeql-parser-derive -p graphql-rewrite

echo "build.sh complete"
