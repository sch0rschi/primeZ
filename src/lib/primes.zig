const std = @import("std");

const Estimates = @import("estimates.zig");
const Comptimes = @import("sieveEngine/comptimes.zig");
const Utils = @import("sieveEngine/utils.zig");
const Types = @import("sieveEngine/types.zig");
const SegmentIterator = @import("sieveEngine/segmentIterator/root.zig").SegmentIterator;
const Pi = @import("pi.zig");
const LayoutMod = @import("sieveEngine/layout.zig");

pub fn nthPrime(allocator: std.mem.Allocator, nth: usize) !Types.PRIME_TYPE {
    if (nth < Comptimes.WHEEL_PRIMES.len) {
        return Comptimes.WHEEL_PRIMES[nth];
    }

    const nthPrimeUpperBound = Estimates.nthPrimeUpperBound(nth);

    var segmentIterator = try SegmentIterator.initDefault(allocator, 0, nthPrimeUpperBound);
    defer segmentIterator.deinit();

    var primeCount: usize = 2;

    while (try segmentIterator.next()) |segment| {
        for (segment.containerStart..segment.containerEndExclusive, segment.containers[0 .. segment.containerEndExclusive - segment.containerStart]) |containerIndex, container| {
            const primesInContainerCount = @popCount(container);
            if (primeCount + primesInContainerCount < nth) {
                primeCount += primesInContainerCount;
            } else {
                var containerWorkingCopy: u64 = container;
                for (0..nth - primeCount - 1) |_| {
                    containerWorkingCopy &= containerWorkingCopy - 1;
                }
                const inBucketIndex: u6 = @intCast(@ctz(containerWorkingCopy));
                return Utils.admissibleNumberFromBitIndex(64 * containerIndex + inBucketIndex);
            }
        }
    }

    unreachable;
}

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

    var segmentIterator = try SegmentIterator.initDefault(allocator, 0, limit);
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
    var sum: Types.PRIME_TYPE = 10;

    var segmentIterator = try SegmentIterator.initDefault(allocator, 0, limit);
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

pub fn piSieveCounting(allocator: std.mem.Allocator, start: u64, limit: u64) !usize {
    return piSieveCountingWithLayouts(allocator, start, limit, LayoutMod.layoutsForQuery(limit));
}

pub fn piSieveCountingWithLayouts(allocator: std.mem.Allocator, start: u64, limit: u64, layouts: LayoutMod.QueryLayouts) !usize {
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

    var segmentIterator = try SegmentIterator.init(allocator, sieveFrom, limit, layouts);
    defer segmentIterator.deinit();

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
