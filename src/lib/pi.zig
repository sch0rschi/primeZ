const std = @import("std");

const Primes = @import("primes.zig");

const XCount = struct {
    x: isize,
    count: isize,
};

pub fn pi(allocator: std.mem.Allocator, x: u64) !usize {
    if (x < 2) {
        return 0;
    }

    const root = std.math.sqrt(x);
    const primes = try Primes.getPrimes(allocator, root);
    defer allocator.free(primes);
    var converted = try allocator.alloc(isize, primes.len);
    defer allocator.free(converted);
    for (primes, 0..) |p, i| {
        converted[i] = @as(isize, @intCast(p));
    }

    const a = converted.len;

    const phiResult = try phi(allocator, x, converted);

    const piResult = phiResult + a - 1;

    return piResult;
}

fn phi(allocator: std.mem.Allocator, x: u64, primes: []const isize) !usize {
    var sum: isize = 0;

    var sourceList = try std.ArrayList(XCount).initCapacity(allocator, primes.len);
    defer sourceList.deinit(allocator);
    try sourceList.append(allocator, XCount{ .x = @intCast(x), .count = 1 });

    var mergedList = try std.ArrayList(XCount).initCapacity(allocator, 0);
    defer mergedList.deinit(allocator);

    var it = std.mem.reverseIterator(primes);
    while (it.next()) |pa| {
        const len = sourceList.items.len;
        var smallXCutoffIndex: usize = 0;
        while (smallXCutoffIndex < len and sourceList.items[smallXCutoffIndex].x < pa) : (smallXCutoffIndex += 1) {
            sum += sourceList.items[smallXCutoffIndex].count;
        }

        mergedList.clearRetainingCapacity();
        try mergedList.ensureTotalCapacity(allocator, (len - smallXCutoffIndex) * 2);

        var ixid = smallXCutoffIndex;
        var xid = sourceList.items[ixid].x;
        var ixda = smallXCutoffIndex;
        var xda: isize = @divFloor(sourceList.items[ixda].x, pa);

        var groupX = xda;
        var groupCount: isize = 0;

        while (ixda < len) {
            while (xda == groupX) {
                groupCount -= sourceList.items[ixda].count;
                ixda += 1;
                if (ixda == len) {
                    xda = std.math.maxInt(isize);
                    break;
                }
                xda = @divFloor(sourceList.items[ixda].x, pa);
            }
            if (xid == groupX) {
                groupCount += sourceList.items[ixid].count;
                ixid += 1;
                xid = sourceList.items[ixid].x;
            }
            if (groupCount != 0) {
                mergedList.appendAssumeCapacity(XCount{ .x = groupX, .count = groupCount });
            }
            groupCount = 0;
            groupX = @min(xda, xid);
        }

        mergedList.appendSliceAssumeCapacity(sourceList.items[ixid..len]);
        std.mem.swap(std.ArrayList(XCount), &sourceList, &mergedList);
    }

    for (sourceList.items) |xc| {
        sum += xc.x * xc.count;
    }

    return @as(usize, @intCast(sum));
}
