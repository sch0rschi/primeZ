const std = @import("std");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");

pub const SievePrime = packed struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,

    pub fn from(prime: usize, bucketIndex: usize, inBucketIndex: u3, minRawNumberInclusive: usize) SievePrime {
        const target = firstAdmissibleMultiple(prime, minRawNumberInclusive);
        return fromTarget(target, bucketIndex, inBucketIndex);
    }

    pub fn fromTarget(target: AdmissibleMultiple, bucketIndex: usize, inBucketIndex: u3) SievePrime {
        return SievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex = target.wheelStepIndex,
        };
    }
};

pub fn lessThanByCurrentBucketIndex(_: void, a: SievePrime, b: SievePrime) bool {
    return a.currentBucketIndex < b.currentBucketIndex;
}

pub const AdmissibleMultiple = struct {
    bucketIndex: usize,
    wheelStepIndex: u3,
};

fn bucketIndexOfMultiple(prime: usize, k: usize) usize {
    const multiple, const overflowed = @mulWithOverflow(prime, k);
    if (overflowed != 0) return std.math.maxInt(usize);
    return multiple / Comptimes.WHEEL_CIRCUMFERENCE;
}

pub fn firstAdmissibleMultiple(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple {
    const k0 = if (minRawNumberInclusive == 0) prime else @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    const r = k0 % Comptimes.WHEEL_CIRCUMFERENCE;
    const wheelStepIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[r];
    const k = k0 + (Comptimes.ADMISSIBLE_RESIDUES.list[wheelStepIndex] - r);

    return .{
        .bucketIndex = bucketIndexOfMultiple(prime, k),
        .wheelStepIndex = @intCast(wheelStepIndex),
    };
}

pub const AdmissibleMultiple2310 = struct {
    bucketIndex: usize,
    wheelStepIndex2310: u9,
};

pub fn firstAdmissibleMultiple2310(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple2310 {
    const k0 = if (minRawNumberInclusive == 0) prime else @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    const r = k0 % Comptimes.WHEEL_CIRCUMFERENCE_2310;
    const wheelStepIndex2310 = Comptimes.ADMISSIBLE_RESIDUES_2310.reverseMap[r];
    const k = k0 + (Comptimes.ADMISSIBLE_RESIDUES_2310.list[wheelStepIndex2310] - r);

    return .{
        .bucketIndex = bucketIndexOfMultiple(prime, k),
        .wheelStepIndex2310 = @intCast(wheelStepIndex2310),
    };
}

pub const LargeSievePrime = packed struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex2310: u9,

    pub fn fromTarget2310(target: AdmissibleMultiple2310, bucketIndex: usize, inBucketIndex: u3) LargeSievePrime {
        return LargeSievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex2310 = target.wheelStepIndex2310,
        };
    }
};

pub const LargeSievePrimeSlot = extern struct {
    localOffsetAndWheelStepIndex2310: u32,
    initialBucketIndexAndInBucketIndex: u32,
};

pub const MediumBucketSievePrime = struct {
    localOffset: u32,
    initialBucketIndex: u32,
};

pub const SmallStrideCompactSievePrime = packed struct {
    localOffset: u23,
    initialBucketIndex: u32,
    wheelStepIndex: u3,
};
