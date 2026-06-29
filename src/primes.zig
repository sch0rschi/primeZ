const std = @import("std");

const Estimates = @import("estimates.zig");
const Comptimes = @import("comptimes.zig");
const Utils = @import("utils.zig");
const Types = @import("types.zig");
const SegmentIterator = @import("segmentIterator.zig").SegmentIterator;
const Pi = @import("pi.zig");

/// Computes the nth prime, zero indexed.
/// nthPrime(0) = 2.
/// nthPrime(1) = 3.
pub fn nthPrime(allocator: std.mem.Allocator, nth: usize) !Types.PRIME_TYPE {
    if (nth < Comptimes.WHEEL_PRIMES.len) {
        return Comptimes.WHEEL_PRIMES[nth];
    }

    const nthPrimeUpperBound = Estimates.nthPrimeUpperBound(nth);

    var segmentIterator = try SegmentIterator.init(allocator, nthPrimeUpperBound);
    defer segmentIterator.deinit();

    var primeCount: usize = 2;

    while (try segmentIterator.next()) |segment| {
        for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
            const primesInContainerCount = @popCount(container);
            if (primeCount + primesInContainerCount < nth) {
                primeCount += primesInContainerCount;
            } else {
                var containerWorkingCopy: u64 = container;
                for (0..nth - primeCount - 1) |_| { // removes all smaller primes from container
                    containerWorkingCopy &= containerWorkingCopy - 1;
                }
                const inBucketIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                return Utils.admissibleNumberFromBitIndex(64 * containerIndex + inBucketIndex);
            }
        }
    }

    unreachable;
}

/// get all primes with values at most limit.
/// The array is to be freed by the caller.
pub fn getPrimes(allocator: std.mem.Allocator, limit: Types.PRIME_TYPE) ![]Types.PRIME_TYPE {
    if (limit < 2) {
        return try allocator.alloc(Types.PRIME_TYPE, 0);
    } else if (limit < 3) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 1);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..1]);
        return primes;
    } else if (limit < 5) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 2);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..2]);
        return primes;
    } else if (limit < 7) {
        const primes = try allocator.alloc(Types.PRIME_TYPE, 3);
        @memcpy(primes, Comptimes.WHEEL_PRIMES[0..3]);
        return primes;
    }
    const amountUpperBound = Estimates.primeCountUpperBound(limit);
    var primes = try std.ArrayList(Types.PRIME_TYPE).initCapacity(allocator, amountUpperBound);
    try primes.appendSlice(allocator, &Comptimes.WHEEL_PRIMES);

    var segmentIterator = try SegmentIterator.init(allocator, limit);
    defer segmentIterator.deinit();

    outer: while (try segmentIterator.next()) |segment| {
        for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
            var containerWorkingCopy: u64 = container;
            while (containerWorkingCopy > 0) {
                const inBucketIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                const prime = Utils.admissibleNumberFromBitIndex(64 * containerIndex + inBucketIndex);
                if (prime > limit) {
                    break :outer;
                }
                try primes.append(allocator, prime);
                containerWorkingCopy &= containerWorkingCopy - 1;
            }
        }
    }

    return try primes.toOwnedSlice(allocator);
}

/// Sums all primes with values at most limit.
pub fn sumPrimes(allocator: std.mem.Allocator, limit: Types.PRIME_TYPE) !Types.PRIME_TYPE {
    if (limit < 2) {
        return 0;
    } else if (limit < 3) {
        return 2;
    } else if (limit < 5) {
        return 5;
    } else if (limit < 7) {
        return 10;
    }
    var sum: Types.PRIME_TYPE = 10; // 2 + 3 + 5

    var segmentIterator = try SegmentIterator.init(allocator, limit);
    defer segmentIterator.deinit();

    outer: while (try segmentIterator.next()) |segment| {
        for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
            var containerWorkingCopy: u64 = container;
            while (containerWorkingCopy > 0) {
                const inBucketIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                const prime = Utils.admissibleNumberFromBitIndex(64 * containerIndex + inBucketIndex);
                if (prime > limit) {
                    break :outer;
                }
                sum += prime;
                containerWorkingCopy &= containerWorkingCopy - 1;
            }
        }
    }

    return sum;
}

pub fn pi(allocator: std.mem.Allocator, x: u64) !usize {
    return try Pi.pi(allocator, x);
}
