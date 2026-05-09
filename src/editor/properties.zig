const tools = @import("tools.zig");
const schema = @import("../map/schema.zig");

pub fn kindLabel(kind: schema.ObjectKind) []const u8 {
    return tools.objectKindName(kind);
}

