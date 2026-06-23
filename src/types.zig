const std = @import("std");

pub const PRIME_TYPE = usize;

pub const SIEVE_TYPE = u8;

pub const SIEVE_TYPE_FULL_MASK = std.math.maxInt(SIEVE_TYPE);

pub const SIEVE_TYPE_SHIFT_TYPE = std.math.Log2Int(SIEVE_TYPE);

pub const SievePrime = struct {
    currentSieveIndex: usize,
    initialSieveIndex: u29,
    wheelStepIndex: u3,
};

comptime {
    std.debug.assert(@sizeOf(SievePrime) == 16);
}
