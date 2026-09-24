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
    _reserved: u8 = 0,
};

pub const WHEEL_PATTERNS: [ADMISSIBLE_RESIDUES.count][ADMISSIBLE_RESIDUES.count]WheelStep = buildWheelPatterns();

const WHEEL_PRIMES_2310 = WHEEL_PRIMES ++ [_]usize{ 7, 11 };
pub const WHEEL_CIRCUMFERENCE_2310: comptime_int = WHEEL_CIRCUMFERENCE * 7 * 11;
const ADMISSIBLE_RESIDUES_2310_COUNT: comptime_int = computeAdmissibleResidueCount2310();

pub const AdmissibleResidues2310 = struct {
    count: comptime_int,
    check: [WHEEL_CIRCUMFERENCE_2310]bool,
    list: [ADMISSIBLE_RESIDUES_2310_COUNT]usize,
    reverseMap: [WHEEL_CIRCUMFERENCE_2310]usize,
};

pub const ADMISSIBLE_RESIDUES_2310: AdmissibleResidues2310 = buildAdmissibleResidues2310();

pub const WheelStep2310 = extern struct {
    bitMask: u8,
    divMultiplicator: u8,
    residueAddend: u8,
    _pad: u8 = 0,
    nextWheelStepIndex2310Bits: u32,
};

pub const WHEEL_2310_INDEX_SHIFT = 23;

const WHEEL_2310_PHASE_COUNT = ADMISSIBLE_RESIDUES_2310.count;
pub const WHEEL_PATTERNS_2310: [ADMISSIBLE_RESIDUES.count * WHEEL_2310_PHASE_COUNT]WheelStep2310 = buildWheelPatterns2310();

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

fn computeAdmissibleResidueCount2310() comptime_int {
    @setEvalBranchQuota(100_000);
    var count: comptime_int = 0;
    for (0..WHEEL_CIRCUMFERENCE_2310) |r| {
        for (WHEEL_PRIMES_2310) |p| {
            if (r % p == 0) break;
        } else count += 1;
    }
    return count;
}

fn buildAdmissibleResidues2310() AdmissibleResidues2310 {
    @setEvalBranchQuota(100_000);
    var position: usize = 0;
    var admissibleCheck: [WHEEL_CIRCUMFERENCE_2310]bool = [_]bool{false} ** WHEEL_CIRCUMFERENCE_2310;
    var admissibleList: [ADMISSIBLE_RESIDUES_2310_COUNT]usize = undefined;
    var reverseMap: [WHEEL_CIRCUMFERENCE_2310]usize = undefined;

    for (0..WHEEL_CIRCUMFERENCE_2310) |r| {
        for (WHEEL_PRIMES_2310) |p| {
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

    return AdmissibleResidues2310{
        .count = ADMISSIBLE_RESIDUES_2310_COUNT,
        .check = admissibleCheck,
        .list = admissibleList,
        .reverseMap = reverseMap,
    };
}

fn buildWheelPatterns2310() [ADMISSIBLE_RESIDUES.count * WHEEL_2310_PHASE_COUNT]WheelStep2310 {
    var wheelPatterns: [ADMISSIBLE_RESIDUES.count * WHEEL_2310_PHASE_COUNT]WheelStep2310 = undefined;

    for (ADMISSIBLE_RESIDUES.list, 0..) |ar, ariIndex| {
        var number = ar;
        var k: usize = 1;
        @setEvalBranchQuota(10_000_000);
        for (0..WHEEL_2310_PHASE_COUNT) |stepIndex| {
            const startNumber = number;
            number += ar;
            k += 1;
            var steps: usize = 1;
            while (!ADMISSIBLE_RESIDUES.check[number % WHEEL_CIRCUMFERENCE] or k % 7 == 0 or k % 11 == 0) {
                number += ar;
                k += 1;
                steps += 1;
            }
            const nextStepIndex = (stepIndex + 1) % WHEEL_2310_PHASE_COUNT;
            wheelPatterns[stepIndex * ADMISSIBLE_RESIDUES.count + ariIndex] = .{
                .bitMask = ~@as(Types.SIEVE_BUCKET_TYPE, 1 << ADMISSIBLE_RESIDUES.reverseMap[startNumber % WHEEL_CIRCUMFERENCE]),
                .divMultiplicator = @intCast(steps),
                .residueAddend = @intCast((number / WHEEL_CIRCUMFERENCE) - (startNumber / WHEEL_CIRCUMFERENCE)),
                .nextWheelStepIndex2310Bits = @intCast(nextStepIndex << WHEEL_2310_INDEX_SHIFT),
            };
        }
    }

    return wheelPatterns;
}
