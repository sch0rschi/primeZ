const config = @import("primeZConfig");

const SieveLayoutMath = @import("sieveLayoutMath.zig");

pub const WheelShape = @import("wheelShape.zig");

pub const PresieveGroups = @import("presieveGroups.zig");

pub const RESIDUE_CLASS_COUNT = WheelShape.RESIDUE_CLASS_COUNT;

pub const GENERAL_PURPOSE_REGISTER_COUNT: usize = config.general_purpose_register_count;

pub const SEGMENT_ELEMS: usize = SieveLayoutMath.segmentElems(config.opt_segment_size_in_kb);
pub const STRIPE_ELEMS: usize = SieveLayoutMath.stripeElems(config.l1_cache_size_in_kb, config.opt_segment_size_in_kb);

pub const SMALL_STRIDE_THRESHOLD: usize =
    SieveLayoutMath.smallStrideThreshold(config.l1_cache_size_in_kb, config.opt_segment_size_in_kb);
pub const SMALL_SEGMENT_THRESHOLD: usize = SieveLayoutMath.smallSegmentThreshold(config.opt_segment_size_in_kb);
pub const MEDIUM_THRESHOLD: usize = SieveLayoutMath.mediumThreshold(config.opt_segment_size_in_kb);
pub const PRE_LARGE_THRESHOLD: usize = SieveLayoutMath.preLargeThreshold(config.opt_segment_size_in_kb);

pub const SMALL_SEGMENT_PRIME_COUNTS_BY_RESIDUE: [RESIDUE_CLASS_COUNT]usize = config.small_segment_prime_counts_by_residue;
pub const PRE_LARGE_PRIME_COUNTS_BY_RESIDUE: [RESIDUE_CLASS_COUNT]usize = config.pre_large_prime_counts_by_residue;

pub const PRESIEVE_GROUPS: []const []const usize = config.presieve_groups;

pub const PRESIEVE_PATTERNS_BLOB: []const u8 = config.presieve_patterns_blob;
