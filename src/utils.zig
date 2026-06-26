const std = @import("std");

const Comptimes = @import("comptimes.zig");
const Types = @import("types.zig");

pub fn admissibleNumberFromBitIndex(bitIndex: usize) usize {
    const fullWheels = bitIndex / Comptimes.ADMISSIBLE_RESIDUES.count;
    const rem = bitIndex % Comptimes.ADMISSIBLE_RESIDUES.count;
    return fullWheels * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.ADMISSIBLE_RESIDUES.list[rem];
}

pub fn admissibleNumberToBitIndex(number: usize) usize {
    const div = number / Comptimes.WHEEL_CIRCUMFERENCE;
    const mod = number % Comptimes.WHEEL_CIRCUMFERENCE;
    std.debug.assert(Comptimes.ADMISSIBLE_RESIDUES.check[mod]);

    return div * Comptimes.ADMISSIBLE_RESIDUES.count + Comptimes.ADMISSIBLE_RESIDUES.reverseMap[mod];
}

pub fn getSieveLength(limitInclusive: usize) usize {
    return divCeil(limitInclusive * @sizeOf(Types.SIEVE_BUCKET_TYPE), Comptimes.WHEEL_CIRCUMFERENCE);
}

pub fn divCeil(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}

/// Returns the index of the least significant set bit in a bucket.
pub fn lsb(n: Types.SIEVE_BUCKET_TYPE) Types.SIEVE_TYPE_SHIFT_TYPE {
    return @as(Types.SIEVE_TYPE_SHIFT_TYPE, @intCast(@ctz(n)));
}

pub fn isMultipleOfWheelPrime(n: Types.PRIME_TYPE) bool {
    return !Comptimes.ADMISSIBLE_RESIDUES.check[n%Comptimes.WHEEL_CIRCUMFERENCE];
}
