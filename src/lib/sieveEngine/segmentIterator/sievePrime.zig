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

pub fn firstAdmissibleMultiple(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple {
    const k0 = if (minRawNumberInclusive == 0) prime else @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    const r = k0 % Comptimes.WHEEL_CIRCUMFERENCE;
    const wheelStepIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[r];
    const k = k0 + (Comptimes.ADMISSIBLE_RESIDUES.list[wheelStepIndex] - r);

    const multiple = prime * k;
    return .{
        .bucketIndex = multiple / Comptimes.WHEEL_CIRCUMFERENCE,
        .wheelStepIndex = @intCast(wheelStepIndex),
    };
}

pub const AdmissibleMultiple210 = struct {
    bucketIndex: usize,
    wheelStepIndex210: u6,
};

pub fn firstAdmissibleMultiple210(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple210 {
    const k0 = if (minRawNumberInclusive == 0) prime else @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    const r = k0 % Comptimes.WHEEL_CIRCUMFERENCE_210;
    const wheelStepIndex210 = Comptimes.ADMISSIBLE_RESIDUES_210.reverseMap[r];
    const k = k0 + (Comptimes.ADMISSIBLE_RESIDUES_210.list[wheelStepIndex210] - r);

    const multiple = prime * k;
    return .{
        .bucketIndex = multiple / Comptimes.WHEEL_CIRCUMFERENCE,
        .wheelStepIndex210 = @intCast(wheelStepIndex210),
    };
}

pub const LargeSievePrime = packed struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex210: u6,

    pub fn fromTarget210(target: AdmissibleMultiple210, bucketIndex: usize, inBucketIndex: u3) LargeSievePrime {
        return LargeSievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex210 = target.wheelStepIndex210,
        };
    }
};

pub const LargeSievePrimeSlot = packed struct {
    localOffset: u23,
    wheelIndex210: u9,
    initialBucketIndex: u32,
};

pub const PreLargeRingEntry = packed struct {
    localOffset: u23,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,
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
