pub const GROUPS = [_][]const usize{
    &[_]usize{ 7, 67, 71 },
    &[_]usize{ 11, 41, 73 },
    &[_]usize{ 13, 43, 59 },
    &[_]usize{ 17, 37, 53 },
    &[_]usize{ 19, 29, 61 },
    &[_]usize{ 23, 31, 47 },
    &[_]usize{ 79, 97 },
    &[_]usize{ 83, 89 },
};

pub const GROUP_COUNT = GROUPS.len;

pub fn periodOf(primes: []const usize) usize {
    var period: usize = 1;
    for (primes) |p| period *= p;
    return period;
}
