const std = @import("std");
const builtin = @import("builtin");
const LayoutMod = @import("sieveEngine/layout.zig");
const PreSieve = @import("sieveEngine/preSieve.zig");
const Primes = @import("primes.zig");

const Tuning = LayoutMod.Tuning;
const Selection = LayoutMod.Selection;
const HardwareProfile = LayoutMod.HardwareProfile;

pub const Options = struct {
    targetSeconds: f64 = 0.2,
    repeats: usize = 3,
    minRounds: usize = 4,
    maxRounds: usize = 12,
    maxPasses: usize = 6,
    minGain: f64 = 0.01,
    minPassGain: f64 = 0.01,
    start: Tuning = Tuning.DEFAULT,
    verbose: bool = true,
    seed: u64 = 0x5eed_7e57,
    maxNoise: f64 = 0.10,
    allowNoisy: bool = false,
};

pub const Result = struct {
    tuning: Tuning,
    noise: f64,
    versusDefault: Stats,
    validationRanges: usize,
};

pub const Stats = struct {
    rounds: usize = 0,
    meanLog: f64 = 0,
    lowLog: f64 = 0,
    highLog: f64 = 0,

    pub fn of(logs: []const f64) Stats {
        const n = logs.len;
        if (n < 2) return .{ .rounds = n, .meanLog = if (n == 1) logs[0] else 0, .lowLog = -std.math.inf(f64), .highLog = std.math.inf(f64) };
        var sum: f64 = 0;
        for (logs) |l| sum += l;
        const mean = sum / @as(f64, @floatFromInt(n));
        var squares: f64 = 0;
        for (logs) |l| squares += (l - mean) * (l - mean);
        const standardError = @sqrt(squares / @as(f64, @floatFromInt(n - 1)) / @as(f64, @floatFromInt(n)));
        const t = if (n - 1 <= T_995.len) T_995[n - 2] else Z_995;
        return .{ .rounds = n, .meanLog = mean, .lowLog = mean - t * standardError, .highLog = mean + t * standardError };
    }

    pub fn gain(self: Stats) f64 {
        return 1 - @exp(self.meanLog);
    }

    pub fn gainLow(self: Stats) f64 {
        return 1 - @exp(self.highLog);
    }

    pub fn gainHigh(self: Stats) f64 {
        return 1 - @exp(self.lowLog);
    }
};

const T_995 = [_]f64{ 63.657, 9.925, 5.841, 4.604, 4.032, 3.707, 3.499, 3.355, 3.250, 3.169, 3.106, 3.055, 3.012, 2.977, 2.947, 2.921, 2.898, 2.878, 2.861, 2.845, 2.831, 2.819, 2.807, 2.797, 2.787, 2.779, 2.771, 2.763, 2.756, 2.750 };
const Z_995 = 2.576;
const MAX_ROUNDS = 64;

pub const Bench = struct {
    ptr: *anyopaque,
    scenarioCount: usize,
    heldOutCount: usize = 0,
    measureFn: *const fn (ptr: *anyopaque, tuning: Tuning, scenario: usize) anyerror!?f64,

    pub fn measure(self: Bench, tuning: Tuning, scenario: usize) !?f64 {
        return self.measureFn(self.ptr, tuning, scenario);
    }
};

const NOISE_SAMPLES = 5;

const Scenario = struct {
    name: []const u8,
    start: u64,
    limit: u64,
    primes: usize = 0,
    baseSeconds: f64 = 0,
};

const ScenarioSpec = struct { name: []const u8, limit: u64, targetScale: f64 = 1 };

const SCENARIO_LIMITS = [_]ScenarioSpec{
    .{ .name = "small", .limit = 0 },
    .{ .name = "mid", .limit = 10_000_000_000_000 },
    .{ .name = "high", .limit = 1_000_000_000_000_000 },
    .{ .name = "extreme", .limit = 100_000_000_000_000_000 },
};

const HELD_OUT_LIMITS = [_]ScenarioSpec{
    .{ .name = "small/2", .limit = 0, .targetScale = 0.5 },
    .{ .name = "1e11", .limit = 100_000_000_000 },
    .{ .name = "1e14", .limit = 100_000_000_000_000 },
    .{ .name = "1e16", .limit = 10_000_000_000_000_000 },
    .{ .name = "1e18", .limit = 1_000_000_000_000_000_000 },
};

const ALL_SPECS = SCENARIO_LIMITS ++ HELD_OUT_LIMITS;

const MAX_CANDIDATES = 32;
const MAX_HISTORY = 64;
const NEIGHBOR_REACH = 2;
const MAX_SCENARIOS = 16;
const MIN_WIDTH: u64 = 1_000_000;
const SETUP_SHARE_INVERSE = 4;

const Candidates = struct {
    values: [MAX_CANDIDATES]usize = undefined,
    len: usize = 0,

    fn contains(self: *const Candidates, value: usize) bool {
        for (self.values[0..self.len]) |v| if (v == value) return true;
        return false;
    }

    fn add(self: *Candidates, value: usize) void {
        if (self.contains(value)) return;
        if (self.len == MAX_CANDIDATES) return;
        self.values[self.len] = value;
        self.len += 1;
    }

    fn slice(self: *const Candidates) []const usize {
        return self.values[0..self.len];
    }
};

const Axis = enum {
    segmentMinKiB,
    segmentMaxKiB,
    l1StrideKiB,
    l2StrideKiB,
    smallL1StrideDivisor,
    smallL2StrideDivisor,
    smallSegmentPercent,
    mediumSegmentFactor,
    presieve,
};

const SieveBench = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    selection: Selection,
    clock: std.Io.Clock,
    targetSeconds: f64,
    repeats: usize,
    verbose: bool,
    scenarios: [ALL_SPECS.len]Scenario = undefined,

    const Run = struct { seconds: f64, primes: usize };

    fn init(allocator: std.mem.Allocator, io: std.Io, selection: Selection, options: Options) SieveBench {
        const threadClock = if (std.Io.Clock.cpu_thread.resolution(io)) |r| r.toNanoseconds() > 0 else |_| false;
        return .{
            .allocator = allocator,
            .io = io,
            .selection = selection.withTuning(Tuning.DEFAULT, .default),
            .clock = if (threadClock) .cpu_thread else .awake,
            .targetSeconds = options.targetSeconds,
            .repeats = options.repeats,
            .verbose = options.verbose,
        };
    }

    fn bench(self: *SieveBench) Bench {
        return .{ .ptr = self, .scenarioCount = SCENARIO_LIMITS.len, .heldOutCount = HELD_OUT_LIMITS.len, .measureFn = measureErased };
    }

    fn log(self: *const SieveBench, comptime fmt: []const u8, args: anytype) void {
        if (self.verbose) std.debug.print(fmt, args);
    }

    fn timeRun(self: *const SieveBench, tuning: Tuning, start: u64, limit: u64) !Run {
        const layouts = LayoutMod.QueryLayouts.forSelection(self.selection.withTuning(tuning, .autotuned), limit);
        const t0 = self.clock.now(self.io);
        const primes = try Primes.piSieveCountingWithLayouts(self.allocator, start, limit, layouts);
        const t1 = self.clock.now(self.io);
        const ns = t0.durationTo(t1).toNanoseconds();
        return .{ .seconds = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s, .primes = primes };
    }

    fn measureErased(ptr: *anyopaque, tuning: Tuning, scenario: usize) anyerror!?f64 {
        const self: *SieveBench = @ptrCast(@alignCast(ptr));
        const s = self.scenarios[scenario];
        const r = try self.timeRun(tuning, s.start, s.limit);
        if (r.primes != s.primes) {
            self.log("  ! {s} counted {d} primes, expected {d}\n", .{ s.name, r.primes, s.primes });
            return null;
        }
        return r.seconds / s.baseSeconds;
    }

    fn calibrate(self: *SieveBench) !void {
        self.log("timing with {s}, calibrating scenarios for ~{d:.2}s each\n", .{ if (self.clock == .cpu_thread) "thread CPU time" else "wall time", self.targetSeconds });
        for (ALL_SPECS, &self.scenarios, 0..) |spec, *scenario, i| {
            if (i == SCENARIO_LIMITS.len) self.log("  held out for validation:\n", .{});
            _ = try self.scenarioRun(spec.limit, MIN_WIDTH);
            const setup = if (spec.limit == 0) 0 else (try self.scenarioRunBest(spec.limit, MIN_WIDTH)).seconds;
            const target = @max(self.targetSeconds * spec.targetScale, SETUP_SHARE_INVERSE * setup);
            var width: u64 = 100_000_000;
            var run = try self.scenarioRun(spec.limit, width);
            var iterations: usize = 0;
            while (iterations < 12 and (run.seconds < target * 0.7 or run.seconds > target * 1.4)) : (iterations += 1) {
                const scale = std.math.clamp(target / @max(run.seconds, 1e-6), 1.0 / 16.0, 16.0);
                const maxWidth = if (spec.limit == 0) std.math.maxInt(u64) / 2 else spec.limit / 2;
                const next: u64 = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(width)) * scale, @as(f64, @floatFromInt(MIN_WIDTH)), @as(f64, @floatFromInt(maxWidth))));
                if (next == width) break;
                width = next;
                run = try self.scenarioRun(spec.limit, width);
            }
            const best = try self.scenarioRunBest(spec.limit, width);
            scenario.* = .{
                .name = spec.name,
                .start = if (spec.limit == 0) 0 else spec.limit - width,
                .limit = if (spec.limit == 0) width else spec.limit,
                .primes = best.primes,
                .baseSeconds = best.seconds,
            };
            self.log("  {s:<8} [{d}, {d}] {d:.3}s\n", .{ scenario.name, scenario.start, scenario.limit, scenario.baseSeconds });
        }
    }

    fn scenarioRun(self: *const SieveBench, specLimit: u64, width: u64) !Run {
        return if (specLimit == 0) try self.timeRun(Tuning.DEFAULT, 0, width) else try self.timeRun(Tuning.DEFAULT, specLimit - width, specLimit);
    }

    fn scenarioRunBest(self: *const SieveBench, specLimit: u64, width: u64) !Run {
        var best = try self.scenarioRun(specLimit, width);
        for (1..self.repeats) |_| {
            const r = try self.scenarioRun(specLimit, width);
            if (r.primes != best.primes) return error.InconsistentPrimeCount;
            best.seconds = @min(best.seconds, r.seconds);
        }
        return best;
    }
};

const Move = []const Axis;

const MOVES: []const Move = blk: {
    var moves: []const Move = &.{};
    for (std.enums.values(Axis)) |axis| moves = moves ++ &[_]Move{&[_]Axis{axis}};
    break :blk moves ++ &[_]Move{
        &.{ .segmentMinKiB, .segmentMaxKiB },
        &.{ .l1StrideKiB, .smallL1StrideDivisor },
        &.{ .l2StrideKiB, .smallL2StrideDivisor },
    };
};

const MoveKey = [2]usize;

const History = struct {
    keys: [MAX_HISTORY]MoveKey = undefined,
    len: usize = 0,

    fn contains(self: *const History, key: MoveKey) bool {
        for (self.keys[0..self.len]) |k| if (std.mem.eql(usize, &k, &key)) return true;
        return false;
    }

    fn add(self: *History, key: MoveKey) void {
        if (self.contains(key) or self.len == MAX_HISTORY) return;
        self.keys[self.len] = key;
        self.len += 1;
    }
};

fn moveKey(move: Move, tuning: Tuning) MoveKey {
    var key: MoveKey = @splat(0);
    for (move, 0..) |axis, i| key[i] = axisValue(axis, tuning);
    return key;
}

const Tuner = struct {
    allocator: std.mem.Allocator,
    bench: Bench,
    profile: HardwareProfile,
    options: Options,
    random: std.Random.DefaultPrng,

    fn log(self: *const Tuner, comptime fmt: []const u8, args: anytype) void {
        if (self.options.verbose) std.debug.print(fmt, args);
    }

    fn shuffledOrder(self: *Tuner, order: []usize) void {
        for (order, 0..) |*o, i| o.* = i;
        self.random.random().shuffle(usize, order);
    }

    fn estimateNoise(self: *Tuner) !f64 {
        var noise: f64 = 0;
        for (0..self.bench.scenarioCount) |s| {
            var samples: [NOISE_SAMPLES]f64 = undefined;
            for (&samples) |*sample| sample.* = (try self.bench.measure(Tuning.DEFAULT, s)) orelse return error.InconsistentPrimeCount;
            std.mem.sortUnstable(f64, &samples, {}, std.sort.asc(f64));
            noise = @max(noise, samples[NOISE_SAMPLES / 2] / samples[0] - 1);
        }
        return noise;
    }

    const Race = struct { winner: usize, stats: Stats };

    const Scenarios = struct { first: usize, count: usize };

    fn tuningScenarios(self: *const Tuner) Scenarios {
        return .{ .first = 0, .count = self.bench.scenarioCount };
    }

    fn validationScenarios(self: *const Tuner) Scenarios {
        if (self.bench.heldOutCount == 0) return self.tuningScenarios();
        return .{ .first = self.bench.scenarioCount, .count = self.bench.heldOutCount };
    }

    fn race(self: *Tuner, candidates: []const Tuning, scenarios: Scenarios) !Race {
        const count = candidates.len;
        std.debug.assert(count >= 2 and count <= MAX_CANDIDATES + 1);
        const maxRounds = @min(@max(self.options.maxRounds, self.options.minRounds), MAX_ROUNDS);
        const threshold = @log(1 - self.options.minGain);
        var logs: [MAX_CANDIDATES + 1][MAX_ROUNDS]f64 = undefined;
        var alive: [MAX_CANDIDATES + 1]bool = @splat(true);
        var stats: [MAX_CANDIDATES + 1]Stats = @splat(.{});
        var order: [MAX_CANDIDATES + 1]usize = undefined;

        var rounds: usize = 0;
        while (rounds < maxRounds) {
            var roundCost: [MAX_CANDIDATES + 1]f64 = @splat(0);
            for (scenarios.first..scenarios.first + scenarios.count) |s| {
                self.shuffledOrder(order[0..count]);
                for (order[0..count]) |c| {
                    if (!alive[c]) continue;
                    const cost = (try self.bench.measure(candidates[c], s)) orelse {
                        if (c == 0) return error.InconsistentPrimeCount;
                        alive[c] = false;
                        continue;
                    };
                    roundCost[c] += cost;
                }
            }
            for (1..count) |c| {
                if (alive[c]) logs[c][rounds] = @log(roundCost[c] / roundCost[0]);
            }
            rounds += 1;
            if (rounds < self.options.minRounds) continue;

            var rivals: usize = 0;
            for (1..count) |c| {
                if (!alive[c]) continue;
                stats[c] = Stats.of(logs[c][0..rounds]);
                if (stats[c].lowLog > threshold) alive[c] = false else rivals += 1;
            }
            if (rivals == 0) break;
            if (self.dominantWinner(stats[0..count], alive[0..count], threshold)) |w| return .{ .winner = w, .stats = stats[w] };
        }

        var best: usize = 0;
        for (1..count) |c| {
            if (alive[c] and isWinner(stats[c], threshold) and (best == 0 or stats[c].meanLog < stats[best].meanLog)) best = c;
        }
        return .{ .winner = best, .stats = if (best == 0) .{ .rounds = rounds } else stats[best] };
    }

    fn isWinner(stats: Stats, threshold: f64) bool {
        return stats.highLog < 0 and stats.meanLog < threshold;
    }

    fn dominantWinner(self: *const Tuner, stats: []const Stats, alive: []const bool, threshold: f64) ?usize {
        _ = self;
        for (1..stats.len) |w| {
            if (!alive[w] or !isWinner(stats[w], threshold)) continue;
            for (1..stats.len) |c| {
                if (c != w and alive[c] and stats[c].lowLog <= stats[w].highLog) break;
            } else return w;
        }
        return null;
    }

    fn candidatesFor(self: *const Tuner, axis: Axis, current: Tuning) Candidates {
        const profile = self.profile;
        var c: Candidates = .{};
        switch (axis) {
            .segmentMinKiB, .segmentMaxKiB => {
                const bounds = LayoutMod.segmentBoundsFor(profile, current);
                const anchorKiB = (if (axis == .segmentMinKiB) bounds.lower else bounds.upper) / 1024;
                const shifts = [_]i8{ -3, -2, -1, 0, 1, 2 };
                for (shifts) |shift| {
                    const kib = if (shift < 0) anchorKiB >> @intCast(-shift) else anchorKiB << @intCast(shift);
                    if (kib < 16 or kib > Tuning.MAX_SEGMENT_KIB) continue;
                    if (axis == .segmentMinKiB and kib > bounds.upper / 1024) continue;
                    if (axis == .segmentMaxKiB and kib < bounds.lower / 1024) continue;
                    c.add(kib);
                }
            },
            .l1StrideKiB, .l2StrideKiB => {
                const derived = (if (axis == .l1StrideKiB) profile.l1dBytes else profile.l2Bytes) / 1024;
                const eighths: []const usize = if (axis == .l1StrideKiB) &.{ 4, 6, 8, 12, 16 } else &.{ 1, 2, 3, 4, 6, 8 };
                for (eighths) |e| {
                    const kib = derived * e / 8;
                    if (kib >= 1 and kib <= Tuning.MAX_SEGMENT_KIB) c.add(kib);
                }
            },
            .smallL1StrideDivisor, .smallL2StrideDivisor => for ([_]usize{ 2, 3, 4, 5, 6, 8, 10, 12, 16 }) |d| c.add(d),
            .smallSegmentPercent => for ([_]usize{ 25, 50, 75, 100, 150, 200 }) |p| c.add(p),
            .mediumSegmentFactor => for ([_]usize{ 2, 3, 4, 5, 6, 8, 10, 12 }) |f| {
                if (f <= LayoutMod.PRE_LARGE_SEGMENT_FACTOR) c.add(f);
            },
            .presieve => if (!PreSieve.BUILD_IS_FALLBACK) {
                c.add(@intFromEnum(Tuning.Presieve.build));
                c.add(@intFromEnum(Tuning.Presieve.fallback));
            },
        }
        return c;
    }

    fn withValue(axis: Axis, base: Tuning, value: usize) Tuning {
        var t = base;
        switch (axis) {
            .presieve => t.presieve = @enumFromInt(value),
            inline else => |a| @field(t, @tagName(a)) = value,
        }
        return t;
    }

    fn effectiveValue(self: *const Tuner, axis: Axis, tuning: Tuning) usize {
        return switch (axis) {
            .segmentMinKiB => LayoutMod.segmentBoundsFor(self.profile, tuning).lower,
            .segmentMaxKiB => LayoutMod.segmentBoundsFor(self.profile, tuning).upper,
            .l1StrideKiB => LayoutMod.l1StrideElemsFor(self.profile, tuning),
            .l2StrideKiB => LayoutMod.l2StrideElemsFor(self.profile, tuning),
            else => axisValue(axis, tuning),
        };
    }

    fn neighborsFor(self: *const Tuner, axis: Axis, incumbent: Tuning) Candidates {
        const own = self.effectiveValue(axis, incumbent);
        var all: Candidates = .{};
        all.add(axisValue(axis, incumbent));
        for (self.candidatesFor(axis, incumbent).slice()) |v| {
            if (self.effectiveValue(axis, withValue(axis, incumbent, v)) != own) all.add(v);
        }
        const Context = struct {
            tuner: *const Tuner,
            axis: Axis,
            base: Tuning,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.tuner.effectiveValue(ctx.axis, withValue(ctx.axis, ctx.base, a)) < ctx.tuner.effectiveValue(ctx.axis, withValue(ctx.axis, ctx.base, b));
            }
        };
        const values = all.values[0..all.len];
        std.mem.sortUnstable(usize, values, Context{ .tuner = self, .axis = axis, .base = incumbent }, Context.lessThan);
        const at = std.mem.indexOfScalar(usize, values, axisValue(axis, incumbent)).?;
        var near: Candidates = .{};
        for (values[at -| NEIGHBOR_REACH..@min(at + NEIGHBOR_REACH + 1, values.len)]) |v| near.add(v);
        return near;
    }

    const Step = struct { tuning: Tuning, ratio: f64 };

    fn addCandidate(candidates: []Tuning, count: *usize, t: Tuning) void {
        if (t.validate() == error.OutOfRange or count.* == candidates.len) return;
        for (candidates[0..count.*]) |c| if (c.eql(t)) return;
        candidates[count.*] = t;
        count.* += 1;
    }

    fn tuneMove(self: *Tuner, move: Move, incumbent: Tuning) !Step {
        const unchanged: Step = .{ .tuning = incumbent, .ratio = 1 };
        var candidates: [MAX_CANDIDATES + 1]Tuning = undefined;
        candidates[0] = incumbent;
        var count: usize = 1;
        if (move.len == 1) {
            for (self.candidatesFor(move[0], incumbent).slice()) |v| addCandidate(&candidates, &count, withValue(move[0], incumbent, v));
        } else {
            const first = self.neighborsFor(move[0], incumbent);
            const second = self.neighborsFor(move[1], incumbent);
            for (first.slice()) |a| for (second.slice()) |b| {
                addCandidate(&candidates, &count, withValue(move[1], withValue(move[0], incumbent, a), b));
            };
        }
        if (count == 1) return unchanged;

        const result = try self.race(candidates[0..count], self.tuningScenarios());
        if (result.winner == 0) {
            self.log("  {f} keep ({d} candidates, {d} rounds)\n", .{ moveValue(move, incumbent), count - 1, result.stats.rounds });
            return unchanged;
        }
        const stats = result.stats;
        self.log("  {f} -> ({d:.1}% faster, 99% CI {d:.1}..{d:.1}%, {d} rounds)\n", .{ moveValue(move, candidates[result.winner]), stats.gain() * 100, stats.gainLow() * 100, stats.gainHigh() * 100, stats.rounds });
        return .{ .tuning = candidates[result.winner], .ratio = @exp(stats.meanLog) };
    }
};

const MoveValue = struct {
    move: Move,
    tuning: Tuning,

    pub fn format(self: MoveValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.move, 0..) |axis, i| {
            if (i > 0) try writer.writeAll(" ");
            try writer.print("{t}={f}", .{ axis, valueOf(axis, self.tuning) });
        }
    }
};

fn moveValue(move: Move, tuning: Tuning) MoveValue {
    return .{ .move = move, .tuning = tuning };
}

const AxisValue = struct {
    axis: Axis,
    tuning: Tuning,

    pub fn format(self: AxisValue, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.axis) {
            .presieve => try writer.print("{t}", .{self.tuning.presieve}),
            inline else => |a| {
                const v = @field(self.tuning, @tagName(a));
                if (v == 0) try writer.writeAll("derived") else try writer.print("{d}", .{v});
            },
        }
    }
};

fn axisValue(axis: Axis, tuning: Tuning) usize {
    return switch (axis) {
        .presieve => @intFromEnum(tuning.presieve),
        inline else => |a| @field(tuning, @tagName(a)),
    };
}

fn valueOf(axis: Axis, tuning: Tuning) AxisValue {
    return .{ .axis = axis, .tuning = tuning };
}

pub fn pinToCpu(cpu: usize) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    var set: std.os.linux.cpu_set_t = @splat(0);
    if (cpu >= set.len * @bitSizeOf(usize)) return error.InvalidCpu;
    set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    try std.os.linux.sched_setaffinity(0, &set);
}

pub fn tune(allocator: std.mem.Allocator, io: std.Io, selection: Selection, options: Options) !Result {
    var sieve = SieveBench.init(allocator, io, selection, options);
    try sieve.calibrate();
    return tuneWith(allocator, sieve.bench(), selection.profile, options);
}

pub fn tuneWith(allocator: std.mem.Allocator, bench: Bench, profile: HardwareProfile, options: Options) !Result {
    std.debug.assert(bench.scenarioCount + bench.heldOutCount <= MAX_SCENARIOS);
    var tuner = Tuner{
        .allocator = allocator,
        .bench = bench,
        .profile = profile,
        .options = options,
        .random = .init(options.seed),
    };

    const noise = try tuner.estimateNoise();
    tuner.log("noise: {d:.1}% (median over best of {d} runs of the default)\n", .{ noise * 100, NOISE_SAMPLES });
    if (noise > options.maxNoise) {
        if (!options.allowNoisy) {
            tuner.log("error: the machine is too noisy to tune ({d:.1}% > {d:.1}%); stop other work or pass --tune-anyway\n", .{ noise * 100, options.maxNoise * 100 });
            return error.TooNoisy;
        }
        tuner.log("warning: tuning anyway, expect longer races and fewer accepted changes\n", .{});
    }

    const axes = comptime std.enums.values(Axis);
    var current = options.start;
    if (!current.eql(Tuning.DEFAULT)) {
        tuner.log("starting from:", .{});
        for (axes) |axis| tuner.log(" {t}={f}", .{ axis, valueOf(axis, current) });
        tuner.log("\n", .{});
    }
    var changes: usize = 0;
    var testedAtChange: [MOVES.len]?usize = @splat(null);
    var held: [MOVES.len]History = @splat(.{});
    var frozen: [MOVES.len]bool = @splat(false);
    for (MOVES, &held) |move, *history| history.add(moveKey(move, current));

    for (0..options.maxPasses) |pass| {
        tuner.log("pass {d}\n", .{pass + 1});
        var passRatio: f64 = 1;
        var tested: usize = 0;
        for (MOVES, &testedAtChange, &held, &frozen) |move, *testedAt, *history, *isFrozen| {
            if (isFrozen.* or testedAt.* == changes) continue;
            tested += 1;
            const step = try tuner.tuneMove(move, current);
            if (!step.tuning.eql(current)) {
                const key = moveKey(move, step.tuning);
                if (history.contains(key)) {
                    tuner.log("  {f} frozen: it wants values it already held, so it is within noise\n", .{moveValue(move, step.tuning)});
                    isFrozen.* = true;
                    continue;
                }
                history.add(key);
                current = step.tuning;
                passRatio *= step.ratio;
                changes += 1;
            }
            testedAt.* = changes;
        }
        if (tested == 0 or changes == 0 or std.mem.allEqual(bool, &frozen, true)) {
            tuner.log("stagnated: no parameter changed since it was last tested\n", .{});
            break;
        }
        if (1 - passRatio < options.minPassGain) {
            tuner.log("stagnated: pass {d} gained {d:.1}% (< {d:.1}%)\n", .{ pass + 1, (1 - passRatio) * 100, options.minPassGain * 100 });
            break;
        }
    } else tuner.log("stopped after {d} passes without stagnating\n", .{options.maxPasses});

    const validation = tuner.validationScenarios();
    tuner.log("validating on {d} {s} ranges\n", .{ validation.count, if (bench.heldOutCount > 0) "held-out" else "tuning" });
    var chosen = options.start;
    if (!current.eql(options.start)) {
        const result = try tuner.race(&.{ options.start, current }, validation);
        if (result.winner == 1) chosen = current;
        tuner.log("  tuned vs start: {s}\n", .{if (result.winner == 1) "tuned is faster" else "no confirmed gain, keeping the start"});
    }
    var versusDefault: Stats = .{};
    if (!chosen.eql(Tuning.DEFAULT)) {
        const result = try tuner.race(&.{ Tuning.DEFAULT, chosen }, validation);
        if (result.winner == 1) {
            versusDefault = result.stats;
            tuner.log("  vs default: {d:.1}% faster (99% CI {d:.1}..{d:.1}%)\n", .{ versusDefault.gain() * 100, versusDefault.gainLow() * 100, versusDefault.gainHigh() * 100 });
        } else {
            chosen = Tuning.DEFAULT;
            tuner.log("  no confirmed gain over the defaults, keeping the defaults\n", .{});
        }
    }
    return .{ .tuning = chosen, .noise = noise, .versusDefault = versusDefault, .validationRanges = validation.count };
}

pub fn writeTuningFile(writer: *std.Io.Writer, result: Result, profile: HardwareProfile) std.Io.Writer.Error!void {
    try writer.print("# primeZ tuning for L1d {d} KiB, L2 {d} KiB, L3 {d} KiB\n", .{ profile.l1dBytes / 1024, profile.l2Bytes / 1024, profile.l3Bytes / 1024 });
    const v = result.versusDefault;
    if (v.rounds > 0) {
        try writer.print("# {d:.1}% faster than the defaults on {d} held-out ranges (99% CI {d:.1}..{d:.1}%, {d} rounds)\n", .{ v.gain() * 100, result.validationRanges, v.gainLow() * 100, v.gainHigh() * 100, v.rounds });
    } else {
        try writer.writeAll("# no confirmed gain over the defaults\n");
    }
    try writer.print("# measurement noise {d:.1}%\n", .{result.noise * 100});
    try writer.writeAll("# 0 = derive from the cache sizes\n");
    try result.tuning.write(writer);
}
