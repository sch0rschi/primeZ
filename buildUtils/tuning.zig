const std = @import("std");

pub const Tuning = struct {
    pub const Presieve = enum { auto, build, fallback };
    pub const MIN_SEGMENT_KIB: usize = 4;
    pub const MAX_SEGMENT_KIB: usize = 8192;

    segmentMinKiB: usize = 0,
    segmentMaxKiB: usize = 0,
    l1StrideKiB: usize = 0,
    l2StrideKiB: usize = 0,
    smallL1StrideDivisor: usize = 5,
    smallL2StrideDivisor: usize = 5,
    smallSegmentPercent: usize = 100,
    mediumSegmentFactor: usize = 5,
    presieve: Presieve = .auto,

    pub const DEFAULT: Tuning = .{};

    pub const ParseError = error{ UnknownKey, MissingValue, InvalidValue, OutOfRange };

    pub fn eql(a: Tuning, b: Tuning) bool {
        inline for (@typeInfo(Tuning).@"struct".field_names) |name| {
            if (@field(a, name) != @field(b, name)) return false;
        }
        return true;
    }

    pub fn parse(text: []const u8) ParseError!Tuning {
        var tuning: Tuning = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |rawLine| {
            const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, rawLine, '#')) |i| rawLine[0..i] else rawLine, " \t");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingValue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (value.len == 0) return error.MissingValue;
            try tuning.set(key, value);
        }
        try tuning.validate();
        return tuning;
    }

    fn set(self: *Tuning, key: []const u8, value: []const u8) ParseError!void {
        inline for (@typeInfo(Tuning).@"struct".field_names) |name| {
            if (std.mem.eql(u8, key, name)) {
                @field(self, name) = switch (@FieldType(Tuning, name)) {
                    usize => std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue,
                    Presieve => std.meta.stringToEnum(Presieve, value) orelse return error.InvalidValue,
                    else => @compileError("unsupported tuning field type"),
                };
                return;
            }
        }
        return error.UnknownKey;
    }

    pub fn validate(self: Tuning) ParseError!void {
        inline for (.{ self.segmentMinKiB, self.segmentMaxKiB }) |kib| {
            if (kib != 0 and (!std.math.isPowerOfTwo(kib) or kib < MIN_SEGMENT_KIB or kib > MAX_SEGMENT_KIB)) return error.OutOfRange;
        }
        inline for (.{ self.l1StrideKiB, self.l2StrideKiB }) |kib| {
            if (kib > MAX_SEGMENT_KIB) return error.OutOfRange;
        }
        inline for (.{ self.smallL1StrideDivisor, self.smallL2StrideDivisor }) |divisor| {
            if (divisor < 1 or divisor > 64) return error.OutOfRange;
        }
        if (self.smallSegmentPercent < 10 or self.smallSegmentPercent > 400) return error.OutOfRange;
        if (self.mediumSegmentFactor < 1 or self.mediumSegmentFactor > 64) return error.OutOfRange;
    }

    pub fn write(self: Tuning, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        inline for (@typeInfo(Tuning).@"struct".field_names) |name| {
            switch (@FieldType(Tuning, name)) {
                usize => try writer.print("{s} = {d}\n", .{ name, @field(self, name) }),
                Presieve => try writer.print("{s} = {t}\n", .{ name, @field(self, name) }),
                else => @compileError("unsupported tuning field type"),
            }
        }
    }

    pub fn parseComptime(comptime text: []const u8) Tuning {
        @setEvalBranchQuota(1_000_000);
        return parse(text) catch |err| @compileError("invalid build tuning file: " ++ @errorName(err));
    }
};
