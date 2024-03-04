const std = @import("std");

const userpath = "user";
const cflags = &[_][]const u8{
    "-Wall", "-Werror", "-Wno-gnu-designator", "-Wno-unused-variable",
    "-Wno-unused-but-set-variable", "-O3",
    "-I./", "-mno-relax", "-fno-pie", "-fno-stack-protector",
    "-fno-common", "-fno-omit-frame-pointer", "-mcmodel=medany"
};
const ulibNames = [_][]const u8 {
    "ulib.c", "umalloc.c", "printf.c", "usys.S",
};
var ulib: [ulibNames.len]*std.Build.Step.Compile = undefined;
const usys = &ulib[idx: {
    for (ulibNames, 0..) |n, i| {
        if (std.mem.eql(u8, n, "usys.S")) {
            break :idx i;
        }
    }
}];

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const features = std.Target.riscv.Feature;
    var enabled = std.Target.Cpu.Feature.Set.empty;

    enabled.addFeature(@intFromEnum(features.zicsr));
    enabled.addFeature(@intFromEnum(features.a));
    enabled.addFeature(@intFromEnum(features.c));

    const target = getTarget(b);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .target = target,
        .optimize = .ReleaseFast, // Debug doesn't work, emits illegal instructions (???)
        .strip = false,
    });
    kernel.addCSourceFiles(.{
        .root = .{.path = "kernel/"},
        .files = &[_][]const u8{
            "entry.S", "bio.c", "console.c", "exec.c", "file.c", "fs.c", 
            "kalloc.c", "log.c", "main.c", "pipe.c", "plic.c", "printf.c", 
            "proc.c", "sleeplock.c", "spinlock.c", "start.c", "string.c", 
            "syscall.c", "sysfile.c", "sysproc.c", "trap.c", "uart.c", 
            "virtio_disk.c", "vm.c", "kernelvec.S", "swtch.S", "trampoline.S"
        },
        .flags = cflags,

    });
    kernel.setLinkerScript(.{ .path = "kernel/kernel.ld" });
    kernel.entry = .{ .symbol_name = "_entry" };
    kernel.link_z_max_page_size = 4096;

    b.installArtifact(kernel);

    const usysGen = b.addSystemCommand(&[_][]const u8 {
        "sh", "-c", "perl user/usys.pl > user/usys.S"
    });

    for (ulibNames, 0..) |u, i| {
        const obj = b.addObject(.{
            .name = u[0..u.len-2],
            .target = target,
            .optimize = .ReleaseFast,
        });
        const path = try std.fs.path.join(
            gpa.allocator(),
            &[_][]const u8 {
                "user", u,
            },
        );
        defer gpa.allocator().free(path);
        obj.addCSourceFile(.{
            .file = .{.path = path},
            .flags = cflags,
        });
        ulib[i] = obj;
    }
    usys.*.step.dependOn(&usysGen.step);
    

    var userprogs = std.ArrayList(*std.Build.Step.Compile).init(
        gpa.allocator());
    defer userprogs.deinit();

    var dir = try std.fs.cwd().openDir(userpath, .{.iterate = true});
    var iter = dir.iterate();
    l: while (try iter.next()) |entry| {
        const name: []const u8 = entry.name;
        const extension = std.fs.path.extension(name);

        for (ulibNames) |skip| {
            if (std.mem.eql(u8, name, skip)) {
                continue :l;
            }
        }

        const outname = try std.mem.concat(
            gpa.allocator(), u8,
            &[_][]const u8 {
                "_", std.fs.path.stem(name),
            },
        );
        defer gpa.allocator().free(outname);

        var exe: *std.Build.Step.Compile = undefined;
        if (std.mem.eql(u8, extension, ".c")) {
            exe = createCUserProg(b, name, outname);
        } else if (std.mem.eql(u8, extension, ".zig")) {
            exe = createZigUserProg(b, name, outname);
        } else {
            continue;
        }
        

        exe.setLinkerScript(.{ .path = "user/user.ld" });
        exe.entry = .{ .symbol_name = "_main" };
        exe.link_z_max_page_size = 4096;

        b.installArtifact(exe);

        try userprogs.append(exe);
    }

    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .target = b.host,
        .optimize = .ReleaseFast,
    });
    mkfs.addCSourceFile(.{
        .file = .{.path = "mkfs/mkfs.c"},
        .flags = &[_][]const u8 {
            "-Wall", "-Werror", "-I./",
        },
    });
    mkfs.linkLibC();
    b.installArtifact(mkfs);

    
    const buildfs = b.addRunArtifact(mkfs);
    const img = buildfs.addOutputFileArg("fs.img");
    while (userprogs.popOrNull()) |u| {
        buildfs.addFileArg(u.getEmittedBin());
    }
    b.getInstallStep().dependOn(&b.addInstallFile(img, "fs.img").step);

    const qemu = b.addSystemCommand(&[_][]const u8 {
        "qemu-system-riscv64", "-machine", "virt", "-bios", "none", "-m", "128M", 
        "-smp", "3", "-nographic", "-global", "virtio-mmio.force-legacy=false",
        "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
    });
    qemu.addArg("-kernel");
    qemu.addFileArg(kernel.getEmittedBin());
    qemu.addArg("-drive");
    qemu.addPrefixedFileArg("if=none,format=raw,id=x0,file=", img);

    const run = b.step("run", "Run XV6");
    run.dependOn(&qemu.step);
}

fn createCUserProg(b: *std.Build, source: []const u8, name: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .target = getTarget(b),
        .optimize = .ReleaseFast,
    });
    const path = b.pathJoin(
        &[_][]const u8 { userpath, source }
    );
    exe.addCSourceFile(.{
        .file = .{.path=path},
        .flags = cflags,
    });
    for (ulib) |o| {
        exe.addObject(o);
    }
    return exe;
}

fn createZigUserProg(b: *std.Build, source: []const u8, name: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .target = getTarget(b),
        .optimize = .ReleaseSafe,
        .root_source_file = .{.path = b.pathJoin(
            &[_][]const u8 { userpath, source }
        )},
    });
    exe.addIncludePath(.{.path = "./"});
    exe.addObject(usys.*);
    return exe;
}

fn getTarget(b: *std.Build) std.Build.ResolvedTarget {
   return b.resolveTargetQuery(.{
        .cpu_arch = std.Target.Cpu.Arch.riscv64,
        .ofmt = std.Target.ObjectFormat.elf,
        .abi = std.Target.Abi.none,
        .os_tag = std.Target.Os.Tag.freestanding,
    });
}

