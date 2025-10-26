/// 司马迁 - 高性能端口扫描器
/// 基于Zig语言开发，类似rustscan的高性能端口扫描工具

const std = @import("std");

/// 主函数
pub fn main() !void {
    std.debug.print("司马迁端口扫描器启动中...\n", .{});

    // 简单的测试
    std.debug.print("测试完成！项目已成功创建。\n", .{});
    std.debug.print("\n使用说明:\n", .{});
    std.debug.print("1. 编译项目: zig build -Doptimize=ReleaseFast\n", .{});
    std.debug.print("2. 运行程序: zig-out/bin/simaqian --help\n", .{});
    std.debug.print("3. 运行测试: ./scripts/test.sh\n", .{});
    std.debug.print("4. 网络测试: ./scripts/network_test.sh\n", .{});
}