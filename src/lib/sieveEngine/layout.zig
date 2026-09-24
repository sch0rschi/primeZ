const std = @import("std");
const BuildUtils = @import("buildUtils");

pub const CacheInfo = BuildUtils.CacheInfo;
pub const HardwareProfile = CacheInfo.HardwareProfile;

pub const PresieveKind = enum { build, fallback };

pub const MAX_SEGMENT_ELEMS: usize = 1 << 23;
pub const MIN_SEGMENT_ELEMS: usize = 16 * 1024;
pub const MIN_PINNED_SEGMENT_ELEMS: usize = 4096;
pub const MIN_SEGMENT_SHIFT = std.math.log2_int(usize, MIN_PINNED_SEGMENT_ELEMS);
pub const MAX_SEGMENT_SHIFT = std.math.log2_int(usize, MAX_SEGMENT_ELEMS);

const SMALL_STRIDE_STRIPE_DIVISOR = 5;
const SMALL_SEGMENT_SEGMENT_FACTOR = 1;
const MEDIUM_SEGMENT_FACTOR = 5;
const PRE_LARGE_SEGMENT_FACTOR = 15;

pub const BUILD_PROFILE = HardwareProfile.fromKiB(BuildUtils.BUILD_L1D_KIB, BuildUtils.BUILD_L2_KIB, BuildUtils.BUILD_L3_KIB);

pub const Layout = struct {
    segmentElems: usize,
    segmentShift: std.math.Log2Int(usize),
    stripeElems: usize,
    smallStrideThreshold: usize,
    smallSegmentThreshold: usize,
    mediumThreshold: usize,
    preLargeThreshold: usize,
    presieve: PresieveKind,

    pub fn pinned(segmentElems: usize, stripeElems: usize, presieve: PresieveKind) Layout {
        std.debug.assert(std.math.isPowerOfTwo(segmentElems));
        std.debug.assert(segmentElems <= MAX_SEGMENT_ELEMS and segmentElems >= MIN_PINNED_SEGMENT_ELEMS);
        const stripe = std.mem.alignBackward(usize, @min(stripeElems, segmentElems), 8);
        std.debug.assert(stripe >= 8);
        return .{
            .segmentElems = segmentElems,
            .segmentShift = std.math.log2_int(usize, segmentElems),
            .stripeElems = stripe,
            .smallStrideThreshold = stripe / SMALL_STRIDE_STRIPE_DIVISOR,
            .smallSegmentThreshold = segmentElems * SMALL_SEGMENT_SEGMENT_FACTOR,
            .mediumThreshold = segmentElems * MEDIUM_SEGMENT_FACTOR,
            .preLargeThreshold = segmentElems * PRE_LARGE_SEGMENT_FACTOR,
            .presieve = presieve,
        };
    }

    pub fn forQuery(profile: HardwareProfile, limit: usize, presieve: PresieveKind) Layout {
        return pinned(segmentElemsForQuery(profile, limit), profile.l1dBytes, presieve);
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

    pub fn pinned(segmentElems: usize, stripeElems: usize, presieve: PresieveKind) QueryLayouts {
        const layout = Layout.pinned(segmentElems, stripeElems, presieve);
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
        return QueryLayouts.pinned(BuildUtils.PINNED_SEGMENT_KIB * 1024, selection.profile.l1dBytes, selection.presieve);
    }
    return QueryLayouts.forQuery(selection.profile, limit, selection.presieve);
}
