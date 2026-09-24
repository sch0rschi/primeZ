const config = @import("primeZConfig");

pub const WheelShape = @import("wheelShape.zig");

pub const PresieveGroups = @import("presieveGroups.zig");

pub const CacheInfo = @import("cacheInfo.zig");

pub const RESIDUE_CLASS_COUNT = WheelShape.RESIDUE_CLASS_COUNT;

pub const GENERAL_PURPOSE_REGISTER_COUNT: usize = config.general_purpose_register_count;

pub const BUILD_L1D_KIB: usize = config.build_l1d_kib;
pub const BUILD_L2_KIB: usize = config.build_l2_kib;
pub const BUILD_L3_KIB: usize = config.build_l3_kib;

pub const PINNED_SEGMENT_KIB: usize = config.pinned_segment_kib;

pub const PRESIEVE_GROUPS_FALLBACK: []const []const usize = &PresieveGroups.FALLBACK_GROUPS;
pub const PRESIEVE_PATTERNS_BLOB_FALLBACK: []const u8 = @embedFile("presieve_patterns_fallback");

pub const BUILD_PRESIEVE_IS_FALLBACK: bool = config.build_presieve_is_fallback;

pub const PRESIEVE_GROUPS_BUILD: []const []const usize = if (BUILD_PRESIEVE_IS_FALLBACK) PRESIEVE_GROUPS_FALLBACK else PresieveGroups.parseGroups(@embedFile("presieve_groups_build"));
pub const PRESIEVE_PATTERNS_BLOB_BUILD: []const u8 = if (BUILD_PRESIEVE_IS_FALLBACK) PRESIEVE_PATTERNS_BLOB_FALLBACK else @embedFile("presieve_patterns_build");
