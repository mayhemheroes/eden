/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// Additive Mayhem variant of the upstream `gca` fuzz target.
//
// ROOT CAUSE this file works around: the upstream target builds its context as
// `TestContext::from_bin(MOZILLA).truncate(65535)`. `from_bin` slices `0..MAX`,
// so `from_parents` first constructs the full segmented IdDag over EVERY rev of
// mozilla-central (~60k), and `truncate` then only trims the plain-parents Vec
// AFTER the heavy `add_heads_and_flush` + full idmap build has already run. That
// build happens lazily on the first `LLVMFuzzerTestOneInput` call, and under
// Mayhem`s instrumented (ASan) executor it never finishes inside the smoke-test
// window: libFuzzer is interrupted before 5 iterations, so the run is flagged
// `has_critical_errors` with 0 edges. (gca_octopus / the range* targets build
// from a small graph and are productive.)
//
// Fix: build from a bounded slice of the DAG, exactly as the productive `range`
// target does ("The complete DAG is too large ... take a subset"). The IdDag
// init then completes quickly while the identical `gca_all` code path is still
// exercised over a real, non-trivial DAG. The upstream sources under eden/ are
// left untouched; only this additive fuzz crate changes which context gca uses.
// The shared test oracle is reused from the upstream sources by path.

#![no_main]

use std::sync::LazyLock;

use bindag::TestContext;
use libfuzzer_sys::fuzz_target;

#[path = "../../../eden/scm/lib/dag/fuzz/fuzz_targets/tests.rs"]
mod tests;

// Same bounded slice the productive `range` target uses (~11k revs) — its IdDag
// init is proven to complete within Mayhem`s window.
static CONTEXT: LazyLock<TestContext> =
    LazyLock::new(|| TestContext::from_bin_sliced(bindag::MOZILLA, 49040..60415));

fuzz_target!(|input: Vec<u16>| {
    // gca with > 3 revs is less interesting to this test.
    let revs = CONTEXT.clamp_revs(&input[..input.len().min(3)]);
    tests::test_gca(&CONTEXT, revs);
});
