const Types = @import("sieveEngine/types.zig");

pub fn primeCountUpperBound(n: Types.PRIME_TYPE) u64 {
    if (n < 2) return 0;

    const small = [_]u64{ 0, 0, 1, 2, 2, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 8, 8 };
    if (n <= 20) return small[n];

    const xf = @as(f64, @floatFromInt(n));
    const logx = @log(xf);

    if (n >= 32_000) {
        const denom = logx - 1.0 - (1.8 / logx);
        return @as(u64, @intFromFloat(@ceil(xf / denom)));
    }

    const est = 1.25506 * xf / logx;
    return @as(u64, @intFromFloat(@ceil(est)));
}

pub fn primeCountLowerBound(n: Types.PRIME_TYPE) u64 {
    if (n < 17) return 0;
    const xf = @as(f64, @floatFromInt(n));
    return @as(u64, @intFromFloat(@floor(xf / @log(xf))));
}

pub fn primeCountInRangeUpperBound(lowerExclusive: Types.PRIME_TYPE, upperInclusive: Types.PRIME_TYPE) u64 {
    if (upperInclusive <= lowerExclusive) return 0;
    return primeCountUpperBound(upperInclusive) -| primeCountLowerBound(lowerExclusive);
}

pub fn nthPrimeUpperBound(n: usize) Types.PRIME_TYPE {
    if (n < 6) {
        const small = [_]Types.PRIME_TYPE{ 2, 3, 5, 7, 11 };
        return small[n];
    }

    const nf = @as(f64, @floatFromInt(n+1));
    const ln = @log(nf);
    const lnln = @log(ln);

    const est = nf * (ln + lnln);

    return @as(Types.PRIME_TYPE, @ceil(est));
}
