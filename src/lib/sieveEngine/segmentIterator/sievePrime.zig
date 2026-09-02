const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");

pub const SievePrime = struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,

    pub fn from(bucketIndex: usize, inBucketIndex: u3) SievePrime {
        const prime =
            Utils.admissibleNumberFromBitIndex(@bitSizeOf(Types.SIEVE_BUCKET_TYPE) * bucketIndex + inBucketIndex);
        const primeSquareBitIndex = Utils.admissibleNumberToBitIndex(prime * prime);
        const primeSquareBucketIndex = primeSquareBitIndex / 8;

        const previousPrimeSquareMultipleMod = prime % Comptimes.WHEEL_CIRCUMFERENCE;
        const previousPrimeSquareWheelStepIndex =
            Comptimes.ADMISSIBLE_RESIDUES.reverseMap[previousPrimeSquareMultipleMod];

        return SievePrime{
            .currentBucketIndex = primeSquareBucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex = @intCast(previousPrimeSquareWheelStepIndex),
        };
    }
};
