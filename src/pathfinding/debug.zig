pub const PathDebugData = struct {
    sector_count: usize = 0,
    portal_count: usize = 0,
    portal_edge_count: usize = 0,
    last_route_portals: usize = 0,
    path_cache_hits: usize = 0,
    path_cache_misses: usize = 0,
    flow_cache_hits: usize = 0,
    flow_cache_misses: usize = 0,
};

