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
    defaultCost: f64,
    tunedCost: f64,
    noise: f64,
};

pub const Bench = struct {
    ptr: *anyopaque,
    scenarioCount: usize,
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

const SCENARIO_LIMITS = [_]struct { name: []const u8, limit: u64 }{
    .{ .name = "small", .limit = 0 },
    .{ .name = "mid", .limit = 10_000_000_000_000 },
    .{ .name = "high", .limit = 1_000_000_000_000_000 },
    .{ .name = "extreme", .limit = 100_000_000_000_000_000 },
};

const MAX_CANDIDATES = 16;
const MAX_SCENARIOS = 8;
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
    scenarios: [SCENARIO_LIMITS.len]Scenario = undefined,

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
        return .{ .ptr = self, .scenarioCount = self.scenarios.len, .measureFn = measureErased };
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
        for (SCENARIO_LIMITS, &self.scenarios) |spec, *scenario| {
            _ = try self.scenarioRun(spec.limit, MIN_WIDTH);
            const setup = if (spec.limit == 0) 0 else (try self.scenarioRunBest(spec.limit, MIN_WIDTH)).seconds;
            const target = @max(self.targetSeconds, SETUP_SHARE_INVERSE * setup);
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

const Tuner = struct {
    allocator: std.mem.Allocator,
    bench: Bench,
    profile: HardwareProfile,
    options: Options,
    random: std.Random.DefaultPrng,
    minGain: f64,

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

    fn evaluate(self: *Tuner, candidates: []const Tuning, costs: []f64, repeats: usize) !void {
        var best: [MAX_CANDIDATES + 1][MAX_SCENARIOS]f64 = undefined;
        for (best[0..candidates.len]) |*row| row.* = @splat(std.math.inf(f64));
        var broken: [MAX_CANDIDATES + 1]bool = @splat(false);
        var order: [MAX_CANDIDATES + 1]usize = undefined;

        for (0..repeats) |_| {
            for (0..self.bench.scenarioCount) |s| {
                self.shuffledOrder(order[0..candidates.len]);
                for (order[0..candidates.len]) |c| {
                    if (broken[c]) continue;
                    const cost = (try self.bench.measure(candidates[c], s)) orelse {
                        broken[c] = true;
                        continue;
                    };
                    best[c][s] = @min(best[c][s], cost);
                }
            }
        }

        for (costs[0..candidates.len], 0..) |*cost, c| {
            if (broken[c]) {
                cost.* = std.math.inf(f64);
                continue;
            }
            var sum: f64 = 0;
            for (best[c][0..self.bench.scenarioCount]) |b| sum += b;
            cost.* = sum / @as(f64, @floatFromInt(self.bench.scenarioCount));
        }
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

    const Step = struct { tuning: Tuning, ratio: f64 };

    fn tuneAxis(self: *Tuner, axis: Axis, incumbent: Tuning) !Step {
        const unchanged: Step = .{ .tuning = incumbent, .ratio = 1 };
        const values = self.candidatesFor(axis, incumbent);
        if (values.len == 0) return unchanged;

        var candidates: [MAX_CANDIDATES + 1]Tuning = undefined;
        candidates[0] = incumbent;
        var count: usize = 1;
        for (values.slice()) |v| {
            const t = withValue(axis, incumbent, v);
            if (t.eql(incumbent) or t.validate() == error.OutOfRange) continue;
            candidates[count] = t;
            count += 1;
        }
        if (count == 1) return unchanged;

        var costs: [MAX_CANDIDATES + 1]f64 = undefined;
        try self.evaluate(candidates[0..count], costs[0..count], self.options.repeats);

        var bestIndex: usize = 0;
        for (costs[1..count], 1..) |cost, i| {
            if (cost < costs[bestIndex]) bestIndex = i;
        }
        if (bestIndex == 0 or costs[bestIndex] >= costs[0] * (1 - self.minGain)) {
            self.log("  {t:<22} keep {f} ({d:.3})\n", .{ axis, valueOf(axis, incumbent), costs[0] });
            return unchanged;
        }

        const duel = [_]Tuning{ incumbent, candidates[bestIndex] };
        var confirmed: [2]f64 = undefined;
        try self.evaluate(&duel, &confirmed, self.options.repeats + 2);
        if (confirmed[1] >= confirmed[0] * (1 - self.minGain)) {
            self.log("  {t:<22} keep {f} ({f} looked {d:.1}% faster, confirmed only {d:.1}%)\n", .{ axis, valueOf(axis, incumbent), valueOf(axis, candidates[bestIndex]), (1 - costs[bestIndex] / costs[0]) * 100, (1 - confirmed[1] / confirmed[0]) * 100 });
            return unchanged;
        }
        self.log("  {t:<22} -> {f} ({d:.1}% faster, confirmed)\n", .{ axis, valueOf(axis, candidates[bestIndex]), (1 - confirmed[1] / confirmed[0]) * 100 });
        return .{ .tuning = candidates[bestIndex], .ratio = confirmed[1] / confirmed[0] };
    }
};

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
    std.debug.assert(bench.scenarioCount <= MAX_SCENARIOS);
    var tuner = Tuner{
        .allocator = allocator,
        .bench = bench,
        .profile = profile,
        .options = options,
        .random = .init(options.seed),
        .minGain = options.minGain,
    };

    const noise = try tuner.estimateNoise();
    tuner.log("noise: {d:.1}% (median over best of {d} runs of the default)\n", .{ noise * 100, NOISE_SAMPLES });
    if (noise > options.maxNoise) {
        if (!options.allowNoisy) {
            tuner.log("error: the machine is too noisy to tune ({d:.1}% > {d:.1}%); stop other work or pass --tune-anyway\n", .{ noise * 100, options.maxNoise * 100 });
            return error.TooNoisy;
        }
        tuner.log("warning: tuning anyway, only gains above the noise are accepted\n", .{});
    }
    tuner.minGain = @max(options.minGain, noise);

    const axes = comptime std.enums.values(Axis);
    var current = options.start;
    if (!current.eql(Tuning.DEFAULT)) {
        tuner.log("starting from:", .{});
        for (axes) |axis| tuner.log(" {t}={f}", .{ axis, valueOf(axis, current) });
        tuner.log("\n", .{});
    }
    var changes: usize = 0;
    var testedAtChange: [axes.len]?usize = @splat(null);
    var held: [axes.len]Candidates = @splat(.{});
    var frozen: [axes.len]bool = @splat(false);
    for (axes, &held) |axis, *values| values.add(axisValue(axis, current));

    for (0..options.maxPasses) |pass| {
        tuner.log("pass {d}\n", .{pass + 1});
        var passRatio: f64 = 1;
        var tested: usize = 0;
        for (axes, &testedAtChange, &held, &frozen) |axis, *testedAt, *values, *isFrozen| {
            if (isFrozen.* or testedAt.* == changes) continue;
            tested += 1;
            const step = try tuner.tuneAxis(axis, current);
            if (!step.tuning.eql(current)) {
                const value = axisValue(axis, step.tuning);
                if (values.contains(value)) {
                    tuner.log("  {t:<22} frozen: it wants a value it already held, so it is within noise\n", .{axis});
                    isFrozen.* = true;
                    continue;
                }
                values.add(value);
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

    const finalists = [_]Tuning{ Tuning.DEFAULT, options.start, current };
    const labels = [_][]const u8{ "default", "start", "tuned" };
    var finalCosts: [finalists.len]f64 = undefined;
    tuner.log("verifying\n", .{});
    try tuner.evaluate(&finalists, &finalCosts, options.repeats + 2);

    var best: usize = 0;
    for (finalists[1..], finalCosts[1..], 1..) |candidate, cost, i| {
        if (!candidate.eql(finalists[best]) and cost < finalCosts[best] * (1 - tuner.minGain)) best = i;
    }
    for (labels, finalCosts, 0..) |label, cost, i| {
        if (i == 0 or !finalists[i].eql(finalists[i - 1])) tuner.log("  {s:<8} {d:.3}{s}\n", .{ label, cost, if (i == best) " <- kept" else "" });
    }
    return .{
        .tuning = finalists[best],
        .defaultCost = finalCosts[0],
        .tunedCost = finalCosts[best],
        .noise = noise,
    };
}

pub fn writeTuningFile(writer: *std.Io.Writer, result: Result, profile: HardwareProfile) std.Io.Writer.Error!void {
    try writer.print("# primeZ tuning for L1d {d} KiB, L2 {d} KiB, L3 {d} KiB\n", .{ profile.l1dBytes / 1024, profile.l2Bytes / 1024, profile.l3Bytes / 1024 });
    try writer.print("# relative cost: default {d:.3}, tuned {d:.3} ({d:.1}% faster)\n", .{ result.defaultCost, result.tunedCost, (result.defaultCost / result.tunedCost - 1) * 100 });
    try writer.print("# measurement noise {d:.1}%\n", .{result.noise * 100});
    try writer.writeAll("# 0 = derive from the cache sizes\n");
    try result.tuning.write(writer);
}
