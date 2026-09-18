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
