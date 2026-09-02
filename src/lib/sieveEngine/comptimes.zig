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
