const std = @import("std");

pub fn primeCountUpperBound(n: u64) u64 {
    if (n < 2) return 0;

    const small = [_]u64{ 0, 0, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 8, 8 };
    if (n <= 20) return small[n];

    const xf = @as(f64, @floatFromInt(n));
    const logx = @log(xf);

    if (n >= 32_000) {
        // Dusart 2016: π(x) < x / (ln x − 1 − 1.8/ln x) for x ≥ 32,299
        const denom = logx - 1.0 - (1.8 / logx);
        return @as(u64, @intFromFloat(@ceil(xf / denom)));
    }

    // For 21 ≤ n < 32,000: Rosser & Schoenfeld, tightened
    // π(x) < 1.25506 · x / ln x  holds for x ≥ 17
    const est = 1.25506 * xf / logx;
    return @as(u64, @intFromFloat(@ceil(est)));
}

pub fn nthPrimeUpperBound(n: u64) u64 {
    if (n < 6) {
        const small = [_]u64{ 2, 3, 5, 7, 11 };
        return small[n - 1];
    }

    const nf = @as(f64, @floatFromInt(n));
    const ln = @log(nf);
    const lnln = @log(ln);

    const est = nf * (ln + lnln);

    return @as(u64, @ceil(est));
}
