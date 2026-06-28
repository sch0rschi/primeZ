// Because n has a known upper bound (u64::MAX), we can use a fixed,
// pre-computed table of witnesses instead of random ones. This gives
// a deterministic, exact answer (Pomerance, Selfridge, Wagstaff and
// Jaeschke in addition to Feitsma and Galway).
// See: https://en.wikipedia.org/wiki/Miller–Rabin_primality_test#Testing_against_small_sets_of_bases

const std = @import("std");
const Comptimes = @import("comptimes.zig");

fn modMulWithOverflow(a: u64, b: u64, m: u64) u64 {
    const aa: u128 = @intCast(a);
    const bb: u128 = @intCast(b);
    const mm: u128 = @intCast(m);
    return @intCast((aa * bb) % mm);
}

fn modMul(a: u64, b: u64, m: u64) u64 {
    const mulWithOverflow = @mulWithOverflow(a, b);
    if (mulWithOverflow[1] > 0) {
        return modMulWithOverflow(a, b, m);
    } else {
        return mulWithOverflow[0] % m;
    }
}

fn modSqr(a: u64, m: u64) u64 {
    if (a < (1 << 32)) {
        const r = a * a;
        if (r >= m) return r % m;
        return r;
    } else {
        return modMulWithOverflow(a, a, m);
    }
}

fn modExp(x_init: u64, d_init: u64, n: u64) u64 {
    var x = x_init;
    var d = d_init;
    var ret: u64 = 1;
    while (d != 0) {
        if (d % 2 == 1) {
            ret = modMul(ret, x, n);
        }
        d /= 2;
        x = modSqr(x, n);
    }
    return ret;
}

pub fn isPrime(maybePrime: u64) bool {
    if (maybePrime < 2) return false;
    if (maybePrime == 2 or maybePrime == 3 or maybePrime == 5) return true;
    if (maybePrime % 2 == 0 or maybePrime % 3 == 0 or maybePrime % 5 == 0) return false;

    const HINT = [_]u64{2};

    const WitnessSet = struct {
        hi: u64,
        bases: []const u64,
    };

    const WITNESSES = [_]WitnessSet{
        .{ .hi = 2_046, .bases = HINT[0..] },
        .{ .hi = 1_373_652, .bases = &[_]u64{ 2, 3 } },
        .{ .hi = 9_080_190, .bases = &[_]u64{ 31, 73 } },
        .{ .hi = 25_326_000, .bases = &[_]u64{ 2, 3, 5 } },
        .{ .hi = 4_759_123_140, .bases = &[_]u64{ 2, 7, 61 } },
        .{ .hi = 1_112_004_669_632, .bases = &[_]u64{ 2, 13, 23, 1662803 } },
        .{ .hi = 2_152_302_898_746, .bases = &[_]u64{ 2, 3, 5, 7, 11 } },
        .{ .hi = 3_474_749_660_382, .bases = &[_]u64{ 2, 3, 5, 7, 11, 13 } },
        .{ .hi = 341_550_071_728_320, .bases = &[_]u64{ 2, 3, 5, 7, 11, 13, 17 } },
        .{ .hi = 3_825_123_056_546_413_050, .bases = &[_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23 } },
        .{ .hi = std.math.maxInt(u64), .bases = &[_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 } },
    };

    if (maybePrime % 2 == 0) return maybePrime == 2;
    if (maybePrime == 1) return false;

    var d = maybePrime - 1;
    var s: u32 = 0;
    while (d % 2 == 0) {
        d /= 2;
        s += 1;
    }

    var witnesses: []const u64 = &[_]u64{};
    for (WITNESSES) |ws| {
        if (ws.hi >= maybePrime) {
            witnesses = ws.bases;
            break;
        }
    }

    outer: for (witnesses) |a| {
        var power = modExp(a, d, maybePrime);
        std.debug.assert(power < maybePrime);
        if (power == 1 or power == maybePrime - 1) continue :outer;

        var r: u32 = 0;
        while (r < s) : (r += 1) {
            power = modSqr(power, maybePrime);
            std.debug.assert(power < maybePrime);
            if (power == 1) return false;
            if (power == maybePrime - 1) continue :outer;
        }
        return false;
    }

    return true;
}
