const std = @import("std");
const BuildUtils = @import("buildUtils");
const Comptimes = @import("comptimes.zig");

pub const CacheInfo = BuildUtils.CacheInfo;
pub const HardwareProfile = CacheInfo.HardwareProfile;
pub const Tuning = BuildUtils.Tuning.Tuning;

pub const PresieveKind = enum { build, fallback };

pub const MAX_SEGMENT_ELEMS: usize = 1 << 23;
pub const MIN_SEGMENT_ELEMS: usize = 16 * 1024;
pub const MIN_PINNED_SEGMENT_ELEMS: usize = 4096;
pub const MIN_SEGMENT_SHIFT = std.math.log2_int(usize, MIN_PINNED_SEGMENT_ELEMS);
pub const MAX_SEGMENT_SHIFT = std.math.log2_int(usize, MAX_SEGMENT_ELEMS);

const L2_STRIDE_L2_DIVISOR = 2;
pub const PRE_LARGE_SEGMENT_FACTOR = Comptimes.WHEEL_CIRCUMFERENCE / MIN_WHEEL_2310_STEP;

const MIN_WHEEL_2310_STEP: usize = blk: {
    @setEvalBranchQuota(100_000);
    var m: usize = std.math.maxInt(usize);
    for (Comptimes.WHEEL_PATTERNS_2310) |step| m = @min(m, step.divMultiplicator);
    break :blk m;
};

const MAX_WHEEL_30_STEP: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS) |row| {
        for (row) |step| m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
    }
    break :blk m;
};

pub fn maxWheel30Advance(prime: usize) usize {
    return (prime / Comptimes.WHEEL_CIRCUMFERENCE) * MAX_WHEEL_30_STEP + MAX_WHEEL_30_STEP;
}

pub fn maxPrimeAdvancingAtMost(elems: usize) usize {
    if (elems < 2 * MAX_WHEEL_30_STEP) return 0;
    return (elems / MAX_WHEEL_30_STEP - 1) * Comptimes.WHEEL_CIRCUMFERENCE + Comptimes.WHEEL_CIRCUMFERENCE - 1;
}

comptime {
    if (MAX_SEGMENT_ELEMS * PRE_LARGE_SEGMENT_FACTOR / Comptimes.WHEEL_CIRCUMFERENCE >= 1 << 29) @compileError("preLarge primes must fit the ring entry's 29-bit initial bucket index");
    if (PRE_LARGE_SEGMENT_FACTOR * MIN_WHEEL_2310_STEP != Comptimes.WHEEL_CIRCUMFERENCE) @compileError("large tier needs every hit of a prime above preLargeThreshold to land at least one segment ahead");
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
        return tuned(segmentElems, l1StrideElems, l2StrideElems, presieve, Tuning.DEFAULT);
    }

    pub fn tuned(segmentElems: usize, l1StrideElems: usize, l2StrideElems: usize, presieve: PresieveKind, tuning: Tuning) Layout {
        std.debug.assert(std.math.isPowerOfTwo(segmentElems));
        std.debug.assert(segmentElems <= MAX_SEGMENT_ELEMS and segmentElems >= MIN_PINNED_SEGMENT_ELEMS);
        const l1Stride = std.mem.alignBackward(usize, @min(l1StrideElems, segmentElems), 8);
        std.debug.assert(l1Stride >= 8);
        const l2Stride = std.mem.alignBackward(usize, std.math.clamp(l2StrideElems, l1Stride, segmentElems), 8);
        const preLargeThreshold = segmentElems * PRE_LARGE_SEGMENT_FACTOR;
        const smallStrideCap = maxPrimeAdvancingAtMost(segmentElems);
        const smallL1StrideThreshold = @min(l1Stride / tuning.smallL1StrideDivisor, smallStrideCap);
        const smallL2StrideThreshold = @min(@max(l2Stride / tuning.smallL2StrideDivisor, smallL1StrideThreshold), smallStrideCap);
        const smallSegmentThreshold = @min(@max(segmentElems * tuning.smallSegmentPercent / 100, smallL2StrideThreshold), preLargeThreshold);
        const layout: Layout = .{
            .segmentElems = segmentElems,
            .segmentShift = std.math.log2_int(usize, segmentElems),
            .l1StrideElems = l1Stride,
            .l2StrideElems = l2Stride,
            .smallL1StrideThreshold = smallL1StrideThreshold,
            .smallL2StrideThreshold = smallL2StrideThreshold,
            .smallSegmentThreshold = smallSegmentThreshold,
            .mediumThreshold = std.math.clamp(segmentElems * tuning.mediumSegmentFactor, smallSegmentThreshold, preLargeThreshold),
            .preLargeThreshold = preLargeThreshold,
            .presieve = presieve,
        };
        std.debug.assert(layout.isSound());
        return layout;
    }

    pub fn isSound(self: Layout) bool {
        return std.math.isPowerOfTwo(self.segmentElems) and
            self.segmentElems >= MIN_PINNED_SEGMENT_ELEMS and self.segmentElems <= MAX_SEGMENT_ELEMS and
            self.l1StrideElems >= 8 and self.l1StrideElems <= self.l2StrideElems and self.l2StrideElems <= self.segmentElems and
            self.smallL1StrideThreshold <= self.smallL2StrideThreshold and
            self.smallL2StrideThreshold <= self.smallSegmentThreshold and
            self.smallSegmentThreshold <= self.mediumThreshold and
            self.mediumThreshold <= self.preLargeThreshold and
            self.preLargeThreshold == self.segmentElems * PRE_LARGE_SEGMENT_FACTOR and
            maxWheel30Advance(self.smallL2StrideThreshold) <= self.segmentElems;
    }

    pub fn forQuery(profile: HardwareProfile, limit: usize, presieve: PresieveKind) Layout {
        return forQueryTuned(profile, limit, presieve, Tuning.DEFAULT);
    }

    pub fn forQueryTuned(profile: HardwareProfile, limit: usize, presieve: PresieveKind, tuning: Tuning) Layout {
        return tunedForSegment(segmentElemsForQueryTuned(profile, limit, tuning), profile, presieve, tuning);
    }

    pub fn tunedForSegment(segmentElems: usize, profile: HardwareProfile, presieve: PresieveKind, tuning: Tuning) Layout {
        return tuned(segmentElems, l1StrideElemsFor(profile, tuning), l2StrideElemsFor(profile, tuning), presieve, tuning);
    }
};

pub fn l1StrideElemsFor(profile: HardwareProfile, tuning: Tuning) usize {
    return if (tuning.l1StrideKiB != 0) tuning.l1StrideKiB * 1024 else profile.l1dBytes;
}

pub fn l2StrideElemsFor(profile: HardwareProfile, tuning: Tuning) usize {
    return if (tuning.l2StrideKiB != 0) tuning.l2StrideKiB * 1024 else profile.l2Bytes / L2_STRIDE_L2_DIVISOR;
}

pub const SegmentBounds = struct { lower: usize, upper: usize };

pub fn segmentBoundsFor(profile: HardwareProfile, tuning: Tuning) SegmentBounds {
    const floorPow2 = struct {
        fn f(x: usize) usize {
            return @as(usize, 1) << std.math.log2_int(usize, @max(x, 1));
        }
    }.f;

    const derivedLowerRaw = @max(@max(profile.l2Bytes / 2, profile.l1dBytes), MIN_SEGMENT_ELEMS);
    const lower = if (tuning.segmentMinKiB != 0) tuning.segmentMinKiB * 1024 else @min(std.math.ceilPowerOfTwoAssert(usize, derivedLowerRaw), MAX_SEGMENT_ELEMS);
    const upperRaw = if (profile.l3Bytes > 0) profile.l3Bytes / 4 else profile.l2Bytes * 2;
    const upper = if (tuning.segmentMaxKiB != 0) tuning.segmentMaxKiB * 1024 else @min(floorPow2(upperRaw), MAX_SEGMENT_ELEMS);
    return .{ .lower = lower, .upper = @max(upper, lower) };
}

pub fn segmentElemsForQuery(profile: HardwareProfile, limit: usize) usize {
    return segmentElemsForQueryTuned(profile, limit, Tuning.DEFAULT);
}

pub fn segmentElemsForQueryTuned(profile: HardwareProfile, limit: usize, tuning: Tuning) usize {
    const bounds = segmentBoundsFor(profile, tuning);
    const wanted = std.math.ceilPowerOfTwoAssert(usize, @max(2 * @as(usize, std.math.sqrt(limit)), 1));
    return std.math.clamp(wanted, bounds.lower, bounds.upper);
}

pub const TuningSource = enum { default, user, file, autotuned };

pub const Selection = struct {
    profile: HardwareProfile,
    presieve: PresieveKind,
    detected: ?HardwareProfile,
    tuning: Tuning = Tuning.DEFAULT,
    tuningSource: TuningSource = .default,

    pub fn withTuning(self: Selection, tuning: Tuning, source: TuningSource) Selection {
        var s = self;
        s.tuning = tuning;
        s.tuningSource = source;
        s.presieve = switch (tuning.presieve) {
            .auto => self.presieve,
            .build => .build,
            .fallback => .fallback,
        };
        return s;
    }
};

var selectionOverride: ?Selection = null;
var cachedSelection: ?Selection = null;

pub fn overrideSelection(selection: ?Selection) void {
    selectionOverride = selection;
}

pub fn activeSelection() Selection {
    if (selectionOverride) |s| return s;
    if (cachedSelection) |s| return s;
    const selection = untunedSelection();
    cachedSelection = selection;
    return selection;
}

pub fn untunedSelection() Selection {
    const detected = CacheInfo.detect();
    if (detected) |hw| {
        if (!hw.eql(BUILD_PROFILE)) return .{ .profile = hw, .presieve = .fallback, .detected = hw };
    }
    return .{ .profile = BUILD_PROFILE, .presieve = .build, .detected = detected };
}

pub const QueryLayouts = struct {
    query: Layout,
    selfSieve: Layout,

    pub fn pinned(segmentElems: usize, l1StrideElems: usize, l2StrideElems: usize, presieve: PresieveKind) QueryLayouts {
        const layout = Layout.pinned(segmentElems, l1StrideElems, l2StrideElems, presieve);
        return .{ .query = layout, .selfSieve = layout };
    }

    pub fn forQuery(profile: HardwareProfile, limit: usize, presieve: PresieveKind) QueryLayouts {
        return forQueryTuned(profile, limit, presieve, Tuning.DEFAULT);
    }

    pub fn forQueryTuned(profile: HardwareProfile, limit: usize, presieve: PresieveKind, tuning: Tuning) QueryLayouts {
        return .{
            .query = Layout.forQueryTuned(profile, limit, presieve, tuning),
            .selfSieve = Layout.forQueryTuned(profile, std.math.sqrt(limit), presieve, tuning),
        };
    }

    pub fn forSelection(selection: Selection, limit: usize) QueryLayouts {
        if (BuildUtils.PINNED_SEGMENT_KIB != 0) {
            const layout = Layout.tunedForSegment(BuildUtils.PINNED_SEGMENT_KIB * 1024, selection.profile, selection.presieve, selection.tuning);
            return .{ .query = layout, .selfSieve = layout };
        }
        return forQueryTuned(selection.profile, limit, selection.presieve, selection.tuning);
    }
};

pub fn layoutsForQuery(limit: usize) QueryLayouts {
    return QueryLayouts.forSelection(activeSelection(), limit);
}
