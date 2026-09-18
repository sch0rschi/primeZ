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
    // Inert padding (always 0, never read) - exists purely for
    // size-rounding, kept at u8 since WHEEL_PATTERNS' own wheel-30
    // wraparound is a free u3 +% 1 and needs no baked-in "next" data.
    // Huge tier's own wheel-210 stepping uses a SEPARATE type
    // (WheelStep210 below) instead of this field, to avoid growing
    // this struct (and therefore WHEEL_PATTERNS' own per-row byte
    // stride, shared with small/medium/large) for a need only huge
    // tier has.
    _reserved: u8 = 0,
};

pub const WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = buildWheelPatterns();

// Wheel-210 (2,3,5,7) variant, huge tier only: the underlying sieve array
// stays wheel-30 (8 bits/bucket) everywhere, this only changes which
// SEQUENCE of admissible-mod-30 landings a huge-tier prime's stepping
// visits - skipping any landing whose k-multiplier is divisible by 7
// (always already crossed off by presieved prime 7, so redundant).
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

// Huge tier's own wheel-210 step data - {bitMask, divMultiplicator,
// residueAddend} exactly like WheelStep, plus a FLAT "next" index
// (0..383, covering all 8 residues x 48 phases combined into one
// number) instead of storing residue and phase as two separate fields
// on the ring-resident entry. Mirrors primesieve's own EratBig.cpp
// `wheel210` table (`WheelElement{unsetBit, nextMultipleFactor,
// correct, next}`) exactly: `next` is precomputed once, at table-build
// time, so the hot per-hit path (hugeSievePrimes.zig's processOne)
// never needs to recombine residue+phase into a row offset at runtime
// - the SEPARATE row-stride-multiply this table used to need (padded
// to WHEEL_210_ROW_LEN=64 for exactly that reason, previously) is gone
// entirely, along with the run-time combine itself, not just its cost.
// Explicit size-padded to a power of 2 (8 bytes), mirroring
// WheelElement's own documented reason ("improves performance by up to
// 15%") - not required for correctness, but avoids reintroducing a
// non-native struct-width tax elsewhere.
pub const WheelStep210 = extern struct {
    bitMask: u8,
    divMultiplicator: u8,
    residueAddend: u8,
    _pad: u8 = 0,
    nextWheelIndex210: u16,
    _pad2: u16 = 0,
};

const WHEEL_210_PHASE_COUNT = ADMISSIBLE_RESIDUES_210.count;
pub const WHEEL_PATTERNS_210: [ADMISSIBLE_RESIDUES.count * WHEEL_210_PHASE_COUNT]WheelStep210 = buildWheelPatterns210();

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

// The wheel-210 admissibility test is NOT "is ar*k coprime to 210" (ar
// itself may be 7, which would make every ar*k spuriously divisible by 7
// and break that row) - it's two independent conditions: ar*k's residue
// mod 30 must be wheel-30-admissible, AND k itself must not be divisible
// by 7. The latter holds regardless of ar because a real huge-tier prime
// is always > 7, so 7 | (prime*k) iff 7 | k.
fn buildWheelPatterns210() [ADMISSIBLE_RESIDUES.count * WHEEL_210_PHASE_COUNT]WheelStep210 {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count * WHEEL_210_PHASE_COUNT]WheelStep210 = undefined;

    for (ADMISSIBLE_RESIDUES.list, 0..) |ar, ariIndex| {
        var number = ar;
        var k: usize = 1;
        @setEvalBranchQuota(1_000_000);
        for (0..WHEEL_210_PHASE_COUNT) |stepIndex| {
            const startNumber = number;
            number += ar;
            k += 1;
            var steps: usize = 1;
            while (!ADMISSIBLE_RESIDUES.check[number % WHEEL_CIRCUMFERENCE] or k % 7 == 0) {
                number += ar;
                k += 1;
                steps += 1;
            }
            // Wraps within THIS residue's own 48-entry block, never
            // into a different one - a huge-tier prime's own residue
            // class mod 30 never changes as its wheel-210 phase
            // advances (verified against primesieve's own wheel210
            // table: its `next` field never crosses a group boundary
            // either).
            const nextStepIndex = (stepIndex + 1) % WHEEL_210_PHASE_COUNT;
            wheelPatterns[ariIndex * WHEEL_210_PHASE_COUNT + stepIndex] = .{
                .bitMask = ~@as(Types.SIEVE_BUCKET_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[startNumber % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = @intCast(steps),
                .residueAddend = @intCast((number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE)),
                .nextWheelIndex210 = @intCast(ariIndex * WHEEL_210_PHASE_COUNT + nextStepIndex),
            };
        }
    }

    return wheelPatterns;
}
