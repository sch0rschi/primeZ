const std = @import("std");

const SegmentIterator = @import("segmentIterator.zig").SegmentIterator;
const Types = @import("types.zig");
const Utils = @import("utils.zig");
const Comptimes = @import("comptimes.zig");
const PrimeCheck = @import("primeCheck.zig");

const ALIGNMENT = std.mem.Alignment.@"8";

pub const PrimeStore = struct {
    allocator: std.mem.Allocator,
    buckets: Types.SIEVE_BUCKETS_TYPE,
    upperBound: Types.PRIME_TYPE,

    pub fn init(allocator: std.mem.Allocator, lowerLimitInclusive: usize) !PrimeStore {
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
            .upperBound = buckets.len * Comptimes.WHEEL_CIRCUMFERENCE,
        };
    }

    pub fn deinit(self: *PrimeStore) void {
        self.allocator.free(self.buckets);
    }

    pub fn isPrime(self: *PrimeStore, maybePrime: Types.PRIME_TYPE) bool {
        if (maybePrime == 2 or maybePrime == 3 or maybePrime == 5) {
            return true;
        }
        if (maybePrime > self.upperBound) {
            return PrimeCheck.isPrime(maybePrime);
        }
        const bucketDiv = maybePrime / Comptimes.WHEEL_CIRCUMFERENCE;
        const bucketMod = maybePrime % Comptimes.WHEEL_CIRCUMFERENCE;
        if (!Comptimes.ADMISSIBLE_RESIDUES.check[bucketMod]) return false;
        return self.buckets[bucketDiv] >>
            @as(u3, @intCast(Comptimes.ADMISSIBLE_RESIDUES.reverseMap[bucketMod])) & 1 != 0;
    }
};
