const std = @import("std");

pub const PRIME_TYPE = usize;

pub const SIEVE_BUCKET_TYPE = u8;

pub const SIEVE_BUCKETS_TYPE = []align(8) SIEVE_BUCKET_TYPE;

pub const SIEVE_CONTAINER_TYPE = u64;

pub const SIEVE_CONTAINERS_TYPE = []align(8) SIEVE_CONTAINER_TYPE;

pub const SIEVE_TYPE_FULL_MASK = std.math.maxInt(SIEVE_BUCKET_TYPE);

pub const SIEVE_TYPE_SHIFT_TYPE = std.math.Log2Int(SIEVE_BUCKET_TYPE);
