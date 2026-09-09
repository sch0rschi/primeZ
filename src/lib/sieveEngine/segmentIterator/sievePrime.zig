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
        const target = firstAdmissibleMultiple(prime, 0);

        return SievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex = target.wheelStepIndex,
        };
    }

    /// Re-seeds this already-discovered SievePrime directly to the first
    /// admissible multiple of its own prime that is >= rangeStartInclusive
    /// (never below prime^2 - smaller multiples are always already handled
    /// by smaller sieving primes), computed in O(1)-ish arithmetic rather
    /// than by simulating every segment in between. Used by
    /// SegmentIterator's range-start support to jump straight from the end
    /// of sieving-prime discovery (always 0-based, see findSievePrimesInSegment)
    /// to an arbitrary requested start, without touching every skipped
    /// segment - see that file's docstring.
    pub fn fastForwardTo(self: SievePrime, rangeStartInclusive: usize) SievePrime {
        const prime = Utils.admissibleNumberFromBitIndex(
            @bitSizeOf(Types.SIEVE_BUCKET_TYPE) * self.initialBucketIndex + self.initialInBucketIndex,
        );
        const target = firstAdmissibleMultiple(prime, rangeStartInclusive);

        return SievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = self.initialBucketIndex,
            .initialInBucketIndex = self.initialInBucketIndex,
            .wheelStepIndex = target.wheelStepIndex,
        };
    }
};

pub fn lessThanByCurrentBucketIndex(_: void, a: SievePrime, b: SievePrime) bool {
    return a.currentBucketIndex < b.currentBucketIndex;
}

const AdmissibleMultiple = struct {
    bucketIndex: usize,
    wheelStepIndex: u3,
};

/// Finds the first admissible (coprime-to-30) multiple of `prime` that is
/// >= max(prime^2, minRawNumberInclusive), and the wheelStepIndex it
/// resumes at.
///
/// admissible multiples of `prime` correspond exactly to k where
/// gcd(k, 30) == 1 (since gcd(prime, 30) == 1, gcd(prime*k, 30) ==
/// gcd(k, 30)) - so the smallest admissible k >= minK is found by a
/// bounded scan (at most 29 steps, one admissible k in every run of 30).
/// The resuming wheelStepIndex is reverseMap[k % 30], not
/// reverseMap[(prime*k) % 30]: WHEEL_PATTERNS' 8-entry rows are indexed by
/// the k-th admissible k-value (not by the composite's own residue) - this
/// holds for any k because admissible k's repeat mod 30 with period 8 (the
/// (k+8)-th admissible k is exactly the k-th plus 30, so prime*k's residue
/// mod 30 repeats every 8 admissible k's too). The prime^2 case (k = prime)
/// is just this same formula with minRawNumberInclusive = 0.
fn firstAdmissibleMultiple(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple {
    var k = @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    while (!Comptimes.ADMISSIBLE_RESIDUES.check[k % Comptimes.WHEEL_CIRCUMFERENCE]) : (k += 1) {}

    const multiple = prime * k;
    return .{
        .bucketIndex = multiple / Comptimes.WHEEL_CIRCUMFERENCE,
        .wheelStepIndex = @intCast(Comptimes.ADMISSIBLE_RESIDUES.reverseMap[k % Comptimes.WHEEL_CIRCUMFERENCE]),
    };
}
