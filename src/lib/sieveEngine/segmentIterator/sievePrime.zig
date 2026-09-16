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

/// Finds the first admissible (coprime-to-30) multiple of `prime` that is
/// >= max(prime^2, minRawNumberInclusive), and the wheelStepIndex it
/// resumes at. ADMISSIBLE_RESIDUES.reverseMap[r] is the index of the
/// smallest admissible residue >= r, so this is a single table lookup
/// instead of a scan. The resuming wheelStepIndex is reverseMap[k % 30],
/// not reverseMap[(prime*k) % 30]: WHEEL_PATTERNS' 8-entry rows are
/// indexed by the k-th admissible k-value, which repeats mod 30 with
/// period 8 regardless of prime.
pub fn firstAdmissibleMultiple(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple {
    // divCeil(0, prime) is always 0 (prime >= 1), making @max(prime, ...)
    // always just `prime` - a real, wasted division on every call with
    // minRawNumberInclusive == 0 (every self-registration, plus every
    // real registration in a from-zero query). Skip it explicitly rather
    // than let the CPU compute and discard a division prime doesn't
    // divide evenly into.
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

/// Wheel-210 analog of firstAdmissibleMultiple (huge tier only): resumes
/// within the 48-long wheel-210 cycle instead of the 8-long wheel-30 one.
/// bucketIndex still lands in wheel-30 units - the sieve array itself is
/// always wheel-30, only the stepping sequence changes.
pub fn firstAdmissibleMultiple210(prime: usize, minRawNumberInclusive: usize) AdmissibleMultiple210 {
    // See firstAdmissibleMultiple's identical fast path above.
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

/// Huge-tier-only sieving-prime record: a separate type from SievePrime so
/// small/medium/large's u3 wheelStepIndex and its free wraparound at 8
/// stay untouched by wheel-210's wider 48-phase index.
pub const HugeSievePrime = packed struct {
    currentBucketIndex: usize,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex210: u6,

    pub fn fromTarget210(target: AdmissibleMultiple210, bucketIndex: usize, inBucketIndex: u3) HugeSievePrime {
        return HugeSievePrime{
            .currentBucketIndex = target.bucketIndex,
            .initialBucketIndex = @intCast(bucketIndex),
            .initialInBucketIndex = inBucketIndex,
            .wheelStepIndex210 = target.wheelStepIndex210,
        };
    }
};

/// Ring/Block-resident encoding of a huge-tier sieving prime (see
/// hugeSievePrimes.zig). Stores only the LOCAL offset within whichever
/// future segment this entry is filed to, not a full absolute position -
/// which segment it belongs to is already implicit in which ring
/// slot/Block holds it. `localOffset: u23` covers any buildable
/// SEGMENT_ELEMS (build.zig caps it at 2^23 - see hugeSievePrimes.zig's
/// comptime assertion). 23+32+3+6 = 64 bits exactly, half of
/// HugeSievePrime's own packed size - this type is only ever built once a
/// ring slot is already known (HugeSievePrimes.list, not yet placed,
/// still uses the wider HugeSievePrime).
pub const HugeSievePrimeSlot = packed struct {
    localOffset: u23,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex210: u6,
};

/// Ring/Block-resident encoding of a preHuge-tier sieving prime (see
/// preHugeSievePrimes.zig) - the same "which ring slot holds an entry
/// already tells you its segment" idea as HugeSievePrimeSlot, but for
/// this tier's own wheel-30 stepping (8 phases, u3) instead of huge's
/// wheel-210 (48 phases, u6). Unlike this type's predecessor
/// (LargeHeadCompactSievePrime, a maps/mapsSwap-resident encoding with
/// its own `segmentsAhead` counter, removed with the ring rewrite), no
/// segmentsAhead field is needed at all: the ring slot itself is that
/// information now, exactly as for HugeSievePrimeSlot.
pub const PreHugeRingEntry = packed struct {
    localOffset: u23,
    initialBucketIndex: u32,
    initialInBucketIndex: u3,
    wheelStepIndex: u3,
};

/// Compact steady-state encoding for SmallSievePrimes' own `active` array
/// (see smallSievePrimes.zig) - no segmentsAhead counter needed at all,
/// unlike LargeHeadCompactSievePrime: a small-tier prime's own threshold
/// guarantees its step is always tiny relative to a stripe, so once
/// active it fires on literally every subsequent stripe/segment call,
/// forever - `localOffset` gets freshly rewritten on every touch as a
/// side effect of that, with a single conditional `-= SEGMENT_ELEMS`
/// folded into the same write whenever a step's exit crosses a segment
/// boundary (see applyCompactSievePrimeIntoSegment's docstring - this is
/// NOT the same recurring "rebase every non-firing touch" cost that
/// already failed for medium/large, since small-tier entries essentially
/// never have a non-firing touch once active). Also drops
/// `initialInBucketIndex` entirely (unlike every other compact type
/// here) - always redundant for this tier specifically, since an entry's
/// residue is already implicit in which of the 8 per-residue arrays
/// holds it. 23+32+3 = 58 bits, 8 bytes packed.
pub const SmallCompactSievePrime = packed struct {
    localOffset: u23,
    initialBucketIndex: u32,
    wheelStepIndex: u3,
};
