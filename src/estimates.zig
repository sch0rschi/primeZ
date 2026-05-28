const std = @import("std");

pub fn primeCountUpperBound(n: u64) u64 {
    if (n < 2) return 0;

    const xf = @as(f64, @floatFromInt(n));
    const logx = @log(xf);

    if (n >= 32_000) {
        // Dusart 2016
        const denom = logx - 1.0 - (1.8 / logx);
        const est = xf / denom;
        return @as(u64, @ceil(est));
    }

    const denom = logx - 1.1;
    const est = xf / denom;
    return @as(u64, @ceil(est)) + 1;
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
