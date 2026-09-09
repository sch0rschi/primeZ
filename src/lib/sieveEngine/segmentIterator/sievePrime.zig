const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");

pub const SievePrime = struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,

    /// Builds a SievePrime for the (bucketIndex, inBucketIndex)-encoded
    /// prime, targeting its first admissible multiple that is >=
    /// minRawNumberInclusive (never below prime^2 - smaller multiples are
    /// always already handled by smaller sieving primes). Discovery always
    /// finds primes via a 0-based scan (see SegmentIterator's nested
    /// sieving-prime discovery), but the target this prime is first needed
    /// at is computed directly relative to whatever range-start the caller
    /// actually asked for - passing 0 here reduces to "first needed at
    /// prime^2", the every-day case. There is deliberately no separate
    /// "discover relative to 0, then re-seed relative to the real start"
    /// step: computing the real target once, at discovery time, is exactly
    /// as cheap as computing a throwaway one relative to 0 would have been
    /// - see project memory huge_tier_bucket_list_idea for the history of
    /// why this used to be a two-step process.
    pub fn from(bucketIndex: usize, inBucketIndex: u3, minRawNumberInclusive: usize) SievePrime {
        const prime =
            Utils.admissibleNumberFromBitIndex(@bitSizeOf(Types.SIEVE_BUCKET_TYPE) * bucketIndex + inBucketIndex);
        const target = firstAdmissibleMultiple(prime, minRawNumberInclusive);

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
