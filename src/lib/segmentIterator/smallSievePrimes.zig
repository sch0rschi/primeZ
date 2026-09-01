const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const config = @import("primeZConfig");

const SievePrimeMod = @import("sievePrime.zig");
const SievePrime = SievePrimeMod.SievePrime;
const applySievePrimeIntoSegment = SievePrimeMod.applySievePrimeIntoSegment;

pub const STRIPE_ELEMS: usize = @as(usize, 1024) * @min(config.l1_cache_size_in_kb, config.opt_segment_size_in_kb);

pub const SmallSievePrimes = struct {
    map: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime),
    activeCounts: [Comptimes.ADMISSIBLE_RESIDUES.count]usize,

    pub fn init(allocator: std.mem.Allocator) !SmallSievePrimes {
        var map: [Comptimes.ADMISSIBLE_RESIDUES.count]std.ArrayList(SievePrime) = undefined;
        for (&map) |*list| {
            list.* = try std.ArrayList(SievePrime).initCapacity(allocator, 0);
        }

        return SmallSievePrimes{
            .map = map,
            .activeCounts = .{0} ** Comptimes.ADMISSIBLE_RESIDUES.count,
        };
    }

    pub fn deinit(self: *SmallSievePrimes, allocator: std.mem.Allocator) void {
        for (&self.map) |*list| {
            list.deinit(allocator);
        }
    }

    pub fn add(
        self: *SmallSievePrimes,
        allocator: std.mem.Allocator,
        comptime inBucketIndex: u3,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
        sievePrime: SievePrime,
    ) !void {
        var registered = sievePrime;
        if (registered.currentBucketIndex < bucketsEndExclusive) {
            applySievePrimeIntoSegment(inBucketIndex, buckets, bucketsStart, bucketsEndExclusive, &registered);
        }
        try self.map[inBucketIndex].append(allocator, registered);
    }

    pub fn activate(self: *SmallSievePrimes, bucketsEndExclusive: usize) void {
        for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
            const pending = self.map[ari].items[self.activeCounts[ari]..];
            for (pending) |sievePrime| {
                if (sievePrime.currentBucketIndex < bucketsEndExclusive) {
                    self.activeCounts[ari] += 1;
                } else {
                    break;
                }
            }
        }
    }

    pub noinline fn apply(
        self: *SmallSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        var stripeEnd = bucketsStart;
        while (stripeEnd < bucketsEndExclusive) {
            stripeEnd = @min(stripeEnd + STRIPE_ELEMS, bucketsEndExclusive);

            inline for (0..Comptimes.ADMISSIBLE_RESIDUES.count) |ari| {
                for (self.map[ari].items[0..self.activeCounts[ari]]) |*sievePrime| {
                    if (sievePrime.currentBucketIndex < stripeEnd) {
                        applySievePrimeIntoSegment(ari, buckets, bucketsStart, stripeEnd, sievePrime);
                    }
                }
            }
        }
    }
};
