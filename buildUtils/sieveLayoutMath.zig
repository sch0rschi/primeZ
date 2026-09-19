pub fn segmentElems(optSegmentSizeInKb: usize) usize {
    return 1024 * optSegmentSizeInKb;
}

pub fn stripeElems(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    const smaller: usize = @min(l1CacheSizeInKb, optSegmentSizeInKb);
    return 1024 * smaller;
}

pub fn smallStrideThreshold(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    return stripeElems(l1CacheSizeInKb, optSegmentSizeInKb) / 5;
}

pub fn smallSegmentThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 1;
}

pub fn preLargeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 15;
}

pub fn mediumThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 5;
}
