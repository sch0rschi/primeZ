const std = @import("std");

const Types = @import("types.zig");
const Comptimes = @import("comptimes.zig");
const Check = @import("../primeCheck.zig");
const BuildUtils = @import("buildUtils");
const PresieveGroups = BuildUtils.PresieveGroups;

const VEC_LEN = std.simd.suggestVectorLength(Types.SIEVE_BUCKET_TYPE) orelse 16;

const GROUPS = BuildUtils.PRESIEVE_GROUPS;

const GROUP_COUNT = GROUPS.len;

pub const PRIMES: [primeCount()]usize = flattenPrimes();

fn primeCount() usize {
    var count: usize = 0;
    for (GROUPS) |group| count += group.len;
    return count;
}

fn flattenPrimes() [primeCount()]usize {
    var result: [primeCount()]usize = undefined;
    var idx: usize = 0;
    for (GROUPS) |group| {
        for (group) |p| {
            result[idx] = p;
            idx += 1;
        }
    }
    return result;
}

pub const OVERRIDE_BUCKET_COUNT = computeOverrideBucketCount();

fn computeOverrideBucketCount() usize {
    var maxPrime: usize = 0;
    for (PRIMES) |p| maxPrime = @max(maxPrime, p);
    return maxPrime / Comptimes.WHEEL_CIRCUMFERENCE + 1;
}

pub const OVERRIDE_BUCKETS: [OVERRIDE_BUCKET_COUNT]Types.SIEVE_BUCKET_TYPE = computeOverrideBuckets();

fn computeOverrideBuckets() [OVERRIDE_BUCKET_COUNT]Types.SIEVE_BUCKET_TYPE {
    @setEvalBranchQuota(1 << 20);
    var buckets = [_]Types.SIEVE_BUCKET_TYPE{0} ** OVERRIDE_BUCKET_COUNT;
    var pp: usize = 1;
    while (pp < OVERRIDE_BUCKET_COUNT * Comptimes.WHEEL_CIRCUMFERENCE) : (pp += 1) {
        const mod = pp % Comptimes.WHEEL_CIRCUMFERENCE;
        if (Comptimes.ADMISSIBLE_RESIDUES.check[mod] and Check.isPrime(pp)) {
            const bucketIndex = pp / Comptimes.WHEEL_CIRCUMFERENCE;
            const inBucketIndex = Comptimes.ADMISSIBLE_RESIDUES.reverseMap[mod];
            buckets[bucketIndex] |=
                @as(Types.SIEVE_BUCKET_TYPE, 1) << @as(Types.SIEVE_TYPE_SHIFT_TYPE, @intCast(inBucketIndex));
        }
    }
    return buckets;
}

const PERIODS: [GROUP_COUNT]usize = blk: {
    var result: [GROUP_COUNT]usize = undefined;
    for (GROUPS, 0..) |primes, i| {
        result[i] = PresieveGroups.periodOf(primes);
    }
    break :blk result;
};

const PATTERNS: [GROUP_COUNT][]const Types.SIEVE_BUCKET_TYPE = blk: {
    var result: [GROUP_COUNT][]const Types.SIEVE_BUCKET_TYPE = undefined;
    var offset: usize = 0;
    for (PERIODS, 0..) |period, i| {
        result[i] = BuildUtils.PRESIEVE_PATTERNS_BLOB[offset..][0..period];
        offset += period;
    }
    if (offset != BuildUtils.PRESIEVE_PATTERNS_BLOB.len) {
        @compileError("presieve_patterns_blob length doesn't match GROUPS - regenerate (stale zig-cache?)");
    }
    break :blk result;
};

pub noinline fn fill(buckets: []Types.SIEVE_BUCKET_TYPE, bucketsStart: usize) void {
    var pos: [GROUP_COUNT]usize = undefined;
    inline for (0..GROUP_COUNT) |i| {
        pos[i] = bucketsStart % PERIODS[i];
    }

    var offset: usize = 0;
    while (offset < buckets.len) {
        var chunk = buckets.len - offset;
        inline for (0..GROUP_COUNT) |i| {
            chunk = @min(chunk, PERIODS[i] - pos[i]);
        }

        var j: usize = 0;
        while (j + VEC_LEN <= chunk) : (j += VEC_LEN) {
            var combined: @Vector(VEC_LEN, Types.SIEVE_BUCKET_TYPE) = @splat(std.math.maxInt(Types.SIEVE_BUCKET_TYPE));
            inline for (0..GROUP_COUNT) |i| {
                const v: @Vector(VEC_LEN, Types.SIEVE_BUCKET_TYPE) = PATTERNS[i][pos[i] + j ..][0..VEC_LEN].*;
                combined &= v;
            }
            buckets[offset + j ..][0..VEC_LEN].* = combined;
        }
        while (j < chunk) : (j += 1) {
            var combined: Types.SIEVE_BUCKET_TYPE = std.math.maxInt(Types.SIEVE_BUCKET_TYPE);
            inline for (0..GROUP_COUNT) |i| {
                combined &= PATTERNS[i][pos[i] + j];
            }
            buckets[offset + j] = combined;
        }

        offset += chunk;
        inline for (0..GROUP_COUNT) |i| {
            pos[i] += chunk;
            if (pos[i] >= PERIODS[i]) pos[i] = 0;
        }
    }
}

const MAX_PRESIEVE_PRIME: usize = blk: {
    var m: usize = 0;
    for (PRIMES) |p| m = @max(m, p);
    break :blk m;
};

pub fn isPreSieved(prime: usize) bool {
    return prime <= MAX_PRESIEVE_PRIME;
}
