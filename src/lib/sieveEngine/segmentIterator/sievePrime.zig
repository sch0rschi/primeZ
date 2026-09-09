const Comptimes = @import("../comptimes.zig");
const Utils = @import("../utils.zig");

pub const SievePrime = struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,

    /// Builds a SievePrime for the (bucketIndex, inBucketIndex)-encoded
    /// prime (its own numeric value passed in as `prime` - the caller
    /// already has it, from the very same bit-scan that produced
    /// bucketIndex/inBucketIndex, to classify which tier it belongs in and
    /// check PreSieve.isPreSieved - recomputing it here via
    /// admissibleNumberFromBitIndex would be a second division-plus-lookup
    /// for no reason), targeting its first admissible multiple that is >=
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
    pub fn from(prime: usize, bucketIndex: usize, inBucketIndex: u3, minRawNumberInclusive: usize) SievePrime {
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
/// gcd(k, 30)) - so we need the smallest admissible k >= minK. Rather than
/// a runtime scan (this used to be a `while` loop advancing k one step at
/// a time until ADMISSIBLE_RESIDUES.check[k % 30] - profiled as the single
/// hottest cost in a huge-magnitude range-start query, likely branch
/// mispredicts from the data-dependent early-out, see project memory
/// huge_tier_bucket_list_idea) this is a single table lookup:
/// ADMISSIBLE_RESIDUES.reverseMap[r] is already, by construction (see
/// buildAdmissibleResidues), the index of the smallest admissible residue
/// >= r within [0, WHEEL_CIRCUMFERENCE) - true whether r itself is
/// admissible or not, and never needs to wrap into the next cycle because
/// WHEEL_CIRCUMFERENCE - 1 is always admissible (gcd(n, n-1) == 1 for any
/// n, so the wheel's own top residue is always coprime to it). So
/// ADMISSIBLE_RESIDUES.list[reverseMap[r]] - r is the exact delta to the
/// next admissible k, in one lookup instead of an unbounded-looking scan.
///
/// The resuming wheelStepIndex is reverseMap[k % 30], not
/// reverseMap[(prime*k) % 30]: WHEEL_PATTERNS' 8-entry rows are indexed by
/// the k-th admissible k-value (not by the composite's own residue) - this
/// holds for any k because admissible k's repeat mod 30 with period 8 (the
/// (k+8)-th admissible k is exactly the k-th plus 30, so prime*k's residue
/// mod 30 repeats every 8 admissible k's too). The prime^2 case (k = prime)
/// is just this same formula with minRawNumberInclusive = 0.
fn firstAdmissibleMultiple(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple {
    const k0 = @max(prime, Utils.divCeil(minRawNumberInclusive, prime));
    const r = k0 % Comptimes.WHEEL_CIRCUMFERENCE;
    const wheelStepIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[r];
    const k = k0 + (Comptimes.ADMISSIBLE_RESIDUES.list[wheelStepIndex] - r);

    const multiple = prime * k;
    return .{
        .bucketIndex = multiple / Comptimes.WHEEL_CIRCUMFERENCE,
        .wheelStepIndex = @intCast(wheelStepIndex),
    };
}
