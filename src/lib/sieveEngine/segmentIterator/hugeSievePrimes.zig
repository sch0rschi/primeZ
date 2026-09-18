const std = @import("std");
const Types = @import("../types.zig");
const Comptimes = @import("../comptimes.zig");
const BuildUtils = @import("buildUtils");
const Estimates = @import("../../estimates.zig");

const SievePrimeMod = @import("sievePrime.zig");
// Discovery-facing type (holds a full absolute bucket position). RingEntry
// below is the compact, ring/Block-resident encoding used everywhere else.
const SievePrime = SievePrimeMod.HugeSievePrime;
const RingEntry = SievePrimeMod.HugeSievePrimeSlot;

const SEGMENT_ELEMS: usize = BuildUtils.SEGMENT_ELEMS;
const LARGE_HUGE_THRESHOLD: usize = BuildUtils.LARGE_HUGE_THRESHOLD;

// RingEntry.localOffset is a u23; SEGMENT_ELEMS must never exceed 2^23.
comptime {
    if (SEGMENT_ELEMS > 1 << 23) @compileError("SEGMENT_ELEMS exceeds RingEntry.localOffset's u23 budget - widen that field before raising this bound");
}

// Largest single-step advance (in buckets) any tracked prime can make.
const MAX_WHEEL_STEP_FACTOR: usize = blk: {
    var m: usize = 0;
    for (Comptimes.WHEEL_PATTERNS_210) |step| {
        m = @max(m, @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend));
    }
    break :blk m;
};

// Rounded up to a power of two so the ring can be indexed with `&
// (ring.len - 1)` instead of a runtime `%`. Reused by LargeSievePrimes
// and PreHugeSievePrimes, both still head+mask-indexed.
pub fn ringSizeFor(maxPrime: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, tightMinRingLen(maxPrime));
}

// Huge tier's OWN ring sizing, used un-padded (see HugeSievePrimes'
// struct doc): rotates its ringWritePos array by one slot every apply()
// call instead of head+mask indexing (mirrors primesieve's own
// EratBig::crossOff `std::copy` rotation exactly), so it needs no power
// of 2 at all - every slot the tight bound doesn't need is a slot that
// doesn't have to be rotated through every segment.
fn tightMinRingLen(maxPrime: usize) usize {
    const maxSievingPrime = maxPrime / Comptimes.WHEEL_CIRCUMFERENCE;
    const maxAdvance = maxSievingPrime * MAX_WHEEL_STEP_FACTOR + MAX_WHEEL_STEP_FACTOR;
    const maxMultipleIndexWithinSegment = (SEGMENT_ELEMS - 1) + maxAdvance;
    return maxMultipleIndexWithinSegment / SEGMENT_ELEMS + 1;
}

const BLOCK_BYTES: usize = 8 * 1024;
const BLOCK_HEADER_BYTES: usize = @sizeOf([*]RingEntry) + @sizeOf(?*anyopaque);
const BLOCK_LEN: usize = (BLOCK_BYTES - BLOCK_HEADER_BYTES) / @sizeOf(RingEntry);
const BLOCK_PAD_BYTES: usize = BLOCK_BYTES - BLOCK_HEADER_BYTES - BLOCK_LEN * @sizeOf(RingEntry);
const BLOCK_ALIGNMENT = std.mem.Alignment.fromByteUnits(BLOCK_BYTES);

// `extern struct`, not a plain struct: isFull/blockOf require `items` to
// be the LAST field, ending exactly on a BLOCK_BYTES boundary - a plain
// struct's field order isn't guaranteed, extern struct pins it.
const Block = extern struct {
    // One past the last valid entry - only meaningful once sealed (see
    // isFull's call sites); a still-filling block's real extent is the
    // live write cursor itself, not this field.
    end: [*]RingEntry,
    next: ?*Block,
    itemsBytes: [BLOCK_LEN * @sizeOf(RingEntry) + BLOCK_PAD_BYTES]u8 align(@alignOf(RingEntry)) = undefined,

    fn items(self: *Block) [*]RingEntry {
        return @ptrCast(&self.itemsBytes);
    }
};

comptime {
    if (@sizeOf(Block) != BLOCK_BYTES) @compileError("Block must be exactly BLOCK_BYTES for the pointer-arithmetic fullness/ownership tricks below to be valid");
    if (!std.math.isPowerOfTwo(BLOCK_BYTES)) @compileError("BLOCK_BYTES must be a power of two");
}

// True once a write cursor has stepped past its Block's last slot. Every
// Block is BLOCK_BYTES-aligned and exactly BLOCK_BYTES large, so this is
// pure pointer arithmetic, no dereference needed.
fn isFull(ptr: [*]RingEntry) bool {
    return @intFromPtr(ptr) % BLOCK_BYTES == 0;
}

// Recovers the Block a write cursor belongs to from its address alone.
// Subtracting 1 first is essential: a cursor that just advanced past a
// now-full Block sits exactly on the boundary of what looks like the
// NEXT Block's address.
fn blockOf(ptr: [*]RingEntry) *Block {
    var address = @intFromPtr(ptr);
    address -= 1;
    address -= address % BLOCK_BYTES;
    return @ptrFromInt(address);
}

// Upper bound on how many huge-tier sieving primes a query can ever
// register: primes in (LARGE_HUGE_THRESHOLD, maxPrime], bounded above by
// primeCountUpperBound's difference (saturating - maxPrime can be below
// LARGE_HUGE_THRESHOLD, e.g. the self-bootstrap sieve's own small dsp, in
// which case the huge tier is simply never used).
fn populationBoundFor(maxPrime: usize) usize {
    const bound = Estimates.primeCountUpperBound(maxPrime) -| Estimates.primeCountUpperBound(LARGE_HUGE_THRESHOLD);
    return @intCast(bound);
}

// Safe upper bound on how many Blocks can ever be simultaneously live
// (allocated but not yet drained) at once, so the whole pool can be one
// fixed-size preallocated array instead of a growing set of separately
// allocated slabs - see the struct doc for why per-slot dedication (not
// just preallocation) is what actually matters for locality.
//
// Each of up to `ringLen` slots can have its own dedicated, freshly
// started (and therefore near-empty) Block open at once - that alone
// costs up to `ringLen` Blocks holding almost nothing. Beyond that,
// `population` entries worth of storage needs at most
// ceil(population / BLOCK_LEN) further Blocks. Formally: for occupancies
// o_1..o_k (k <= ringLen, sum o_i <= population), each slot's Block count
// is ceil(o_i / BLOCK_LEN) <= floor(o_i / BLOCK_LEN) + 1, so the total is
// <= population / BLOCK_LEN + ringLen. The extra +1 covers apply()'s own
// transient: it re-files a drained slot's entries into their new slots
// one Block at a time, only calling freeBlock() on the old Block once
// every one of its entries has already been re-stored elsewhere - so for
// the span of one Block's re-filing, both its own (not-yet-freed) Block
// and its entries' brand new destination Block(s) are briefly live at
// once. Single-threaded, so at most one such not-yet-freed Block ever
// exists at a time.
fn maxBlocksFor(population: usize, ringLen: usize) usize {
    return ringLen + (population + BLOCK_LEN - 1) / BLOCK_LEN + 1;
}

// Above LARGE_HUGE_THRESHOLD a single wheel step already exceeds a full
// segment, so a huge sieving prime crosses off at most once per segment.
//
// Storage is a ring buffer of buckets, one per upcoming segment up to
// `ringSizeFor(maxPrime)` segments ahead - that bound holds for any
// tracked prime's single wheel step, so once filed into the ring, apply()
// only ever touches an entry on the exact segment it's due. Each ring
// slot is a singly-linked list of Block; `ringWritePos[i]` (the live
// write cursor) is enough to recover everything else on demand. Each
// Block, once started, belongs to exactly one slot until fully drained -
// that per-slot dedication is what keeps a slot's entries contiguous in
// memory, so apply()'s scan over a drained slot stays a sequential read
// instead of chasing pointers scattered across the whole pool.
//
// Ring/Block storage uses RingEntry (a local offset within its eventual
// segment - see HugeSievePrimeSlot's own docstring), not SievePrime
// (which stores a full absolute position): which ring slot/Block an
// entry lives in already tells you its segment, so storing that again
// would be pure waste. `list`/`pendingStart` below still uses SievePrime,
// since a pending entry has no segment assignment yet.
//
// The ring can't hold a prime whose first target is still arbitrarily
// far from bucketsStart: `firstAdmissibleMultiple(prime, start)` lands
// within the ring's reach whenever start > prime^2, but for a prime close
// to sqrt(limit), prime^2 can be >= start, landing arbitrarily far away.
// `list`/`pendingStart` bridges that thin band (kept sorted by
// currentBucketIndex - discovery order already gives that for free);
// activate() drains its front into the ring once a prime's position
// comes within reach. Sized to the same populationBoundFor(maxPrime)
// bound as the Block pool: in the worst case every registered prime
// stays pending.
pub const HugeSievePrimes = struct {
    list: std.ArrayList(SievePrime),
    pendingStart: usize,

    // null means the slot has never been written to since it was last
    // drained. Everything else about a slot's block list is recovered on
    // demand from this cursor (see blockOf/isFull). Slot 0 is ALWAYS
    // "the current segment" - no head pointer at all, unlike large/
    // preHuge's own ring: apply() physically rotates this array by one
    // slot every call (mirrors primesieve's own EratBig::crossOff
    // `std::copy` rotation exactly), so indexing a future slot is just
    // `segmentsAhead` directly, no offset or mask needed.
    ringWritePos: []?[*]RingEntry,

    // Head of the free list threading through blockPool (below) - a
    // Block returned here once its ring slot is fully drained by apply(),
    // reused by future addBlock() calls. Starts empty: blocks are handed
    // out from `blockPool` lazily (see nextUnclaimed) rather than
    // pre-chained, so a query that never needs the whole pool never
    // touches (page-faults in) the part it doesn't use.
    freeBlocks: ?*Block,

    // The entire Block pool, sized once via maxBlocksFor() and never
    // grown - see maxBlocksFor's doc for why this bound is safe.
    blockPool: []align(BLOCK_BYTES) Block,
    nextUnclaimed: usize,

    pub fn init(allocator: std.mem.Allocator, maxPrime: usize) !HugeSievePrimes {
        const ringLen = tightMinRingLen(maxPrime);
        const ringWritePos = try allocator.alloc(?[*]RingEntry, ringLen);
        @memset(ringWritePos, null);

        const population = populationBoundFor(maxPrime);
        const blockCount = maxBlocksFor(population, ringLen);
        const blockPool = try allocator.alignedAlloc(Block, BLOCK_ALIGNMENT, blockCount);

        return HugeSievePrimes{
            .list = try std.ArrayList(SievePrime).initCapacity(allocator, population),
            .pendingStart = 0,
            .ringWritePos = ringWritePos,
            .freeBlocks = null,
            .blockPool = blockPool,
            .nextUnclaimed = 0,
        };
    }

    pub fn deinit(self: *HugeSievePrimes, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        allocator.free(self.ringWritePos);
        allocator.free(self.blockPool);
    }

    fn freeBlock(self: *HugeSievePrimes, b: *Block) void {
        b.next = self.freeBlocks;
        self.freeBlocks = b;
    }

    fn addBlock(self: *HugeSievePrimes, sealedWritePos: ?[*]RingEntry) [*]RingEntry {
        // maxBlocksFor(maxPrime) bounds total simultaneously-live Blocks,
        // so one of these two sources always has room.
        const fresh = if (self.freeBlocks) |fb| blk: {
            self.freeBlocks = fb.next;
            break :blk fb;
        } else blk: {
            std.debug.assert(self.nextUnclaimed < self.blockPool.len);
            const b = &self.blockPool[self.nextUnclaimed];
            self.nextUnclaimed += 1;
            break :blk b;
        };
        fresh.next = null;

        if (sealedWritePos) |wp| {
            const old = blockOf(wp);
            old.end = wp;
            fresh.next = old;
        }
        return fresh.items();
    }

    fn storeSievingPrime(self: *HugeSievePrimes, slot: usize, entry: *const RingEntry) void {
        const wp = self.ringWritePos[slot] orelse self.addBlock(null);
        wp[0] = entry.*;
        const next = wp + 1;
        self.ringWritePos[slot] = if (isFull(next)) self.addBlock(next) else next;
    }

    // The one place residue and phase combine into a flat wheelIndex210 -
    // runs at most twice per prime's whole lifetime (once via add(),
    // once more if it passed through the pending band via activate()),
    // unlike the old per-(residue,phase) row lookup this replaces, which
    // ran once per segment a prime was actually due in - see this
    // file's own RingEntry/HugeSievePrimeSlot doc for why that frequency
    // difference is the whole point.
    fn toRingEntry(sievePrime: SievePrime, bucketsStart: usize, segmentsAhead: usize) RingEntry {
        const localOffset = sievePrime.currentBucketIndex - bucketsStart - segmentsAhead * SEGMENT_ELEMS;
        return RingEntry{
            .localOffset = @intCast(localOffset),
            .initialBucketIndex = sievePrime.initialBucketIndex,
            .wheelIndex210 = @as(u9, sievePrime.initialInBucketIndex) * Comptimes.ADMISSIBLE_RESIDUES_210.count + @as(u9, sievePrime.wheelStepIndex210),
        };
    }

    /// `bucketsStart` must be the position ring slot 0 currently
    /// represents (not necessarily the query's own first segment) -
    /// discoverSievingPrimes's self-bootstrapping sieve calls add()
    /// interleaved with its own activate()/apply(), which rotate the
    /// ring, so this can't assume slot 0 still represents position 0.
    pub fn add(self: *HugeSievePrimes, sievePrime: SievePrime, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        const segmentsAhead = destinationOf(sievePrime, ringLen, bucketsStart);
        if (segmentsAhead < ringLen) {
            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(segmentsAhead, &entry);
        } else {
            self.list.appendAssumeCapacity(sievePrime);
        }
    }

    fn destinationOf(sievePrime: SievePrime, ringLen: usize, bucketsStart: usize) usize {
        std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
        const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
        return if (segmentsAhead < ringLen) segmentsAhead else ringLen;
    }

    pub noinline fn activate(self: *HugeSievePrimes, bucketsStart: usize) void {
        const ringLen = self.ringWritePos.len;
        while (self.pendingStart < self.list.items.len) {
            const sievePrime = self.list.items[self.pendingStart];
            std.debug.assert(sievePrime.currentBucketIndex >= bucketsStart);
            const segmentsAhead = (sievePrime.currentBucketIndex - bucketsStart) / SEGMENT_ELEMS;
            if (segmentsAhead >= ringLen) break;

            const entry = toRingEntry(sievePrime, bucketsStart, segmentsAhead);
            self.storeSievingPrime(segmentsAhead, &entry);
            self.pendingStart += 1;
        }
    }

    pub noinline fn apply(
        self: *HugeSievePrimes,
        buckets: Types.SIEVE_BUCKETS_TYPE,
        bucketsStart: usize,
        bucketsEndExclusive: usize,
    ) void {
        _ = bucketsEndExclusive;
        _ = bucketsStart; // RingEntry.localOffset is already segment-relative.
        const ringLen = self.ringWritePos.len;

        if (self.ringWritePos[0]) |wp| {
            const headBlock = blockOf(wp);
            headBlock.end = wp;

            var block: ?*Block = headBlock;
            while (block) |b| {
                const items = b.items();
                const fill = (@intFromPtr(b.end) - @intFromPtr(items)) / @sizeOf(RingEntry);

                // Process 2 entries per iteration to increase instruction
                // level parallelism - mirrors primesieve's own
                // EratBig::crossOff(sieve, prime, end) exactly, which
                // pairs sieving primes for the same stated reason. No
                // data dependency between the two processOne calls, so
                // the compiler is free to interleave/overlap them.
                var i: usize = 0;
                while (i + 1 < fill) : (i += 2) {
                    const result0 = processOne(buckets, items[i]);
                    const result1 = processOne(buckets, items[i + 1]);
                    std.debug.assert(result0.segmentsAhead >= 1 and result0.segmentsAhead < ringLen);
                    std.debug.assert(result1.segmentsAhead >= 1 and result1.segmentsAhead < ringLen);
                    self.storeSievingPrime(result0.segmentsAhead, &result0.entry);
                    self.storeSievingPrime(result1.segmentsAhead, &result1.entry);
                }
                if (i < fill) {
                    const result = processOne(buckets, items[i]);
                    std.debug.assert(result.segmentsAhead >= 1 and result.segmentsAhead < ringLen);
                    self.storeSievingPrime(result.segmentsAhead, &result.entry);
                }

                const next = b.next;
                self.freeBlock(b);
                block = next;
            }
            self.ringWritePos[0] = null;
        }

        // Rotate by one slot - mirrors primesieve's own EratBig::crossOff
        // exactly (`std::copy(buckets_.begin()+1, buckets_.end(),
        // buckets_.begin()); buckets_.back() = bucket;`): slot 0 is
        // always "the current segment," so a future slot needs no head
        // offset or mask, just segmentsAhead directly (see add()/
        // activate()/the loop above). ringWritePos[0] is always null
        // here (either it already was, or the drain above just set it),
        // so unlike primesieve - which eagerly hands the vacated slot a
        // fresh bucket before rotating it to the back - there's nothing
        // to carry forward: storeSievingPrime already lazily allocates
        // on first write.
        std.mem.copyForwards(?[*]RingEntry, self.ringWritePos[0 .. ringLen - 1], self.ringWritePos[1..ringLen]);
        self.ringWritePos[ringLen - 1] = null;
    }
};

/// Crosses off one entry's current occurrence and advances it to the
/// next, returning the ADVANCED entry by value (not written back through
/// `entry`) plus how many segments ahead it now lands. Takes `entry` BY
/// VALUE, not `*RingEntry` - an earlier version wrote the new
/// localOffset/wheelIndex210 back into the caller's entry pointer
/// (the OLD block, about to be freed) and had the caller re-read
/// `entry.*` afterward to copy it into `storeSievingPrime` - `perf
/// annotate` showed the compiler couldn't prove that memory wasn't
/// touched by the intervening addBlock() call (which also touches the
/// same Block pool), so it emitted a genuine store-then-reload instead
/// of keeping the freshly-computed value in a register. Returning the
/// new entry by value sidesteps the whole question - there's no shared
/// memory location for the optimizer to reason about at all.
inline fn processOne(buckets: Types.SIEVE_BUCKETS_TYPE, entry: RingEntry) struct { entry: RingEntry, segmentsAhead: usize } {
    // Single flat lookup - entry.wheelIndex210 already combines residue
    // and phase (see toRingEntry), so unlike the old [ari][wsi] 2D
    // table there is no row-offset combine to do here at all.
    const step = Comptimes.WHEEL_PATTERNS_210[entry.wheelIndex210];

    const localOffset: usize = entry.localOffset;
    buckets[localOffset] &= step.bitMask;

    const initialBucketIndex = @as(usize, entry.initialBucketIndex);
    const advance = initialBucketIndex * @as(usize, step.divMultiplicator) + @as(usize, step.residueAddend);
    const newOffset = localOffset + advance;
    const segmentsAhead = newOffset / SEGMENT_ELEMS;

    return .{
        .entry = RingEntry{
            .localOffset = @intCast(newOffset - segmentsAhead * SEGMENT_ELEMS),
            .initialBucketIndex = entry.initialBucketIndex,
            // Already flat and already the right next value - baked
            // into the table as data (mirrors primesieve's own
            // wheel210[...].next), so this is a plain load, no
            // combine, no branch.
            .wheelIndex210 = @intCast(step.nextWheelIndex210),
        },
        .segmentsAhead = segmentsAhead,
    };
}
