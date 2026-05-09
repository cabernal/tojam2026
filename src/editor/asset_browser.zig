const assets = @import("../assets/asset_loader.zig");

pub fn nextAssetOfKind(catalog: *const assets.AssetCatalog, start: u16, kind: assets.AssetKind) ?u16 {
    if (catalog.assets.items.len == 0) return null;
    var i: usize = @min(start + 1, catalog.assets.items.len);
    while (i < catalog.assets.items.len) : (i += 1) {
        if (catalog.assets.items[i].kind == kind) return @intCast(i);
    }
    for (catalog.assets.items[0..@min(start + 1, catalog.assets.items.len)], 0..) |asset, idx| {
        if (asset.kind == kind) return @intCast(idx);
    }
    return null;
}

