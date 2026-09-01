pub const PRIMES = [_]usize{ 2, 3, 5 };

pub const CIRCUMFERENCE = computeCircumference();

pub const RESIDUE_CLASS_COUNT = computeResidueClassCount();

pub const RESIDUE_CLASS_INDEX: [CIRCUMFERENCE]?usize = computeResidueClassIndex();

fn computeCircumference() usize {
    var product: usize = 1;
    for (PRIMES) |p| product *= p;
    return product;
}

fn computeResidueClassCount() usize {
    var count: usize = 0;
    for (0..CIRCUMFERENCE) |r| {
        for (PRIMES) |p| {
            if (r % p == 0) break;
        } else count += 1;
    }
    return count;
}

fn computeResidueClassIndex() [CIRCUMFERENCE]?usize {
    var index = [_]?usize{null} ** CIRCUMFERENCE;
    var position: usize = 0;
    for (0..CIRCUMFERENCE) |r| {
        for (PRIMES) |p| {
            if (r % p == 0) break;
        } else {
            index[r] = position;
            position += 1;
        }
    }
    return index;
}
