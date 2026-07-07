#!/usr/bin/env bash
# Build the sapling-dag cargo-fuzz targets (gca*/range* families) as sanitized
# libFuzzer binaries. OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): verify-repo re-runs this OFFLINE (--network none,
# no CARGO_NET_OFFLINE). So the FIRST (online) build vendors every crates.io dep into
# the image + writes a source-replacement into $CARGO_HOME/config.toml; the offline
# re-run then resolves everything from vendor/ and skips vendoring (dir already there).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

SRC="${SRC:-/mayhem}"
cd "$SRC"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# §6.2 item 10: Mayhem's triage can't read DWARF >= 4. Force DWARF 3 in rustc and (for the C/C++
# compiled in -sys crates like libfuzzer-sys) in clang, so NO compilation unit in the linked binary
# is >= 4. The prebuilt std rlibs + asan runtime archives (DWARF 4/5) are debug-stripped in the
# Dockerfile so their CUs don't leak in. Thread $RUST_DEBUG_FLAGS (overridable) into RUSTFLAGS.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Zdwarf-version=3}"
export RUST_DEBUG_FLAGS

# $SANITIZER_FLAGS are clang flags rustc ignores; the Rust ASan path goes via RUSTFLAGS.
# Reference it so the intent (sanitize the fuzzed code) is explicit + greppable.
: "${SANITIZER_FLAGS:=}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# ---- air-gapped vendor (first, online build only) ----------------------------------
VENDOR_DIR="$SRC/mayhem/vendor"
if [ ! -d "$VENDOR_DIR" ]; then
  echo "=== vendoring crates.io deps for offline re-runs ==="
  ( cd "$FUZZ_DIR" && cargo generate-lockfile )
  cargo vendor --manifest-path "$FUZZ_DIR/Cargo.toml" --versioned-dirs "$VENDOR_DIR" >/dev/null
  : "${CARGO_HOME:?CARGO_HOME must be set (pinned by the Dockerfile)}"
  # Idempotent: only append the replacement block once.
  if ! grep -q 'vendored-sources' "$CARGO_HOME/config.toml" 2>/dev/null; then
    cat >> "$CARGO_HOME/config.toml" <<CFG

[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$VENDOR_DIR"
CFG
  fi
fi

# ---- bindag tempdir sweep (build-time only; git tree stays additive) ----------------
# Every fuzz process materializes its TestContext as an ON-DISK Dag inside
# tempfile::tempdir() (/tmp/.tmpXXXX). Mayhem's regression phase replays crashing inputs
# in a FRESH process per input (these targets carry historical assert-defects), and each
# process is SIGKILLed before the TempDir Drop runs — thousands of leaked DAG dirs fill
# the 488MB run tmpfs, the run dies ("Ran out of writeable disk space") and coverage
# finalizes at edges=0 despite fuzzing fine mid-run. Rewrite the tempdir creation to
# (a) live under /tmp/bindag-dags/pid<PID>-* and (b) sweep sibling dirs whose creating
# process is dead before creating ours. Disk stays bounded; live processes are never
# touched. Idempotent + offline-safe.
python3 - "$SRC/eden/scm/lib/dag/bindag/src/test_context.rs" <<'PYSWEEP'
import sys
p = sys.argv[1]
s = open(p).read()
old = "let dir = tempfile::tempdir().unwrap();"
new = """let dir = {
            let base = std::path::Path::new("/tmp/bindag-dags");
            let _ = std::fs::create_dir_all(base);
            if let Ok(rd) = std::fs::read_dir(base) {
                for e in rd.flatten() {
                    let name = e.file_name().to_string_lossy().into_owned();
                    let dead = name
                        .strip_prefix("pid")
                        .and_then(|rest| rest.split('-').next())
                        .and_then(|pid| pid.parse::<u32>().ok())
                        .map_or(true, |pid| !std::path::Path::new(&format!("/proc/{pid}")).exists());
                    if dead {
                        let _ = std::fs::remove_dir_all(e.path());
                    }
                }
            }
            tempfile::Builder::new()
                .prefix(&format!("pid{}-", std::process::id()))
                .tempdir_in(base)
                .unwrap()
        };"""
if "bindag-dags" in s and old not in s:
    print("bindag tempdir sweep: already applied")
elif old in s:
    open(p, "w").write(s.replace(old, new, 1))
    print("bindag tempdir sweep: patched", p)
else:
    sys.exit("bindag tempdir sweep: anchor line not found in " + p)
PYSWEEP

# cargo-fuzz must run from a cargo PROJECT root (a dir with Cargo.toml); the fuzzed
# project is the dag crate. --fuzz-dir points at our additive fuzz crate.
PROJECT_DIR="$SRC/eden/scm/lib/dag"
FUZZ_DIR_ABS="$SRC/$FUZZ_DIR"
FUZZ_TARGETS=(gca gca_small gca_octopus range range_medium range_octopus range_small)
echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
# Force a clean relink so no stale DWARF-5 object lingers from a prior cache (memory: old-rust-dwarf).
rm -rf "$FUZZ_DIR_ABS/target"
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  ( cd "$PROJECT_DIR" && cargo fuzz build --fuzz-dir "$FUZZ_DIR_ABS" -O --debug-assertions "$t" )
  bin="$FUZZ_DIR_ABS/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done
echo "build.sh complete"
