pub fn segmentElems(optSegmentSizeInKb: usize) usize {
    return 1024 * optSegmentSizeInKb;
}

pub fn stripeElems(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    const smaller: usize = @min(l1CacheSizeInKb, optSegmentSizeInKb);
    return 1024 * smaller;
}

pub fn smallMediumThreshold(l1CacheSizeInKb: usize, optSegmentSizeInKb: usize) usize {
    return stripeElems(l1CacheSizeInKb, optSegmentSizeInKb) / 5;
}

pub fn mediumLargeThreshold(optSegmentSizeInKb: usize) usize {
    return segmentElems(optSegmentSizeInKb) * 7 / 4;
}
