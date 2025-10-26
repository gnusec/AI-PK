const std = @import("std");
const scanner = @import("scanner.zig");

pub fn writeTxt(w: anytype, out: *const scanner.ScanOutput) !void {
    try w.print("Scanned {d} target(s). Open ports listed below.\n", .{out.results.len});
    for (out.results) |r| {
        try w.print("{s}: ", .{r.target});
        if (r.open_ports.len == 0) {
            try w.writeAll("(none)\n");
        } else {
            var first = true;
            for (r.open_ports) |p| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{d}", .{p});
            }
            try w.writeAll("\n");
        }
    }
    try w.print(
        "Done in {d} ms. Tasks: {d}, Open: {d}.\n",
        .{ out.stats.duration_ms, out.stats.total_tasks, out.stats.open_count },
    );
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeAll(s[i .. i + 1]),
        }
    }
    try w.writeAll("\"");
}

pub fn writeJson(w: anytype, out: *const scanner.ScanOutput) !void {
    try w.writeAll("{\n  \"stats\": {\n");
    try w.print("    \"duration_ms\": {d},\n", .{out.stats.duration_ms});
    try w.print("    \"total_tasks\": {d},\n", .{out.stats.total_tasks});
    try w.print("    \"open_count\": {d}\n", .{out.stats.open_count});
    try w.writeAll("  },\n  \"results\": [\n");
    var idx: usize = 0;
    while (idx < out.results.len) : (idx += 1) {
        const r = out.results[idx];
        try w.writeAll("    { \"target\": ");
        try writeJsonString(w, r.target);
        try w.writeAll(", \"open_ports\": [");
        var j: usize = 0;
        while (j < r.open_ports.len) : (j += 1) {
            try w.print("{d}", .{r.open_ports[j]});
            if (j + 1 < r.open_ports.len) try w.writeAll(", ");
        }
        try w.writeAll("] }");
        if (idx + 1 < out.results.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");
}
