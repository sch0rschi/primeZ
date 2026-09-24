const std = @import("std");
const BuildUtils = @import("buildUtils");
const Comptimes = @import("comptimes.zig");

pub const CacheInfo = BuildUtils.CacheInfo;
pub const HardwareProfile = CacheInfo.HardwareProfile;

pub const PresieveKind = enum { build, fallback };

pub const MAX_SEGMENT_ELEMS: usize = 1 << 23;
pub const MIN_SEGMENT_ELEMS: usize = 16 * 1024;
pub const MIN_PINNED_SEGMENT_ELEMS: usize = 4096;
pub const MIN_SEGMENT_SHIFT = std.math.log2_int(usize, MIN_PINNED_SEGMENT_ELEMS);
pub const MAX_SEGMENT_SHIFT = std.math.log2_int(usize, MAX_SEGMENT_ELEMS);

const SMALL_L1_STRIDE_DIVISOR = 5;
const SMALL_L2_STRIDE_DIVISOR = 5;
const L2_STRIDE_L2_DIVISOR = 2;
const SMALL_SEGMENT_SEGMENT_FACTOR = 1;
const MEDIUM_SEGMENT_FACTOR = 5;
const PRE_LARGE_SEGMENT_FACTOR = Comptimes.WHEEL_CIRCUMFERENCE / MIN_WHEEL_2310_STEP;

const MIN_WHEEL_2310_STEP: usize = blk: {
    @setEvalBranchQuota(100_000);
    var m: usize = std.math.maxInt(usize);
    for (Comptimes.WHEEL_PATTERNS_2310) |step| m = @min(m, step.divMultiplicator);
    break :blk m;
};

comptime {
    if (PRE_LARGE_SEGMENT_FACTOR * MIN_WHEEL_2310_STEP != Comptimes.WHEEL_CIRCUMFERENCE) @compileError("large tier needs every hit of a prime above preLargeThreshold to land at least one segment ahead");
    if (PRE_LARGE_SEGMENT_FACTOR < MEDIUM_SEGMENT_FACTOR) @compileError("preLarge threshold must not be below the medium threshold");
}

pub const BUILD_PROFILE = HardwareProfile.fromKiB(BuildUtils.BUILD_L1D_KIB, BuildUtils.BUILD_L2_KIB, BuildUtils.BUILD_L3_KIB);

pub const Layout = struct {
    segmentElems: usize,
    segmentShift: std.math.Log2Int(usize),
    l1StrideElems: usize,
    l2StrideElems: usize,
    smallL1StrideThreshold: usize,
    smallL2StrideThreshold: usize,
    smallSegmentThreshold: usize,
    mediumThreshold: usize,
    preLargeThreshold: usize,
    presieve: PresieveKind,

    pub fn pinned(segmentElems: usize, l1StrideElems: usize, l2StrideElems: usize, presieve: PresieveKind) Layout {
        std.debug.assert(std.math.isPowerOfTwo(segmentElems));
        std.debug.assert(segmentElems <= MAX_SEGMENT_ELEMS and segmentElems >= MIN_PINNED_SEGMENT_ELEMS);
        const l1Stride = std.mem.alignBackward(usize, @min(l1StrideElems, segmentElems), 8);
        std.debug.assert(l1Stride >= 8);
        const l2Stride = std.mem.alignBackward(usize, std.math.clamp(l2StrideElems, l1Stride, segmentElems), 8);
        const smallL1StrideThreshold = l1Stride / SMALL_L1_STRIDE_DIVISOR;
        const smallL2StrideThreshold = @max(l2Stride / SMALL_L2_STRIDE_DIVISOR, smallL1StrideThreshold);
        const smallSegmentThreshold = @max(segmentElems * SMALL_SEGMENT_SEGMENT_FACTOR, smallL2StrideThreshold);
        return .{
            .segmentElems = segmentElems,
            .segmentShift = std.math.log2_int(usize, segmentElems),
            .l1StrideElems = l1Stride,
            .l2StrideElems = l2Stride,
            .smallL1StrideThreshold = smallL1StrideThreshold,
            .smallL2StrideThreshold = smallL2StrideThreshold,
            .smallSegmentThreshold = smallSegmentThreshold,
            .mediumThreshold = @max(segmentElems * MEDIUM_SEGMENT_FACTOR, smallSegmentThreshold),
            .preLargeThreshold = segmentElems * PRE_LARGE_SEGMENT_FACTOR,
            .presieve = presieve,
        };
    }

    pub fn forQuery(profile: HardwareProfile, limit: usize, presieve: PresieveKind) Layout {
        return pinned(segmentElemsForQuery(profile, limit), profile.l1dBytes, profile.l2Bytes / L2_STRIDE_L2_DIVISOR, presieve);
    }
};

pub fn segmentElemsForQuery(profile: HardwareProfile, limit: usize) usize {
    const floorPow2 = struct {
        fn f(x: usize) usize {
            return @as(usize, 1) << std.math.log2_int(usize, @max(x, 1));
        }
    }.f;

    const lowerRaw = @max(@max(profile.l2Bytes / 2, profile.l1dBytes), MIN_SEGMENT_ELEMS);
    const lower = @min(std.math.ceilPowerOfTwoAssert(usize, lowerRaw), MAX_SEGMENT_ELEMS);
    const upperRaw = if (profile.l3Bytes > 0) profile.l3Bytes / 4 else profile.l2Bytes * 2;
    const upper = @max(@min(floorPow2(upperRaw), MAX_SEGMENT_ELEMS), lower);

    const wanted = std.math.ceilPowerOfTwoAssert(usize, @max(2 * @as(usize, std.math.sqrt(limit)), 1));
    return std.math.clamp(wanted, lower, upper);
}

pub const Selection = struct {
    profile: HardwareProfile,
    presieve: PresieveKind,
    detected: ?HardwareProfile,
};

var selectionOverride: ?Selection = null;
var cachedSelection: ?Selection = null;

pub fn overrideSelection(selection: ?Selection) void {
    selectionOverride = selection;
}

pub fn activeSelection() Selection {
    if (selectionOverride) |s| return s;
    if (cachedSelection) |s| return s;
    const detected = CacheInfo.detect();
    const selection: Selection = if (detected) |hw|
        if (hw.eql(BUILD_PROFILE))
            .{ .profile = BUILD_PROFILE, .presieve = .build, .detected = hw }
        else
            .{ .profile = hw, .presieve = .fallback, .detected = hw }
    else
        .{ .profile = BUILD_PROFILE, .presieve = .build, .detected = null };
    cachedSelection = selection;
    return selection;
}

pub const QueryLayouts = struct {
    query: Layout,
    selfSieve: Layout,

    pub fn pinned(segmentElems: usize, l1StrideElems: usize, l2StrideElems: usize, presieve: PresieveKind) QueryLayouts {
        const layout = Layout.pinned(segmentElems, l1StrideElems, l2StrideElems, presieve);
        return .{ .query = layout, .selfSieve = layout };
    }

    pub fn forQuery(profile: HardwareProfile, limit: usize, presieve: PresieveKind) QueryLayouts {
        return .{
            .query = Layout.forQuery(profile, limit, presieve),
            .selfSieve = Layout.forQuery(profile, std.math.sqrt(limit), presieve),
        };
    }
};

pub fn layoutsForQuery(limit: usize) QueryLayouts {
    const selection = activeSelection();
    if (BuildUtils.PINNED_SEGMENT_KIB != 0) {
        return QueryLayouts.pinned(BuildUtils.PINNED_SEGMENT_KIB * 1024, selection.profile.l1dBytes, selection.profile.l2Bytes / L2_STRIDE_L2_DIVISOR, selection.presieve);
    }
    return QueryLayouts.forQuery(selection.profile, limit, selection.presieve);
}
