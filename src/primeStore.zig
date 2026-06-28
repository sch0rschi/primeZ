const std = @import("std");

const SegmentIterator = @import("segmentIterator.zig").SegmentIterator;
const Types = @import("types.zig");
const Utils = @import("utils.zig");
const Comptimes = @import("comptimes.zig");
const PrimeCheck = @import("primeCheck.zig");
const Estimates = @import("estimates.zig");

const ALIGNMENT = std.mem.Alignment.@"8";

pub const PrimeStore = struct {
    allocator: std.mem.Allocator,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    upperBoundQuery: Types.PRIME_TYPE,
    primes: ?[]Types.PRIME_TYPE = null,

    /// Initializes a prime store that yiu can query (.isPrime(n), ... TODO).
    /// It is guaranteed, that the number lowerLimitInclusive is included in the prime store for fast querying.
    pub fn initForQueries(allocator: std.mem.Allocator, lowerLimitInclusive: usize) !PrimeStore {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(lowerLimitInclusive));
        const buckets = try allocator.alignedAlloc(Types.SIEVE_BUCKET_TYPE, ALIGNMENT, bucketsLength);
        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));
        var segmentIterator = try SegmentIterator.init(allocator, lowerLimitInclusive);
        defer segmentIterator.deinit();
        while (try segmentIterator.next()) |segment| {
            @memcpy(containers[segment.containerStart..segment.containerEndExclusive], segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]);
        }

        return PrimeStore{
            .allocator = allocator,
            .buckets = buckets,
            .upperBoundQuery = buckets.len * Comptimes.WHEEL_CIRCUMFERENCE,
        };
    }

    /// Initializes a prime store that yiu can query (.isPrime(n), ... TODO).
    /// It is guaranteed, that the number lowerLimitInclusive is included in the prime store for fast querying.
    /// In addition you get an array of sorted prime numbers via getPrimes(), where the last element is primesLimitInclusive.
    pub fn initForQueriesAndPrimes(allocator: std.mem.Allocator, queryLowerLimitInclusive: usize, primesLimitInclusive: usize) !PrimeStore {
        const bucketsLength = ALIGNMENT.forward(Utils.getSieveLength(queryLowerLimitInclusive));
        const buckets = try allocator.alignedAlloc(Types.SIEVE_BUCKET_TYPE, ALIGNMENT, bucketsLength);
        const containers: Types.SIEVE_CONTAINERS_TYPE = std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(buckets));

        const amountUpperBound = Estimates.primeCountUpperBound(primesLimitInclusive);
        var primes = try std.ArrayList(Types.PRIME_TYPE).initCapacity(allocator, amountUpperBound);
        try primes.appendSlice(allocator, &Comptimes.WHEEL_PRIMES);

        var segmentIterator = try SegmentIterator.init(allocator, @max(queryLowerLimitInclusive, primesLimitInclusive));
        defer segmentIterator.deinit();
        outer: while (try segmentIterator.next()) |segment| {
            if (segment.containerStart < containers.len) {
                const copyLength = @min(segment.containerEndExclusive - segment.containerStart, containers.len - segment.containerStart);
                @memcpy(containers[segment.containerStart..segment.containerStart + copyLength], segment.containers[0 .. copyLength]);
            }
            for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
                var containerWorkingCopy: u64 = container;
                while (containerWorkingCopy > 0) {
                    const inBucketIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                    const prime = Utils.admissibleNumberFromBitIndex(64 * containerIndex + inBucketIndex);
                    if (prime > primesLimitInclusive) {
                        continue :outer;
                    }
                    try primes.append(allocator, prime);
                    containerWorkingCopy &= containerWorkingCopy - 1;
                }
            }
        }

        return PrimeStore{
            .allocator = allocator,
            .buckets = buckets,
            .upperBoundQuery = buckets.len * Comptimes.WHEEL_CIRCUMFERENCE,
            .primes = try primes.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *PrimeStore) void {
        self.allocator.free(self.buckets);
        if (self.primes) |primes| {
            self.allocator.free(primes);
        }
        self.primes = undefined;
        self.* = undefined;
    }

    pub fn isPrime(self: PrimeStore, maybePrime: Types.PRIME_TYPE) bool {
        if (maybePrime < 2) return false;
        if (maybePrime == 2 or maybePrime == 3 or maybePrime == 5) return true;
        if (maybePrime % 2 == 0 or maybePrime % 3 == 0 or maybePrime % 5 == 0) return false;

        if (maybePrime > self.upperBoundQuery) {
            return PrimeCheck.isPrime(maybePrime);
        }

        const bucketDiv = maybePrime / Comptimes.WHEEL_CIRCUMFERENCE;
        const bucketMod = maybePrime % Comptimes.WHEEL_CIRCUMFERENCE;
        return self.buckets[bucketDiv] >>
            @as(u3, @intCast(Comptimes.ADMISSIBLE_RESIDUES.reverseMap[bucketMod])) & 1 != 0;
    }

    pub fn getPrimes(self: PrimeStore) ![]Types.PRIME_TYPE {
        return self.primes.?;
    }
};
