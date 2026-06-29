const std = @import("std");

const Estimates = @import("estimates.zig");
const Types = @import("types.zig");
const Primes = @import("primes.zig");

const PhiCache = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(?Table),

    const EMPTY: u64 = std.math.maxInt(u64);

    const Table = struct {
        keys: []u64,
        vals: []u64,
        mask: u64,
        len: usize,
        cap: usize,

        fn init(allocator: std.mem.Allocator, size_pow2: u32) !Table {
            const size: usize = @as(usize, 1) << @intCast(size_pow2);
            const keys = try allocator.alloc(u64, size);
            const vals = try allocator.alloc(u64, size);
            @memset(keys, EMPTY);
            return Table{ .keys = keys, .vals = vals, .mask = size - 1, .len = 0, .cap = size };
        }

        fn deinit(self: *Table, allocator: std.mem.Allocator) void {
            allocator.free(self.keys);
            allocator.free(self.vals);
        }

        inline fn hashOf(x: u64) u64 {
            return x *% 0x9E3779B97F4A7C15;
        }

        fn get(self: *const Table, x: u64) ?u64 {
            var idx = (hashOf(x) >> 32) & self.mask;
            while (true) {
                const k = self.keys[idx];
                if (k == x) return self.vals[idx];
                if (k == EMPTY) return null;
                idx = (idx + 1) & self.mask;
            }
        }

        fn put(self: *Table, allocator: std.mem.Allocator, x: u64, v: u64) !void {
            // Grow before we get too full (load factor > ~0.7) to keep probe
            // chains short. Doubling is rare in steady state since most `a`
            // buckets are sized generously up front in ensureTable.
            if (self.len * 10 >= self.cap * 7) {
                try self.grow(allocator);
            }
            var idx = (hashOf(x) >> 32) & self.mask;
            while (true) {
                const k = self.keys[idx];
                if (k == x) {
                    self.vals[idx] = v;
                    return;
                }
                if (k == EMPTY) {
                    self.keys[idx] = x;
                    self.vals[idx] = v;
                    self.len += 1;
                    return;
                }
                idx = (idx + 1) & self.mask;
            }
        }

        fn grow(self: *Table, allocator: std.mem.Allocator) !void {
            const new_cap = self.cap * 2;
            const new_keys = try allocator.alloc(u64, new_cap);
            const new_vals = try allocator.alloc(u64, new_cap);
            @memset(new_keys, EMPTY);
            const new_mask = new_cap - 1;

            for (self.keys, self.vals) |k, v| {
                if (k == EMPTY) continue;
                var idx = (hashOf(k) >> 32) & new_mask;
                while (new_keys[idx] != EMPTY) {
                    idx = (idx + 1) & new_mask;
                }
                new_keys[idx] = k;
                new_vals[idx] = v;
            }

            allocator.free(self.keys);
            allocator.free(self.vals);
            self.keys = new_keys;
            self.vals = new_vals;
            self.mask = new_mask;
            self.cap = new_cap;
        }
    };

    fn init(allocator: std.mem.Allocator) !PhiCache {
        return .{ .allocator = allocator, .tables = try std.ArrayList(?Table).initCapacity(allocator, 0) };
    }

    fn deinit(self: *PhiCache) void {
        for (self.tables.items) |*maybe_table| {
            if (maybe_table.*) |*t| t.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
    }

    fn ensureTable(self: *PhiCache, a: usize) !*Table {
        while (self.tables.items.len <= a) {
            try self.tables.append(self.allocator, null);
        }
        if (self.tables.items[a] == null) {
            // Lower `a` is hit by far more distinct `x` values during recursion
            // (the tree is widest near the leaves), so give small `a` more room.
            // These are starting sizes; `grow()` handles any underestimate.
            const size_pow2: u32 = if (a <= 4) 18 else if (a <= 10) 15 else if (a <= 20) 11 else 7;
            self.tables.items[a] = try Table.init(self.allocator, size_pow2);
        }
        return &self.tables.items[a].?;
    }

    fn get(self: *PhiCache, x: u64, a: usize) ?u64 {
        if (a >= self.tables.items.len) return null;
        const t = self.tables.items[a] orelse return null;
        return t.get(x);
    }

    fn put(self: *PhiCache, x: u64, a: usize, v: u64) !void {
        const t = try self.ensureTable(a);
        try t.put(self.allocator, x, v);
    }
};

/// phi(x, a) = count of integers in [1, x] with no prime factor among the
/// first `a` primes (primes[0..a]).
fn phi(x: u64, a: usize, primes: []const u64, cache: *PhiCache) !u64 {
    if (a == 0) return x;
    if (x == 0) return 0;

    const p_a = primes[a - 1];

    // Short-circuit: if p_a > x, every integer in [1, x] except 1 itself has
    // already been excluded by some prime <= p_a (since x < p_a means no
    // multiple of p_a or larger primes fits below p_a anyway... more directly:
    // phi(x, a) counts numbers <= x coprime to primes[0..a]; once p_a > x,
    // phi(x, a) == phi(x, a-1) - phi(x/p_a, a-1) == phi(x,a-1) - 0 == ... but
    // the real shortcut is: once a is large enough that p_a > x, phi(x, a) = 1
    // for all x >= 1 (only the number 1 survives), because every n in [2, x]
    // has a prime factor <= x < p_a, hence <= p_{a-1}, so it was already
    // sieved out at a smaller index. This holds as long as a is the *current*
    // recursion depth, i.e. p_a is among the primes being divided out.
    if (p_a > x) return 1;

    // Closed form for a == 1: count of odd numbers <= x.
    if (a == 1) return x - x / 2;

    if (cache.get(x, a)) |cached| return cached;

    const left = try phi(x, a - 1, primes, cache);
    const right = try phi(x / p_a, a - 1, primes, cache);
    const result = left - right;

    try cache.put(x, a, result);
    return result;
}

/// Counts primes <= x using Legendre's formula with a memoized phi recursion.
/// pi(x) = phi(x, a) + a - 1, where a = pi(sqrt(x)).
///
/// This intentionally does NOT implement the P2/P3 correction terms (full
/// Meissel-Lehmer with a = pi(x^(1/3))). At the x ~ 1e10-1e12 range, the
/// extra sieve up to x^(2/3) required for P2 costs more than it saves; the
/// recursion here, with the array-based cache and the p_a > x short-circuit,
/// is fast enough in that range. Revisit if benchmarking x >= ~1e13+, where
/// the recursion blowup starts to outweigh the P2 sieve cost.
pub fn pi(allocator: std.mem.Allocator, x: u64) !usize {
    if (x < 2) {
        return 0;
    }

    const root = std.math.sqrt(x);
    const primes = try Primes.getPrimes(allocator, root);
    defer allocator.free(primes);

    const a: usize = primes.len;

    var cache = try PhiCache.init(allocator);
    defer cache.deinit();

    const phi_val = try phi(x, a, primes, &cache);

    const pi_x: u64 = phi_val + @as(u64, a) - 1;

    return @intCast(pi_x);
}