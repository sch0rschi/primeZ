const std = @import("std");
const builtin = @import("builtin");

pub const HardwareProfile = struct {
    l1dBytes: usize,
    l2Bytes: usize,
    l3Bytes: usize,

    pub fn eql(a: HardwareProfile, b: HardwareProfile) bool {
        return a.l1dBytes == b.l1dBytes and a.l2Bytes == b.l2Bytes and a.l3Bytes == b.l3Bytes;
    }

    pub fn fromKiB(l1dKiB: usize, l2KiB: usize, l3KiB: usize) HardwareProfile {
        return .{ .l1dBytes = l1dKiB * 1024, .l2Bytes = l2KiB * 1024, .l3Bytes = l3KiB * 1024 };
    }
};

pub const FALLBACK = HardwareProfile.fromKiB(32, 1024, 16 * 1024);

pub fn detect() ?HardwareProfile {
    const profile = switch (builtin.os.tag) {
        .linux => detectLinux(),
        .macos => detectMacos(),
        else => null,
    } orelse detectCpuid() orelse return null;
    if (profile.l1dBytes == 0) return null;
    return profile;
}

fn detectLinux() ?HardwareProfile {
    var best: ?HardwareProfile = null;
    var cpu: usize = 0;
    while (cpu < 4096) : (cpu += 1) {
        const profile = linuxProfileOfCpu(cpu) orelse break;
        if (best == null or isBiggerCore(profile, best.?)) best = profile;
    }
    return best;
}

fn isBiggerCore(a: HardwareProfile, b: HardwareProfile) bool {
    if (a.l1dBytes != b.l1dBytes) return a.l1dBytes > b.l1dBytes;
    if (a.l2Bytes != b.l2Bytes) return a.l2Bytes > b.l2Bytes;
    return a.l3Bytes > b.l3Bytes;
}

fn linuxProfileOfCpu(cpu: usize) ?HardwareProfile {
    var profile = HardwareProfile{ .l1dBytes = 0, .l2Bytes = 0, .l3Bytes = 0 };
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        var pathBuffer: [128]u8 = undefined;
        var valueBuffer: [64]u8 = undefined;

        const level = readSysfsCacheField(&pathBuffer, &valueBuffer, cpu, index, "level") orelse break;
        const kind = readSysfsCacheField(&pathBuffer, &valueBuffer, cpu, index, "type") orelse break;
        const isData = std.mem.eql(u8, kind, "Data") or std.mem.eql(u8, kind, "Unified");
        if (!isData) continue;
        const levelNumber = std.fmt.parseInt(u8, level, 10) catch continue;

        const size = readSysfsCacheField(&pathBuffer, &valueBuffer, cpu, index, "size") orelse continue;
        const bytes = parseSysfsSize(size) orelse continue;
        switch (levelNumber) {
            1 => profile.l1dBytes = bytes,
            2 => profile.l2Bytes = bytes,
            3 => profile.l3Bytes = bytes,
            else => {},
        }
    }
    if (profile.l1dBytes == 0) return null;
    return profile;
}

fn readSysfsCacheField(pathBuffer: *[128]u8, valueBuffer: *[64]u8, cpu: usize, index: usize, field: []const u8) ?[]const u8 {
    const linux = std.os.linux;
    const path = std.mem.printSentinel(pathBuffer, "/sys/devices/system/cpu/cpu{d}/cache/index{d}/{s}", .{ cpu, index, field }, 0) catch return null;
    const openResult = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(openResult) != .SUCCESS) return null;
    const fd: i32 = @intCast(openResult);
    defer _ = linux.close(fd);

    const readResult = linux.read(fd, valueBuffer, valueBuffer.len);
    if (linux.errno(readResult) != .SUCCESS) return null;
    return std.mem.trim(u8, valueBuffer[0..readResult], " \t\r\n");
}

fn parseSysfsSize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const multiplier: usize = switch (text[text.len - 1]) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (multiplier == 1) text else text[0 .. text.len - 1];
    const value = std.fmt.parseInt(usize, digits, 10) catch return null;
    return value * multiplier;
}

fn detectMacos() ?HardwareProfile {
    if (builtin.os.tag != .macos) return null;
    const l1 = sysctlSize("hw.perflevel0.l1dcachesize") orelse sysctlSize("hw.l1dcachesize") orelse return null;
    const l2 = sysctlSize("hw.perflevel0.l2cachesize") orelse sysctlSize("hw.l2cachesize") orelse 0;
    const l3 = sysctlSize("hw.l3cachesize") orelse 0;
    return .{ .l1dBytes = l1, .l2Bytes = l2, .l3Bytes = l3 };
}

fn sysctlSize(name: [*:0]const u8) ?usize {
    var value: u64 = 0;
    var len: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &len, null, 0) != 0) return null;
    if (value == 0) return null;
    return @intCast(value);
}

const CpuidLeaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn detectCpuid() ?HardwareProfile {
    if (comptime !builtin.cpu.arch.isX86()) return null;

    const vendor = cpuid(0, 0);
    const isAmd = vendor.ebx == 0x68747541 and vendor.edx == 0x69746e65 and vendor.ecx == 0x444d4163;
    const leaf: u32 = if (isAmd) 0x8000001D else 4;
    if (isAmd and cpuid(0x80000000, 0).eax < leaf) return null;
    if (!isAmd and vendor.eax < leaf) return null;

    var profile = HardwareProfile{ .l1dBytes = 0, .l2Bytes = 0, .l3Bytes = 0 };
    var subleaf: u32 = 0;
    while (subleaf < 16) : (subleaf += 1) {
        const r = cpuid(leaf, subleaf);
        const cacheType = r.eax & 0x1f;
        if (cacheType == 0) break;
        if (cacheType == 2) continue;
        const level = (r.eax >> 5) & 0x7;
        const ways = ((r.ebx >> 22) & 0x3ff) + 1;
        const partitions = ((r.ebx >> 12) & 0x3ff) + 1;
        const lineSize = (r.ebx & 0xfff) + 1;
        const sets = r.ecx + 1;
        const bytes = @as(usize, ways) * partitions * lineSize * sets;
        switch (level) {
            1 => profile.l1dBytes = bytes,
            2 => profile.l2Bytes = bytes,
            3 => profile.l3Bytes = bytes,
            else => {},
        }
    }
    if (profile.l1dBytes == 0) return null;
    return profile;
}
