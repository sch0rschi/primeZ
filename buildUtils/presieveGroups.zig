// The DEFAULT presieve grouping - used whenever no solved config exists at
// build.zig's SOLVED_PRESIEVE_GROUPS_PATH (see resolvePresieveGroups
// there). This is NOT this project's own tuning output: it's primesieve's
// own "large" pre-sieve buffer grouping, copied directly from
// bench/primesieve/src/PreSieve.cpp's `bufferPrimes` (and matching that
// file's own doc comment) - the same 8 buffers/22 primes (7..97) primesieve
// itself ships and benchmarks against in this repo, so a from-scratch
// checkout with no solved config starts from an already-validated grouping
// rather than an untested guess. `zig build regen-presieve-groups` (see
// build.zig) can replace this at build time without ever touching this
// file - see SOLVED_PRESIEVE_GROUPS_PATH's docstring.
//
// Lives here, not in preSieve.zig itself, so both preSieve.zig (via the
// "buildUtils" named module, for periodOf and as build.zig's import-level
// fallback) and genPreSievePatternsTool.zig (a bare `zig run`, plain
// relative import - see that file, for periodOf only: GROUPS itself now
// always arrives via build.zig's argv, see computePreSievePatternsBlob)
// share one definition instead of risking drift.
pub const GROUPS = [_][]const usize{
    &[_]usize{ 7, 67, 71 },
    &[_]usize{ 11, 41, 73 },
    &[_]usize{ 13, 43, 59 },
    &[_]usize{ 17, 37, 53 },
    &[_]usize{ 19, 29, 61 },
    &[_]usize{ 23, 31, 47 },
    &[_]usize{ 79, 97 },
    &[_]usize{ 83, 89 },
};

pub const GROUP_COUNT = GROUPS.len;

/// Not comptime-qualified: works identically called from a comptime context
/// (preSieve.zig, primes known at comptime) or plain runtime code
/// (genPreSievePatternsTool.zig) - Zig comptime-evaluates a call
/// transparently based on the call site, no qualifier needed here since the
/// result is never used as a type/array-bound at this function's own
/// signature-elaboration stage.
pub fn periodOf(primes: []const usize) usize {
    var period: usize = 1;
    for (primes) |p| period *= p;
    return period;
}
