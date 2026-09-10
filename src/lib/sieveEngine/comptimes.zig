const Types = @import("types.zig");
const WheelShape = @import("buildUtils").WheelShape;

pub const WHEEL_PRIMES = WheelShape.PRIMES;

pub const WHEEL_CIRCUMFERENCE = WheelShape.CIRCUMFERENCE;

const ADMISSIBLE_RESIDUES_COUNT: comptime_int = WheelShape.RESIDUE_CLASS_COUNT;

pub const AdmissibleResidues = struct {
    count: comptime_int,
    check: [WHEEL_CIRCUMFERENCE]bool,
    list: [ADMISSIBLE_RESIDUES_COUNT]usize,
    reverseMap: [WHEEL_CIRCUMFERENCE]usize,
};

pub const ADMISSIBLE_RESIDUES: AdmissibleResidues = buildAdmissibleResidues();

pub const WheelStep = struct {
    bitMask: u8,
    divMultiplicator: u8,
    residueAddend: u8,
    _padding: u8 = 0,
};

pub const WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = buildWheelPatterns();

// Wheel-210 (2,3,5,7) variant, huge tier only - mirrors primesieve's
// Wheel210_t/EratBig exactly (see bench/primesieve/include/primesieve/
// Wheel.hpp): the underlying sieve array stays wheel-30 (8 bits/bucket)
// everywhere, this only changes which SEQUENCE of admissible-mod-30
// landings a huge-tier prime's stepping visits - skipping any landing
// whose own k-multiplier is divisible by 7 (that occurrence is always
// already crossed off by presieved prime 7 itself, so visiting it is
// provably redundant work). See project memory wheel210_attempt_reverted
// for why two earlier, structurally different attempts (a runtime mod-7
// check on write, and an earlier bloated 2018-style table) both lost -
// this is the first faithful port of primesieve's own mechanism (skip
// baked into the step *sequence* itself, zero runtime branching).
const WHEEL_PRIMES_210 = WHEEL_PRIMES ++ [_]usize{7};
pub const WHEEL_CIRCUMFERENCE_210: comptime_int = WHEEL_CIRCUMFERENCE * 7;
const ADMISSIBLE_RESIDUES_210_COUNT: comptime_int = computeAdmissibleResidueCount210();

pub const AdmissibleResidues210 = struct {
    count: comptime_int,
    check: [WHEEL_CIRCUMFERENCE_210]bool,
    list: [ADMISSIBLE_RESIDUES_210_COUNT]usize,
    reverseMap: [WHEEL_CIRCUMFERENCE_210]usize,
};

pub const ADMISSIBLE_RESIDUES_210: AdmissibleResidues210 = buildAdmissibleResidues210();

// Indexed [prime's own residue class mod 30][phase in the 48-long
// wheel-210 cycle] - same shape as WHEEL_PATTERNS, just a longer inner
// cycle. See buildWheelPatterns210 for why the outer dimension stays
// mod-30 (8 classes, matching primesieve's wheelOffsets_[prime % 30])
// rather than mod-210 (48 classes).
pub const WHEEL_PATTERNS_210: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES_210.count]WheelStep = buildWheelPatterns210();

fn buildAdmissibleResidues() AdmissibleResidues {
    var position: usize = 0;
    var admissibleCheck: [WHEEL_CIRCUMFERENCE]bool = [_]bool{false} ** WHEEL_CIRCUMFERENCE;
    var admissibleList: [ADMISSIBLE_RESIDUES_COUNT]usize = undefined;
    var reverseMap: [WHEEL_CIRCUMFERENCE]usize = undefined;

    for (0..WHEEL_CIRCUMFERENCE) |r| {
        for (WHEEL_PRIMES) |p| {
            if (r % p == 0) {
                reverseMap[r] = position;
                break;
            }
        } else {
            admissibleCheck[r] = true;
            admissibleList[position] = r;
            reverseMap[r] = position;
            position += 1;
        }
    }

    return AdmissibleResidues{
        .count = ADMISSIBLE_RESIDUES_COUNT,
        .check = admissibleCheck,
        .list = admissibleList,
        .reverseMap = reverseMap,
    };
}

fn buildWheelPatterns() [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = undefined;

    for (ADMISSIBLE_RESIDUES.list, &wheelPatterns) |ar, *wp| {
        var number = ar;
        @setEvalBranchQuota(100_000);
        for (wp) |*step| {
            const startNumber = number;
            number += ar;
            var steps = 1;
            while (!ADMISSIBLE_RESIDUES.check[number % WHEEL_CIRCUMFERENCE]) {
                number += ar;
                steps += 1;
            }
            step.* = .{
                .bitMask = ~@as(Types.SIEVE_BUCKET_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[startNumber % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = steps,
                .residueAddend = (number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE),
            };
        }
    }

    return wheelPatterns;
}

fn computeAdmissibleResidueCount210() comptime_int {
    var count: comptime_int = 0;
    for (0..WHEEL_CIRCUMFERENCE_210) |r| {
        for (WHEEL_PRIMES_210) |p| {
            if (r % p == 0) break;
        } else count += 1;
    }
    return count;
}

fn buildAdmissibleResidues210() AdmissibleResidues210 {
    var position: usize = 0;
    var admissibleCheck: [WHEEL_CIRCUMFERENCE_210]bool = [_]bool{false} ** WHEEL_CIRCUMFERENCE_210;
    var admissibleList: [ADMISSIBLE_RESIDUES_210_COUNT]usize = undefined;
    var reverseMap: [WHEEL_CIRCUMFERENCE_210]usize = undefined;

    for (0..WHEEL_CIRCUMFERENCE_210) |r| {
        for (WHEEL_PRIMES_210) |p| {
            if (r % p == 0) {
                reverseMap[r] = position;
                break;
            }
        } else {
            admissibleCheck[r] = true;
            admissibleList[position] = r;
            reverseMap[r] = position;
            position += 1;
        }
    }

    return AdmissibleResidues210{
        .count = ADMISSIBLE_RESIDUES_210_COUNT,
        .check = admissibleCheck,
        .list = admissibleList,
        .reverseMap = reverseMap,
    };
}

// Builds WHEEL_PATTERNS_210 by simulating the SAME "ar" multiplicative
// stand-in as buildWheelPatterns (ar = prime's own residue mod 30, so
// number == ar*k for k = 1, 2, 3, ...), keeping bitMask/residueAddend
// derived from that exact identity (bucket(P*k) == B*k + bucket(ar*k),
// for real prime P = 30*B + ar - see sievePrime.zig's own derivation).
// The wheel-210 admissibility test is therefore NOT "is ar*k coprime to
// 210" (ar itself may be 7, which would make every ar*k spuriously
// divisible by 7 and break that one row entirely) - it's the two
// independent conditions actually implied by "k coprime to 210": ar*k's
// residue mod 30 must already be wheel-30-admissible (unrelated to 7,
// same check as buildWheelPatterns), AND k itself (tracked separately,
// never folded into "number") must not be divisible by 7 - true
// regardless of ar because a real huge-tier prime P is always > 7, so
// 7 | (P*k) iff 7 | k, independent of P mod 7.
fn buildWheelPatterns210() [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES_210.count]WheelStep {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES_210.count]WheelStep = undefined;

    for (ADMISSIBLE_RESIDUES.list, &wheelPatterns) |ar, *wp| {
        var number = ar;
        var k: usize = 1;
        @setEvalBranchQuota(1_000_000);
        for (wp) |*step| {
            const startNumber = number;
            number += ar;
            k += 1;
            var steps: usize = 1;
            while (!ADMISSIBLE_RESIDUES.check[number % WHEEL_CIRCUMFERENCE] or k % 7 == 0) {
                number += ar;
                k += 1;
                steps += 1;
            }
            step.* = .{
                .bitMask = ~@as(Types.SIEVE_BUCKET_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[startNumber % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = @intCast(steps),
                .residueAddend = @intCast((number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE)),
            };
        }
    }

    return wheelPatterns;
}
