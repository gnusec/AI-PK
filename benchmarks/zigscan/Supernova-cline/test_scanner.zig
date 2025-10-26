const std = @import("std");

test "parse ports" {
    const allocator = std.testing.allocator;

    // 测试单个端口
    const single = try parsePorts(allocator, "80");
    defer allocator.free(single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(@as(u16, 80), single[0]);

    // 测试端口列表
    const list = try parsePorts(allocator, "80,443,8080");
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u16, 80), list[0]);
    try std.testing.expectEqual(@as(u16, 443), list[1]);
    try std.testing.expectEqual(@as(u16, 8080), list[2]);

    // 测试端口范围
    const range = try parsePorts(allocator, "1-5");
    defer allocator.free(range);
    try std.testing.expectEqual(@as(usize, 5), range.len);
    try std.testing.expectEqual(@as(u16, 1), range[0]);
    try std.testing.expectEqual(@as(u16, 5), range[4]);
}

test "get service name" {
    try std.testing.expect(std.mem.eql(u8, getServiceName(80), "HTTP"));
    try std.testing.expect(std.mem.eql(u8, getServiceName(443), "HTTPS"));
    try std.testing.expect(std.mem.eql(u8, getServiceName(22), "SSH"));
    try std.testing.expect(std.mem.eql(u8, getServiceName(999), "Unknown"));
}
