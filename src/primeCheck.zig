const std = @import("std");

const WHEEL_THRESHOLD: usize = 10_000_000_000;

pub fn isPrime(n: usize) bool {
    if (n < 2) return false;
    if (n == 2 or n == 3 or n == 5) return true;
    if (n % 2 == 0 or n % 3 == 0 or n % 5 == 0) return false;
    if (n < WHEEL_THRESHOLD) {
        return wheelPrimeCheck(n);
    }
    return isPrimeMillerRabin(n);
}

fn wheelPrimeCheck(n: usize) bool {
    const offsets = [_]usize{ 7, 11, 13, 17, 19, 23, 29, 31 };

    var base: usize = 0;

    while (true) {
        for (offsets) |o| {
            const x = base + o;

            if (x > n / x) return true;
            if (n % x == 0) return false;
        }

        base += 30;

        // safe stopping condition (prevents division-by-zero entirely)
        if (base > n / 7) break;
    }

    return true;
}

fn isPrimeMillerRabin(n: usize) bool {
    if (n < 1_373_653) return millerRabinWithBases(n, &.{ 2, 3 });
    if (n < 9_080_191) return millerRabinWithBases(n, &.{ 31, 73 });
    if (n < 4_759_123_141) return millerRabinWithBases(n, &.{ 2, 7, 61 });
    if (n < 1_122_004_669_633)
        return millerRabinWithBases(n, &.{ 2, 13, 23, 1_662_803 });

    return millerRabinWithBases(
        n,
        &.{ 2, 325, 9375, 28178, 450775, 9780504, 1_795_265_022 },
    );
}

fn millerRabinWithBases(n: usize, bases: []const u64) bool {
    const nn: u128 = @intCast(n);
    var d: u128 = nn - 1;
    var s: usize = 0;

    while ((d & 1) == 0) : (d >>= 1) s += 1;

    for (bases) |a| {
        if (a % nn == 0) continue;

        var x = modpow(a % nn, d, nn);
        if (x == 1 or x == nn - 1) continue;

        var composite = true;
        for (1..s) |_| {
            x = modmul(x, x, nn);
            if (x == nn - 1) {
                composite = false;
                break;
            }
        }

        if (composite) return false;
    }

    return true;
}

inline fn modmul(a: u128, b: u128, m: u128) u128 {
    return (a * b) % m;
}

fn modpow(base: u128, exp: u128, m: u128) u128 {
    var x = base;
    var y = exp;
    var r: u128 = 1;

    while (y > 0) : (y >>= 1) {
        if ((y & 1) == 1)
            r = modmul(r, x, m);
        x = modmul(x, x, m);
    }

    return r;
}
