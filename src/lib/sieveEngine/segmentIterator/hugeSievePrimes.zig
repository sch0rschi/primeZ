const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;

// Primes above LARGE_HUGE_THRESHOLD: even a single wheel step already
// exceeds a full segment, regardless of where within the segment the prime
// is currently positioned - see sieveLayoutMath.zig's largeHugeThreshold.
// So a huge sieving prime crosses off at most once per segment: no loop
// (a `while` would run 0 or 1 times, so an `if` suffices), and no benefit
// to batching several primes together the way largeSievePrimes.zig does to
// pipeline a loop's iterations - there is no loop to pipeline.
pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    activeCount: usize,

    pub fn init(allocator: std.mem.Allocator) !HugeSievePrimes {
        return HugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, 0),
            .activeCount = 0,
        };
    }

    pub fn deinit(self: *HugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn add(
        self: *HugeSievePrimes,
        allocator: std.mem.Allocator,
        sievePrime: SievePrime,
    ) !void {
        try self.list.append(allocator, sievePrime);
    }

    pub fn activate(self: *HugeSievePrimes, bucketsEndExclusive: usize) void {
        for (self.list.items[self.activeCount..]) |sievePrime| {
            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                self.activeCount += 1;
            } else {
                break;
            }
        }
    }

    pub noinline fn apply(
        self: *HugeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        for (self.list.items[0..self.activeCount]) |*sievePrime| {
            if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                const initialInBucketIndex = sievePrime.initialInBucketIndex;
                const wheelStepIndex = sievePrime.wheelStepIndex;
                const step = Comptimes.WHEEL_PATTERNS[initialInBucketIndex][wheelStepIndex];

                const currentBucketIndex = sievePrime.currentBucketIndex - bucketsStart;
                buckets[currentBucketIndex] &= step.bitMask;

                const initialBucketIndex = @as(usize, sievePrime.initialBucketIndex);
                const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
                sievePrime.currentBucketIndex = currentBucketIndex + advance + bucketsStart;
                sievePrime.wheelStepIndex = wheelStepIndex +% 1;
            }
        }
    }
};
