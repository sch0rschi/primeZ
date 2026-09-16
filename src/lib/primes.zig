const std = @import("std");

const Estimates = @import("estimates.zig");
const Comptimes = @import("sieveEngine/comptimes.zig");
const Utils = @import("sieveEngine/utils.zig");
const Types = @import("sieveEngine/types.zig");
const SegmentIterator = @import("sieveEngine/segmentIterator/root.zig").SegmentIterator;
const Pi = @import("pi.zig");

/// Computes the nth prime, zero indexed.
/// nthPrime(0) = 2.
/// nthPrime(1) = 3.
pub fn nthPrime(allocator: std.mem.Allocator, nth: usize) !Types.PRIME_TYPE {
    if (nth < Comptimes.WHEEL_PRIMES.len) {
        return Comptimes.WHEEL_PRIMES[nth];
    }

    const nthPrimeUpperBound = Estimates.nthPrimeUpperBound(nth);

    var segmentIterator = try SegmentIterator.init(allocator, 0, nthPrimeUpperBound);
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
    primes.appendSliceAssumeCapacity(&Comptimes.WHEEL_PRIMES);

    var segmentIterator = try SegmentIterator.init(allocator, 0, limit);
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
                primes.appendAssumeCapacity(prime);
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

    var segmentIterator = try SegmentIterator.init(allocator, 0, limit);
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

/// Counts primes in [start, limit] (both inclusive). start defaults to 0
/// for "count all primes up to limit" (pass 0 explicitly).
///
/// When start is far beyond limit's own sqrt, SegmentIterator skips
/// straight from the end of sieving-prime discovery to start's segment
/// instead of simulating every segment in between (see its own docstring)
/// - counting a narrow, huge-magnitude range is fast, not just a narrow
/// window into an otherwise full sieve from 0.
pub fn piSieveCounting(allocator: std.mem.Allocator, start: u64, limit: u64) !usize {
    if (limit < 2 or start > limit) {
        return 0;
    }

    var count: usize = 0;
    inline for (Comptimes.WHEEL_PRIMES) |p| {
        if (p >= start and p <= limit) count += 1;
    }

    const lastWheelPrime = Comptimes.WHEEL_PRIMES[Comptimes.WHEEL_PRIMES.len - 1];
    const sieveFrom = @max(start, lastWheelPrime + 1);
    if (sieveFrom > limit) {
        return count;
    }

    var segmentIterator = try SegmentIterator.init(allocator, sieveFrom, limit);
    defer segmentIterator.deinit();

    // Bits before sieveFrom's own admissible position must not be counted,
    // even within the first segment actually yielded (which - thanks to
    // SegmentIterator's container-alignment on jump - starts at most one
    // container's worth of admissible numbers before sieveFrom, but for a
    // small/no-jump range could be anywhere earlier in that segment).
    const precedingCount = if (sieveFrom == 0) 0 else Utils.admissibleCountUpTo(sieveFrom - 1);
    const headContainerIndex = precedingCount / 64;
    const headMask: Types.SIEVE_CONTAINER_TYPE = ~@as(Types.SIEVE_CONTAINER_TYPE, 0) << @intCast(precedingCount % 64);

    while (try segmentIterator.next()) |segment| {
        if (segment.containerStart <= headContainerIndex) {
            for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
                if (containerIndex < headContainerIndex) continue;
                const masked = if (containerIndex == headContainerIndex) container & headMask else container;
                count += @popCount(masked);
            }
        } else {
            count += collectSegmentCount(segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]);
        }
    }

    const lastContainerLocalIndex = (segmentIterator.bucketsEndExclusive - segmentIterator.bucketsStart) / 8 - 1;
    const lastContainer = segmentIterator.containers[lastContainerLocalIndex];

    const validBitCount = Utils.admissibleCountUpTo(limit);
    const lastContainerStartBit = segmentIterator.bucketsLength * 8 - 64;
    const excessStart = if (validBitCount > lastContainerStartBit) validBitCount - lastContainerStartBit else 0;
    if (excessStart < 64) {
        const tailMask: Types.SIEVE_CONTAINER_TYPE = ~@as(Types.SIEVE_CONTAINER_TYPE, 0) << @intCast(excessStart);
        count -= @popCount(lastContainer & tailMask);
    }

    return count;
}

noinline fn collectSegmentCount(containers: []const Types.SIEVE_CONTAINER_TYPE) usize {
    var count: usize = 0;
    for (containers) |container| {
        count += @popCount(container);
    }
    return count;
}

pub fn pi(allocator: std.mem.Allocator, x: u64) !usize {
    return try Pi.pi(allocator, x);
}
