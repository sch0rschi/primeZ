const config = @import("primeZConfig");

const SieveLayoutMath = @import("sieveLayoutMath.zig");

pub const WheelShape = @import("wheelShape.zig");

pub const RESIDUE_CLASS_COUNT = WheelShape.RESIDUE_CLASS_COUNT;

pub const SEGMENT_ELEMS: usize = SieveLayoutMath.segmentElems(config.opt_segment_size_in_kb);
pub const STRIPE_ELEMS: usize = SieveLayoutMath.stripeElems(config.l1_cache_size_in_kb, config.opt_segment_size_in_kb);

pub const SMALL_MEDIUM_THRESHOLD: usize =
    SieveLayoutMath.smallMediumThreshold(config.l1_cache_size_in_kb, config.opt_segment_size_in_kb);
pub const MEDIUM_LARGE_THRESHOLD: usize = SieveLayoutMath.mediumLargeThreshold(config.opt_segment_size_in_kb);

pub const PRIME_COUNTS_BY_RESIDUE: [RESIDUE_CLASS_COUNT]usize = config.prime_counts_by_residue;
