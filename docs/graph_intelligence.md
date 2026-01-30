# Graph Intelligence for beads_zig

## Overview

This document specifies the addition of graph-theoretic analysis commands to beads_zig (`bz`). The goal is to provide actionable insights about project health, execution order, and bottlenecks—all from a single ~50KB binary.

**Design principles:**
- Single binary, no external dependencies
- Human-readable by default, `--json` for agents
- Fast enough to run on every command (sub-millisecond for typical repos)
- Algorithms chosen for practical value, not academic completeness

---

## Table of Contents

1. [Data Model](#data-model)
2. [CLI Interface](#cli-interface)
3. [Algorithms](#algorithms)
4. [Implementation](#implementation)
5. [Output Formats](#output-formats)
6. [Agent Integration](#agent-integration)
7. [Phased Rollout](#phased-rollout)

---

## Data Model

### Issue Graph Representation

```zig
const IssueId = []const u8;  // e.g., "AUTH-123"

const Issue = struct {
    id: IssueId,
    title: []const u8,
    status: Status,
    priority: u8,  // 0 = critical, 4 = backlog
    blocks: []IssueId,      // Issues that depend on this
    blocked_by: []IssueId,  // Issues this depends on
    labels: [][]const u8,
    assignee: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

const Status = enum {
    open,
    in_progress,
    blocked,
    closed,
    
    pub fn isOpen(self: Status) bool {
        return self != .closed;
    }
};
```

### Adjacency Representation

For graph algorithms, we convert to index-based adjacency lists:

```zig
const Graph = struct {
    n: usize,  // Number of nodes (issues)
    
    // Issue ID -> node index
    id_to_index: std.StringHashMap(u32),
    // Node index -> Issue ID  
    index_to_id: []IssueId,
    
    // Adjacency lists (index-based)
    // out_edges[i] = list of nodes that i blocks (i -> j means i must complete before j)
    out_edges: [][]u32,
    // in_edges[i] = list of nodes that block i (j -> i means j must complete before i)
    in_edges: [][]u32,
    
    // Quick access to issue data by index
    statuses: []Status,
    priorities: []u8,
    
    pub fn fromIssues(allocator: Allocator, issues: []const Issue) !Graph {
        // Build id_to_index mapping
        // Build adjacency lists
        // Only include open issues in graph (closed issues are "done")
    }
    
    pub fn outDegree(self: *Graph, node: u32) u32 {
        return @intCast(self.out_edges[node].len);
    }
    
    pub fn inDegree(self: *Graph, node: u32) u32 {
        return @intCast(self.in_edges[node].len);
    }
};
```

### Graph Scope

**Important decision:** The dependency graph only includes **open** issues by default.

Rationale:
- Closed issues are "done"—they don't block anything
- Including closed issues inflates metrics meaninglessly
- Critical path through closed issues is irrelevant

Option: `--include-closed` flag for historical analysis.

---

## CLI Interface

### Command Overview

```
bz                      # Default: list open issues
bz add <title>          # Create issue
bz show <id>            # Show issue details
bz update <id> ...      # Update issue
bz close <id>           # Close issue

# === Graph Intelligence ===
bz status               # Quick health summary
bz ready                # List actionable issues (no blockers)
bz blocked              # List blocked issues
bz plan                 # Execution order (topo sort)
bz cycles               # Detect and list cycles
bz critical             # Show critical path
bz bottlenecks          # Show high-impact issues
bz insights             # Full analysis report

# === Modifiers ===
--json                  # Machine-readable output
--top=N                 # Limit results (default: 10)
--verbose               # Include explanations
```

### Command Details

#### `bz status`
Quick health check. Should run in <1ms.

```
$ bz status

beads: my-project/.beads
───────────────────────────
  47 open    12 blocked    35 ready
  ⚠️  2 cycles detected
  
Critical path: 7 issues deep
Highest blocker: AUTH-001 (blocks 5)
```

With `--json`:
```json
{
  "total_open": 47,
  "blocked": 12,
  "ready": 35,
  "cycles": 2,
  "critical_path_length": 7,
  "top_blocker": {
    "id": "AUTH-001",
    "blocks_count": 5
  }
}
```

#### `bz ready`
Issues with no open blockers—what you can work on right now.

```
$ bz ready

Ready to work (35 issues):
───────────────────────────
P0  AUTH-001   Implement OAuth flow
P1  UI-042     Login page styling
P1  API-017    Rate limiting middleware
P2  DOCS-003   Update README
...

Tip: Complete AUTH-001 first (unblocks 5 others)
```

Sorted by:
1. Priority (P0 first)
2. Unblock count (higher first)
3. Created date (older first)

#### `bz blocked`
Issues waiting on dependencies.

```
$ bz blocked

Blocked issues (12):
───────────────────────────
UI-099     Waiting on: AUTH-001, API-017
FEAT-042   Waiting on: DB-001
...
```

#### `bz plan`
Topologically sorted execution order.

```
$ bz plan

Execution Plan (47 issues):
═══════════════════════════

Phase 1 (parallel):
  AUTH-001   Implement OAuth flow
  DB-001     Schema migration
  DOCS-003   Update README

Phase 2 (after phase 1):
  API-017    Rate limiting middleware
  UI-042     Login page styling

Phase 3:
  ...
```

The "phases" are computed by finding all issues with in-degree 0 (ready), then removing them and repeating.

#### `bz cycles`
Detect and report circular dependencies.

```
$ bz cycles

⚠️  2 dependency cycles detected:
───────────────────────────────────

Cycle 1:
  AUTH-001 → API-005 → AUTH-001
  
  AUTH-001 blocks API-005
  API-005 blocks AUTH-001  ← break here?

Cycle 2:
  FEAT-010 → FEAT-011 → FEAT-012 → FEAT-010
  
Cycles make issues uncompletable. Use 'bz unblock' to remove a dependency.
```

#### `bz critical`
Show the critical path (longest dependency chain).

```
$ bz critical

Critical Path (7 issues):
═════════════════════════
Any delay here delays the entire project.

DB-001     Schema migration
  ↓
AUTH-001   Implement OAuth flow
  ↓
API-005    Auth middleware
  ↓
API-017    Protected endpoints
  ↓
UI-042     Dashboard components
  ↓
UI-099     User settings page
  ↓
FEAT-100   Beta release checklist

Total depth: 7
Estimated: 7 * avg_issue_time
```

#### `bz bottlenecks`
Issues that block the most downstream work.

```
$ bz bottlenecks

Top Blockers:
═════════════
                          Direct    Total
AUTH-001   OAuth flow        5        12
DB-001     Schema            3         9
API-005    Auth middleware   4         7
...

"Direct" = immediate dependents
"Total" = all transitive dependents
```

#### `bz insights`
Full analysis report combining all metrics.

```
$ bz insights

═══════════════════════════════════════════
  beads intelligence report
═══════════════════════════════════════════

Health
──────
Open: 47  Blocked: 12  Ready: 35  Cycles: 0 ✓

Critical Path (depth: 7)
────────────────────────
DB-001 → AUTH-001 → API-005 → API-017 → UI-042 → UI-099 → FEAT-100

Top Blockers (by transitive impact)
───────────────────────────────────
1. AUTH-001   OAuth flow           impact: 12
2. DB-001     Schema migration     impact: 9
3. API-005    Auth middleware      impact: 7

Recommendations
───────────────
• Start with: AUTH-001 (highest impact, ready)
• Parallelize: DB-001, DOCS-003, UI-001 (independent)
• Watch: API-005 (on critical path, high blocker)

Ready queue (top 5):
────────────────────
P0  AUTH-001   Implement OAuth flow
P1  DB-001     Schema migration
P1  UI-001     Base component library
P2  DOCS-003   Update README
P3  TEST-001   CI pipeline setup
```

---

## Algorithms

### 1. Cycle Detection

**Algorithm:** DFS with three-color marking (white/gray/black)

**Complexity:** O(V + E)

```zig
const Color = enum { white, gray, black };

const CycleDetector = struct {
    graph: *const Graph,
    colors: []Color,
    parent: []?u32,
    cycles: std.ArrayList([]u32),
    
    pub fn init(allocator: Allocator, graph: *const Graph) CycleDetector {
        return .{
            .graph = graph,
            .colors = allocator.alloc(Color, graph.n),
            .parent = allocator.alloc(?u32, graph.n),
            .cycles = std.ArrayList([]u32).init(allocator),
        };
    }
    
    pub fn findCycles(self: *CycleDetector) ![][]u32 {
        @memset(self.colors, .white);
        @memset(self.parent, null);
        
        for (0..self.graph.n) |i| {
            if (self.colors[i] == .white) {
                try self.dfs(@intCast(i));
            }
        }
        
        return self.cycles.items;
    }
    
    fn dfs(self: *CycleDetector, node: u32) !void {
        self.colors[node] = .gray;
        
        for (self.graph.out_edges[node]) |neighbor| {
            if (self.colors[neighbor] == .gray) {
                // Back edge found - cycle!
                try self.recordCycle(node, neighbor);
            } else if (self.colors[neighbor] == .white) {
                self.parent[neighbor] = node;
                try self.dfs(neighbor);
            }
        }
        
        self.colors[node] = .black;
    }
    
    fn recordCycle(self: *CycleDetector, from: u32, to: u32) !void {
        var cycle = std.ArrayList(u32).init(self.allocator);
        
        var current = from;
        try cycle.append(to);
        while (current != to) {
            try cycle.append(current);
            current = self.parent[current] orelse break;
        }
        try cycle.append(to);  // Close the cycle
        
        std.mem.reverse(u32, cycle.items);
        try self.cycles.append(cycle.items);
    }
};
```

### 2. Topological Sort

**Algorithm:** Kahn's algorithm (BFS-based)

**Complexity:** O(V + E)

**Advantage:** Also detects cycles (if not all nodes processed, cycle exists)

```zig
const TopoSort = struct {
    pub fn sort(allocator: Allocator, graph: *const Graph) !?[]u32 {
        var in_degree = try allocator.alloc(u32, graph.n);
        defer allocator.free(in_degree);
        
        // Calculate in-degrees
        for (0..graph.n) |i| {
            in_degree[i] = @intCast(graph.in_edges[i].len);
        }
        
        // Queue of nodes with in-degree 0
        var queue = std.ArrayList(u32).init(allocator);
        defer queue.deinit();
        
        for (0..graph.n) |i| {
            if (in_degree[i] == 0) {
                try queue.append(@intCast(i));
            }
        }
        
        var result = std.ArrayList(u32).init(allocator);
        
        while (queue.items.len > 0) {
            const node = queue.orderedRemove(0);
            try result.append(node);
            
            for (graph.out_edges[node]) |neighbor| {
                in_degree[neighbor] -= 1;
                if (in_degree[neighbor] == 0) {
                    try queue.append(neighbor);
                }
            }
        }
        
        // If we didn't process all nodes, there's a cycle
        if (result.items.len != graph.n) {
            return null;  // Cycle detected
        }
        
        return result.toOwnedSlice();
    }
};
```

### 3. Phased Execution Plan

**Algorithm:** Iterative layer extraction

**Complexity:** O(V + E)

Groups issues into "phases" where each phase can be executed in parallel.

```zig
const PhasedPlan = struct {
    phases: [][]u32,
    
    pub fn compute(allocator: Allocator, graph: *const Graph) !?PhasedPlan {
        var in_degree = try allocator.alloc(u32, graph.n);
        defer allocator.free(in_degree);
        
        var remaining = std.DynamicBitSet.initFull(allocator, graph.n);
        defer remaining.deinit();
        
        // Calculate initial in-degrees (only from remaining nodes)
        for (0..graph.n) |i| {
            in_degree[i] = @intCast(graph.in_edges[i].len);
        }
        
        var phases = std.ArrayList([]u32).init(allocator);
        
        while (remaining.count() > 0) {
            var phase = std.ArrayList(u32).init(allocator);
            
            // Find all nodes with in-degree 0
            var iter = remaining.iterator(.{});
            while (iter.next()) |i| {
                if (in_degree[i] == 0) {
                    try phase.append(@intCast(i));
                }
            }
            
            // No nodes with in-degree 0 but nodes remain = cycle
            if (phase.items.len == 0) {
                return null;
            }
            
            // Remove phase nodes, update in-degrees
            for (phase.items) |node| {
                remaining.unset(node);
                for (graph.out_edges[node]) |neighbor| {
                    in_degree[neighbor] -= 1;
                }
            }
            
            try phases.append(phase.toOwnedSlice());
        }
        
        return .{ .phases = phases.toOwnedSlice() };
    }
};
```

### 4. Critical Path (Longest Path in DAG)

**Algorithm:** Dynamic programming on topological order

**Complexity:** O(V + E)

```zig
const CriticalPath = struct {
    // depth[i] = length of longest path ending at node i
    depth: []u32,
    // parent[i] = predecessor on longest path
    parent: []?u32,
    
    pub fn compute(allocator: Allocator, graph: *const Graph) !?CriticalPath {
        const topo_order = TopoSort.sort(allocator, graph) orelse return null;
        defer allocator.free(topo_order);
        
        var depth = try allocator.alloc(u32, graph.n);
        var parent = try allocator.alloc(?u32, graph.n);
        
        @memset(depth, 0);
        @memset(parent, null);
        
        // Process in topological order
        for (topo_order) |node| {
            for (graph.out_edges[node]) |neighbor| {
                const new_depth = depth[node] + 1;
                if (new_depth > depth[neighbor]) {
                    depth[neighbor] = new_depth;
                    parent[neighbor] = node;
                }
            }
        }
        
        return .{ .depth = depth, .parent = parent };
    }
    
    pub fn maxDepth(self: *CriticalPath) u32 {
        return std.mem.max(u32, self.depth);
    }
    
    pub fn extractPath(self: *CriticalPath, allocator: Allocator) ![]u32 {
        // Find node with maximum depth
        var max_node: u32 = 0;
        var max_depth: u32 = 0;
        for (self.depth, 0..) |d, i| {
            if (d > max_depth) {
                max_depth = d;
                max_node = @intCast(i);
            }
        }
        
        // Walk backwards to reconstruct path
        var path = std.ArrayList(u32).init(allocator);
        var current: ?u32 = max_node;
        while (current) |node| {
            try path.append(node);
            current = self.parent[node];
        }
        
        std.mem.reverse(u32, path.items);
        return path.toOwnedSlice();
    }
};
```

### 5. Transitive Impact (Reachability Count)

**Algorithm:** DFS from each node, count reachable

**Complexity:** O(V * (V + E)) — acceptable for small graphs

```zig
const ImpactAnalysis = struct {
    // direct_impact[i] = number of immediate dependents
    direct: []u32,
    // total_impact[i] = number of transitive dependents
    total: []u32,
    
    pub fn compute(allocator: Allocator, graph: *const Graph) !ImpactAnalysis {
        var direct = try allocator.alloc(u32, graph.n);
        var total = try allocator.alloc(u32, graph.n);
        
        for (0..graph.n) |i| {
            direct[i] = @intCast(graph.out_edges[i].len);
            total[i] = countReachable(graph, @intCast(i));
        }
        
        return .{ .direct = direct, .total = total };
    }
    
    fn countReachable(graph: *const Graph, start: u32) u32 {
        var visited = std.DynamicBitSet.initEmpty(graph.n);
        defer visited.deinit();
        
        var stack = std.ArrayList(u32).init(allocator);
        defer stack.deinit();
        
        try stack.append(start);
        
        while (stack.items.len > 0) {
            const node = stack.pop();
            if (visited.isSet(node)) continue;
            visited.set(node);
            
            for (graph.out_edges[node]) |neighbor| {
                if (!visited.isSet(neighbor)) {
                    try stack.append(neighbor);
                }
            }
        }
        
        return @intCast(visited.count() - 1);  // Exclude start node
    }
};
```

**Optimization for large graphs:** Use BFS with bitset, or precompute strongly connected components.

### 6. PageRank (Optional, Phase 2)

**Algorithm:** Power iteration

**Complexity:** O(iterations * E), typically 20-50 iterations

```zig
const PageRank = struct {
    scores: []f32,
    
    pub fn compute(
        allocator: Allocator, 
        graph: *const Graph,
        damping: f32,      // Usually 0.85
        tolerance: f32,    // Usually 1e-6
        max_iter: u32,     // Usually 100
    ) !PageRank {
        const n = graph.n;
        const n_f: f32 = @floatFromInt(n);
        
        var scores = try allocator.alloc(f32, n);
        var new_scores = try allocator.alloc(f32, n);
        defer allocator.free(new_scores);
        
        // Initialize uniformly
        @memset(scores, 1.0 / n_f);
        
        for (0..max_iter) |_| {
            // Base score (random jump)
            const base = (1.0 - damping) / n_f;
            @memset(new_scores, base);
            
            // Distribute scores along edges
            for (0..n) |i| {
                const out_deg = graph.out_edges[i].len;
                if (out_deg == 0) continue;
                
                const contribution = damping * scores[i] / @as(f32, @floatFromInt(out_deg));
                for (graph.out_edges[i]) |neighbor| {
                    new_scores[neighbor] += contribution;
                }
            }
            
            // Check convergence
            var diff: f32 = 0;
            for (0..n) |i| {
                diff += @abs(new_scores[i] - scores[i]);
            }
            
            std.mem.swap([]f32, &scores, &new_scores);
            
            if (diff < tolerance) break;
        }
        
        return .{ .scores = scores };
    }
};
```

### Algorithm Summary

| Algorithm | Complexity | When to Use |
|-----------|------------|-------------|
| Cycle Detection | O(V + E) | Always (health check) |
| Topological Sort | O(V + E) | `plan`, `critical` |
| Phased Plan | O(V + E) | `plan` |
| Critical Path | O(V + E) | `critical`, `insights` |
| Impact Analysis | O(V² + VE) | `bottlenecks`, `ready` |
| PageRank | O(iter * E) | `insights --full` |

For typical repos (V < 500, E < 2000), all algorithms complete in <10ms.

---

## Implementation

### Module Structure

```
src/
  main.zig              # CLI entry point
  commands/
    status.zig          # bz status
    ready.zig           # bz ready
    blocked.zig         # bz blocked
    plan.zig            # bz plan
    cycles.zig          # bz cycles
    critical.zig        # bz critical
    bottlenecks.zig     # bz bottlenecks
    insights.zig        # bz insights
  graph/
    graph.zig           # Graph data structure
    cycles.zig          # Cycle detection
    topo.zig            # Topological sort
    critical_path.zig   # Critical path
    impact.zig          # Impact analysis
    pagerank.zig        # PageRank (optional)
  storage/
    jsonl.zig           # JSONL loading/saving
  output/
    terminal.zig        # Human-readable formatting
    json.zig            # JSON output
```

### Shared Analysis Context

```zig
const AnalysisContext = struct {
    allocator: Allocator,
    issues: []Issue,
    graph: Graph,
    
    // Lazily computed
    topo_order: ?[]u32 = null,
    cycles: ?[][]u32 = null,
    critical_path: ?CriticalPath = null,
    impact: ?ImpactAnalysis = null,
    
    pub fn init(allocator: Allocator, issues: []Issue) !AnalysisContext {
        return .{
            .allocator = allocator,
            .issues = issues,
            .graph = try Graph.fromIssues(allocator, issues),
        };
    }
    
    pub fn getTopoOrder(self: *AnalysisContext) ?[]u32 {
        if (self.topo_order == null) {
            self.topo_order = TopoSort.sort(self.allocator, &self.graph);
        }
        return self.topo_order;
    }
    
    pub fn getCycles(self: *AnalysisContext) [][]u32 {
        if (self.cycles == null) {
            var detector = CycleDetector.init(self.allocator, &self.graph);
            self.cycles = detector.findCycles() catch &[_][]u32{};
        }
        return self.cycles.?;
    }
    
    pub fn hasCycles(self: *AnalysisContext) bool {
        return self.getCycles().len > 0;
    }
    
    // ... other lazy getters
};
```

### Terminal Output Helpers

```zig
const term = @import("output/terminal.zig");

pub fn printStatus(ctx: *AnalysisContext) void {
    const open = countByStatus(ctx.issues, .open);
    const blocked = countBlocked(ctx);
    const ready = open - blocked;
    const cycles = ctx.getCycles().len;
    
    term.header("beads: {s}", .{ctx.path});
    term.separator();
    
    term.stats(&[_]term.Stat{
        .{ .label = "open", .value = open, .color = .green },
        .{ .label = "blocked", .value = blocked, .color = .yellow },
        .{ .label = "ready", .value = ready, .color = .cyan },
    });
    
    if (cycles > 0) {
        term.warning("⚠️  {d} cycles detected", .{cycles});
    }
    
    if (ctx.getCriticalPath()) |cp| {
        term.info("Critical path: {d} issues deep", .{cp.maxDepth()});
    }
    
    if (ctx.getTopBlocker()) |blocker| {
        term.info("Highest blocker: {s} (blocks {d})", .{
            blocker.id, blocker.impact
        });
    }
}
```

---

## Output Formats

### Human-Readable (Default)

Design principles:
- Minimal decoration, maximum information density
- Color for status, not decoration
- Aligned columns where useful
- Actionable recommendations at the end

Example:
```
Ready to work (35 issues):
───────────────────────────
P0  AUTH-001   Implement OAuth flow
P1  UI-042     Login page styling
P1  API-017    Rate limiting middleware
P2  DOCS-003   Update README

Tip: Complete AUTH-001 first (unblocks 5 others)
```

### JSON (--json)

Design principles:
- Stable schema (document changes)
- Include metadata (timestamp, version)
- Arrays for ordered data, objects for keyed data
- Nested structure mirrors CLI sections

```json
{
  "meta": {
    "version": "0.1.0",
    "generated_at": "2025-01-29T10:30:00Z",
    "beads_path": ".beads/beads.jsonl"
  },
  "summary": {
    "total_open": 47,
    "blocked": 12,
    "ready": 35,
    "cycles": 0,
    "critical_path_length": 7
  },
  "ready": [
    {
      "id": "AUTH-001",
      "title": "Implement OAuth flow",
      "priority": 0,
      "unblocks": 5,
      "labels": ["auth", "backend"],
      "assignee": null
    }
  ],
  "critical_path": ["DB-001", "AUTH-001", "API-005", "API-017", "UI-042"],
  "bottlenecks": [
    {
      "id": "AUTH-001",
      "direct_impact": 5,
      "total_impact": 12
    }
  ],
  "cycles": []
}
```

---

## Agent Integration

### Recommended Agent Workflow

```bash
#!/bin/bash
# agent-loop.sh

# 1. Check health
STATUS=$(bz status --json)
CYCLES=$(echo "$STATUS" | jq '.summary.cycles')

if [ "$CYCLES" -gt 0 ]; then
    echo "ERROR: Dependency cycles detected"
    bz cycles --json
    exit 1
fi

# 2. Get next task
NEXT=$(bz ready --json | jq -r '.ready[0].id')

if [ -z "$NEXT" ]; then
    echo "No actionable tasks"
    exit 0
fi

echo "Working on: $NEXT"

# 3. Do work...

# 4. Mark complete
bz close "$NEXT"

# 5. Show what's unblocked
bz ready --json | jq '.ready[:5]'
```

### MCP Tool Definitions

For Claude/MCP integration:

```json
{
  "tools": [
    {
      "name": "beads_status",
      "description": "Get project health summary including open/blocked counts and cycle detection",
      "input_schema": {
        "type": "object",
        "properties": {}
      }
    },
    {
      "name": "beads_ready",
      "description": "Get list of actionable issues with no blockers, sorted by impact",
      "input_schema": {
        "type": "object",
        "properties": {
          "top": {
            "type": "number",
            "description": "Maximum issues to return",
            "default": 10
          }
        }
      }
    },
    {
      "name": "beads_plan",
      "description": "Get execution plan with parallel phases respecting dependencies",
      "input_schema": {
        "type": "object",
        "properties": {}
      }
    }
  ]
}
```

### AGENTS.md Snippet

```markdown
### Using beads_zig (bz) for task management

bz is a local-first issue tracker with built-in dependency intelligence.

**Always use --json flag for programmatic access.**

Key commands:
- `bz status --json` — Health check: open/blocked counts, cycle detection
- `bz ready --json` — Actionable tasks sorted by impact
- `bz plan --json` — Full execution plan with parallel phases
- `bz cycles --json` — Circular dependency details (must fix before proceeding)

Workflow:
1. Check `bz status --json` for cycles (block if cycles > 0)
2. Get next task from `bz ready --json`
3. Complete task
4. Run `bz close <id>`
5. Repeat

The `unblocks` field tells you how many tasks become actionable after completing each issue. Prioritize high-unblock tasks to maximize parallelism.
```

---

## Phased Rollout

### Phase 1: Core (MVP)
Estimated: 2-3 days

- [ ] Graph data structure from JSONL
- [ ] Cycle detection
- [ ] Topological sort
- [ ] `bz status` command
- [ ] `bz ready` command
- [ ] `bz plan` command
- [ ] `bz cycles` command
- [ ] `--json` flag for all

### Phase 2: Analysis
Estimated: 1-2 days

- [ ] Critical path calculation
- [ ] `bz critical` command
- [ ] Impact analysis (transitive dependents)
- [ ] `bz bottlenecks` command
- [ ] `bz blocked` command

### Phase 3: Insights
Estimated: 1-2 days

- [ ] `bz insights` command (combines all)
- [ ] Recommendation engine ("start with X")
- [ ] `--verbose` explanations
- [ ] Terminal formatting polish

### Phase 4: Polish (Optional)
Estimated: 1 day

- [ ] PageRank implementation
- [ ] Watch mode (re-analyze on file change)
- [ ] Performance benchmarks
- [ ] Integration tests with sample repos

---

## Appendix: Performance Targets

| Command | 100 issues | 500 issues | 1000 issues |
|---------|------------|------------|-------------|
| `status` | <1ms | <5ms | <10ms |
| `ready` | <1ms | <5ms | <10ms |
| `plan` | <1ms | <5ms | <10ms |
| `cycles` | <1ms | <5ms | <10ms |
| `critical` | <1ms | <5ms | <10ms |
| `bottlenecks` | <5ms | <20ms | <50ms |
| `insights` | <10ms | <30ms | <100ms |

Memory targets:
- Base overhead: <1MB
- Per issue: ~500 bytes (including graph edges)
- 1000 issues: <2MB total

---

## Appendix: Example Outputs

### `bz insights --json` (Complete)

```json
{
  "meta": {
    "version": "0.1.0",
    "generated_at": "2025-01-29T10:30:00Z"
  },
  "health": {
    "total_open": 47,
    "blocked": 12,
    "ready": 35,
    "cycles": 0,
    "critical_path_length": 7,
    "graph_density": 0.043
  },
  "critical_path": {
    "length": 7,
    "issues": [
      {"id": "DB-001", "title": "Schema migration"},
      {"id": "AUTH-001", "title": "Implement OAuth flow"},
      {"id": "API-005", "title": "Auth middleware"},
      {"id": "API-017", "title": "Protected endpoints"},
      {"id": "UI-042", "title": "Dashboard components"},
      {"id": "UI-099", "title": "User settings page"},
      {"id": "FEAT-100", "title": "Beta release checklist"}
    ]
  },
  "bottlenecks": [
    {"id": "AUTH-001", "direct": 5, "total": 12, "on_critical_path": true},
    {"id": "DB-001", "direct": 3, "total": 9, "on_critical_path": true},
    {"id": "API-005", "direct": 4, "total": 7, "on_critical_path": true}
  ],
  "ready": [
    {"id": "AUTH-001", "priority": 0, "unblocks": 5},
    {"id": "DB-001", "priority": 1, "unblocks": 3},
    {"id": "DOCS-003", "priority": 2, "unblocks": 0}
  ],
  "plan": {
    "phases": [
      {"phase": 1, "issues": ["AUTH-001", "DB-001", "DOCS-003", "UI-001"]},
      {"phase": 2, "issues": ["API-005", "API-017", "UI-042"]},
      {"phase": 3, "issues": ["UI-099", "API-020"]},
      {"phase": 4, "issues": ["FEAT-100"]}
    ],
    "total_phases": 4
  },
  "recommendations": [
    {
      "action": "start",
      "issue": "AUTH-001",
      "reason": "Highest impact (unblocks 12), on critical path, ready now"
    },
    {
      "action": "parallelize",
      "issues": ["DB-001", "DOCS-003", "UI-001"],
      "reason": "Independent work streams, no shared dependencies"
    }
  ]
}
```

---

## Conclusion

Adding graph intelligence transforms beads_zig from a simple issue tracker into a project planning tool. The algorithms are straightforward, the implementation is bounded, and the value for agent-driven workflows is high.

Key insight: Most of the value comes from cycle detection, topo sort, and impact analysis. PageRank is nice-to-have but not critical. Ship the MVP fast, iterate on polish.
