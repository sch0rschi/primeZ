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

// Shared by SmallSievePrimes.apply() and every class's add() - a freshly
// discovered prime always starts mid-wheel, regardless of size class.
pub inline fn applySievePrimeIntoSegment(
    comptime inBucketIndex: u3,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    bucketsStart: usize,
    bucketsEndExclusive: usize,
    sievePrime: *SievePrime,
) void {
    const wheelPattern = &Comptimes.WHEEL_PATTERNS[inBucketIndex];

    const bucketCount = bucketsEndExclusive - bucketsStart;
    const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
    const wheelStepIndex = @as(usize, sievePrime.wheelStepIndex);
    var currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;

    var concreteBucketAdvance: [Comptimes.ADMISSIBLE_RESIDUES.count]usize = undefined;
    var bucketAdvance7: usize = 0;
    @setEvalBranchQuota(1 << 20);
    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |step| {
        const stepAdvance = @as(usize, wheelPattern[step].divMultiplicator) * initialBucketIndex +
            @as(usize, wheelPattern[step].residueAddend);
        concreteBucketAdvance[step] = stepAdvance;
        bucketAdvance7 += stepAdvance;
    }
    bucketAdvance7 -=
        @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].divMultiplicator) * initialBucketIndex +
        @as(usize, wheelPattern[Comptimes.ADMISSIBLE_RESIDUES.count - 1].residueAddend);

    if (wheelStepIndex > 0) {
        if (currentBucketIndex + bucketAdvance7 < bucketCount) {
            inline for (1..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                if (wheelStepIndex <= ari) {
                    buckets[currentBucketIndex] &= wheelPattern[ari].bitMask;
                    currentBucketIndex += concreteBucketAdvance[ari];
                }
            }
        } else {
            inline for (1..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                if (wheelStepIndex <= ari) {
                    if (currentBucketIndex < bucketCount) {
                        buckets[currentBucketIndex] &= wheelPattern[ari].bitMask;
                        currentBucketIndex += concreteBucketAdvance[ari];
                    } else {
                        sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
                        sievePrime.wheelStepIndex = ari;
                        return;
                    }
                }
            }
        }
    }

    while (currentBucketIndex + bucketAdvance7 < bucketCount) {
        inline for (0.., wheelPattern) |si, wheelStep| {
            buckets[currentBucketIndex] &= wheelStep.bitMask;
            currentBucketIndex += concreteBucketAdvance[si];
        }
    }

    inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
        if (currentBucketIndex < bucketCount) {
            buckets[currentBucketIndex] &= wheelPattern[ari].bitMask;
            currentBucketIndex += concreteBucketAdvance[ari];
        } else {
            sievePrime.currentBucketIndex = currentBucketIndex + bucketsStart;
            sievePrime.wheelStepIndex = ari;
            return;
        }
    } else {
        unreachable;
    }
}
