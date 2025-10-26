/// Zig构建系统配置文件
/// 定义项目构建规则和测试流程

const std = @import("std");

/// 构建函数
pub fn build(b: *std.Build) void {
    // 获取优化选项
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // 创建主程序模块
    const scanner_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const args_mod = b.createModule(.{
        .root_source_file = b.path("src/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const output_mod = b.createModule(.{
        .root_source_file = b.path("src/output.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 主程序
    const exe = b.addExecutable(.{
        .name = "simaqian",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scanner", .module = scanner_mod },
                .{ .name = "args", .module = args_mod },
                .{ .name = "output", .module = output_mod },
            },
        }),
    });

    // 安装主程序
    b.installArtifact(exe);

    // 运行主程序的快捷方式
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // 如果传递了参数，则将其传递给程序
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // 创建运行步骤
    const run_step = b.step("run", "运行端口扫描器");
    run_step.dependOn(&run_cmd.step);

    // 创建测试步骤
    const test_step = b.step("test", "运行所有测试");

    // 主测试
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_scanner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scanner", .module = scanner_mod },
                .{ .name = "args", .module = args_mod },
                .{ .name = "output", .module = output_mod },
            },
        }),
    });

    // 单元测试
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scanner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const args_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/args.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const output_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/output.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 添加测试步骤依赖
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(args_tests).step);
    test_step.dependOn(&b.addRunArtifact(output_tests).step);

    // 创建文档步骤
    const docs_step = b.step("docs", "生成文档");
    const docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);

    // 创建清理步骤
    const clean_step = b.step("clean", "清理构建产物");
    const install_path = b.getInstallPath(.bin, "");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = install_path }).step);

    // 创建格式化步骤
    const fmt_step = b.step("fmt", "格式化所有Zig源代码");
    const fmt_cmd = b.addFmt(.{
        .paths = &.{
            "src/",
            "test_scanner.zig",
            "build.zig",
        },
    });
    fmt_step.dependOn(&fmt_cmd.step);

    // 创建检查步骤（编译但不运行）
    const check_step = b.step("check", "检查代码语法和类型");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&main_tests.step);
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&args_tests.step);
    check_step.dependOn(&output_tests.step);

    // 创建发布构建步骤
    const release_step = b.step("release", "创建发布版本");
    const release_exe = b.addExecutable(.{
        .name = "simaqian",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "scanner", .module = scanner_mod },
                .{ .name = "args", .module = args_mod },
                .{ .name = "output", .module = output_mod },
            },
        }),
    });

    // 剥离调试信息以减小二进制文件大小
    release_exe.root_module.strip = true;

    const release_install = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&release_install.step);

    // 创建性能测试步骤
    const benchmark_step = b.step("benchmark", "运行性能基准测试");
    const benchmark_cmd = b.addRunArtifact(main_tests);
    benchmark_cmd.addArgs(&.{"--benchmark"});
    benchmark_step.dependOn(&benchmark_cmd.step);

    // 创建内存泄漏检查步骤
    const leak_check_step = b.step("leak-check", "检查内存泄漏");
    const leak_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_scanner.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "scanner", .module = scanner_mod },
                .{ .name = "args", .module = args_mod },
                .{ .name = "output", .module = output_mod },
            },
        }),
    });

    // 启用内存泄漏检测
    leak_test.root_module.sanitize_thread = true;

    leak_check_step.dependOn(&b.addRunArtifact(leak_test).step);

    // 创建全量检查步骤（包括所有检查）
    const full_check_step = b.step("full-check", "运行所有检查（测试、格式、语法）");
    full_check_step.dependOn(test_step);
    full_check_step.dependOn(&fmt_cmd.step);
    full_check_step.dependOn(check_step);

    // 设置默认步骤
    b.default_step.dependOn(&exe.step);
}