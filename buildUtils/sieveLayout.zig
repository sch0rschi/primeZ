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

pub const PRESIEVE_GROUPS: []const []const usize = config.presieve_groups;

pub const PRESIEVE_PATTERNS_BLOB: []const u8 = config.presieve_patterns_blob;
