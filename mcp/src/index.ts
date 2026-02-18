#!/usr/bin/env node
/**
 * Lore MCP Server
 *
 * Exposes Lore's knowledge base to AI agents via Model Context Protocol.
 * 
 * Tools:
 *   Knowledge: search, context, related
 *   Query: query_patterns, query_journal, query_graph
 *   Capture: remember, learn
 *   Session: resume
 *   Intent: goals, spec
 *   Spec Management: spec_list, spec_context, spec_assign, spec_progress, spec_complete
 *   Analysis: failures, triggers, impact
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { execSync } from "child_process";
import { readFileSync } from "fs";
import { z } from "zod";
import { parse as parseYaml } from "yaml";

const LORE_DIR = process.env.LORE_DIR;
if (!LORE_DIR) {
  console.error("[lore-mcp] LORE_DIR environment variable is required");
  process.exit(1);
}

/**
 * Execute a lore command and return the output.
 * Uses stderr for logging since stdout is reserved for MCP protocol.
 */
function runLore(args: string[]): string {
  const cmd = `${LORE_DIR}/lore.sh ${args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ")}`;
  console.error(`[lore-mcp] Running: ${cmd}`);

  try {
    const output = execSync(cmd, {
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024,
      env: { ...process.env, LORE_DIR, NO_COLOR: "1" },
    });
    return output;
  } catch (error: unknown) {
    const execError = error as { stdout?: string; stderr?: string; message: string };
    // Command may exit non-zero but still produce useful output
    if (execError.stdout) {
      return execError.stdout;
    }
    throw new Error(`lore command failed: ${execError.message}`);
  }
}

/**
 * Strip ANSI color codes from output
 */
function stripAnsi(str: string): string {
  return str.replace(/\x1b\[[0-9;]*m/g, "");
}

const server = new McpServer({
  name: "lore",
  version: "1.0.0",
});

// Tool: lore_search
// Ranked FTS5 search across decisions, patterns, and transfers
server.tool(
  "lore_search",
  "Search Lore's knowledge base with ranked results. Returns decisions, patterns, and session handoffs matching the query.",
  {
    query: z.string().describe("Search query (supports FTS5 syntax)"),
    project: z.string().optional().describe("Boost results from this project"),
    graph_depth: z
      .number()
      .min(0)
      .max(3)
      .optional()
      .describe("Follow graph edges (0-3, default 0)"),
    limit: z.number().optional().describe("Max results (default 10)"),
    compact: z.boolean().optional().describe(
      "Return compact index (ID + title + score) instead of full content"
    ),
  },
  async ({ query, project, graph_depth, limit, compact }) => {
    const args = ["search", query];

    if (graph_depth && graph_depth > 0) {
      args.push("--graph-depth", String(graph_depth));
    }

    if (compact) {
      args.push("--compact");
    }

    // Set working directory for project boosting
    const cwd = project ? `${process.env.HOME}/dev/${project}` : undefined;

    try {
      const cmd = `${LORE_DIR}/lore.sh ${args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ")}`;
      console.error(`[lore-mcp] Running: ${cmd}`);

      const output = execSync(cmd, {
        encoding: "utf-8",
        maxBuffer: 10 * 1024 * 1024,
        env: { ...process.env, LORE_DIR, NO_COLOR: "1" },
        cwd,
      });

      return {
        content: [
          {
            type: "text" as const,
            text: stripAnsi(output),
          },
        ],
      };
    } catch (error: unknown) {
      const execError = error as { stdout?: string; message: string };
      if (execError.stdout) {
        return {
          content: [{ type: "text" as const, text: stripAnsi(execError.stdout) }],
        };
      }
      return {
        content: [{ type: "text" as const, text: `Search failed: ${execError.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_context
// Full project context: decisions, patterns, graph neighbors
server.tool(
  "lore_context",
  "Get full context for a project: recent decisions, relevant patterns, and graph relationships.",
  {
    project: z.string().describe("Project name (e.g., 'flow', 'ralph', 'lore')"),
  },
  async ({ project }) => {
    try {
      const output = runLore(["context", project]);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Context retrieval failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_related
// Graph traversal from a node
server.tool(
  "lore_related",
  "Find related concepts via graph traversal. Follows typed edges (relates_to, depends_on, implements, etc.).",
  {
    node_id: z.string().describe("Graph node ID to start from"),
    hops: z
      .number()
      .min(1)
      .max(3)
      .optional()
      .describe("How many hops to traverse (1-3, default 1)"),
  },
  async ({ node_id, hops }) => {
    const args = ["graph", "related", node_id];
    if (hops) {
      args.push("--hops", String(hops));
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Graph traversal failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_remember
// Record a decision to the journal
server.tool(
  "lore_remember",
  "Record a decision to Lore's journal. Captures rationale and alternatives considered.",
  {
    decision: z.string().describe("The decision made"),
    rationale: z.string().optional().describe("Why this decision was made"),
    alternatives: z
      .string()
      .optional()
      .describe("Alternatives considered (comma-separated)"),
    tags: z.string().optional().describe("Tags (comma-separated)"),
    force: z
      .boolean()
      .optional()
      .describe("Skip duplicate check (default false)"),
  },
  async ({ decision, rationale, alternatives, tags, force }) => {
    const args = ["remember", decision];

    if (rationale) {
      args.push("--rationale", rationale);
    }
    if (alternatives) {
      args.push("--alternatives", alternatives);
    }
    if (tags) {
      args.push("--tags", tags);
    }
    if (force) {
      args.push("--force");
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [
          {
            type: "text" as const,
            text: `Failed to record decision: ${err.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// Tool: lore_learn
// Capture a pattern
server.tool(
  "lore_learn",
  "Capture a learned pattern to Lore. Patterns are reusable solutions to recurring problems.",
  {
    name: z.string().describe("Pattern name"),
    context: z.string().optional().describe("When this pattern applies"),
    problem: z.string().optional().describe("The problem this solves"),
    solution: z.string().optional().describe("The solution/approach"),
    category: z
      .string()
      .optional()
      .describe("Category (e.g., 'bash', 'api', 'testing')"),
    force: z
      .boolean()
      .optional()
      .describe("Skip duplicate check (default false)"),
  },
  async ({ name, context, problem, solution, category, force }) => {
    const args = ["learn", name];

    if (context) {
      args.push("--context", context);
    }
    if (problem) {
      args.push("--problem", problem);
    }
    if (solution) {
      args.push("--solution", solution);
    }
    if (category) {
      args.push("--category", category);
    }
    if (force) {
      args.push("--force");
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [
          {
            type: "text" as const,
            text: `Failed to capture pattern: ${err.message}`,
          },
        ],
        isError: true,
      };
    }
  }
);

// Tool: lore_resume
// Load session context from previous handoff
server.tool(
  "lore_resume",
  "Load context from a previous session. Returns handoff notes, pending work, and relevant patterns.",
  {
    session_id: z
      .string()
      .optional()
      .describe("Specific session ID to resume (default: latest)"),
  },
  async ({ session_id }) => {
    const args = ["resume"];
    if (session_id) {
      args.push(session_id);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Resume failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// =============================================================================
// Intent Tools - Goals and Specs
// =============================================================================

// Tool: lore_goals
// List goals from intent layer
server.tool(
  "lore_goals",
  "List goals from Lore's intent layer. Goals define strategic objectives with success criteria.",
  {
    status: z
      .string()
      .optional()
      .describe("Filter by status: draft, active, blocked, completed, cancelled"),
    priority: z
      .string()
      .optional()
      .describe("Filter by priority: critical, high, medium, low"),
  },
  async ({ status, priority }) => {
    const args = ["goal", "list"];
    if (status) {
      args.push("--status", status);
    }
    if (priority) {
      args.push("--priority", priority);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to list goals: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_spec
// Export a goal as a spec file for Claude Code
server.tool(
  "lore_spec",
  "Export a goal as a spec file. Specs are contracts that define what to achieve, success criteria, context, and done conditions.",
  {
    goal_id: z.string().describe("Goal ID to export"),
    format: z
      .enum(["yaml", "markdown"])
      .optional()
      .describe("Output format (default: yaml)"),
  },
  async ({ goal_id, format }) => {
    const args = ["intent", "export", goal_id];
    if (format) {
      args.push("--format", format);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to export spec: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// =============================================================================
// Spec Management Tools - SDD Lifecycle
// =============================================================================

// Tool: lore_spec_list
// List specs by phase or assignment status
server.tool(
  "lore_spec_list",
  "List specs by phase or assignment status. Shows specs in various lifecycle states.",
  {
    filter: z
      .enum(["active", "assigned", "unassigned", "completed"])
      .describe("Filter specs by status"),
  },
  async ({ filter }) => {
    const args = ["spec", "list", "--filter", filter];

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to list specs: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_spec_context
// Get full context for a spec including decisions
server.tool(
  "lore_spec_context",
  "Get full context for a spec: details, related decisions, current phase/task, and patterns.",
  {
    goal_id: z.string().describe("Goal ID to get context for"),
  },
  async ({ goal_id }) => {
    try {
      // Get spec details
      const specOutput = runLore(["spec", "show", goal_id]);

      // Search for related decisions
      let decisionsOutput = "";
      try {
        decisionsOutput = runLore(["search", `spec:${goal_id}`]);
      } catch {
        // No related decisions found, continue without them
        decisionsOutput = "No related decisions found.";
      }

      const combined = `${stripAnsi(specOutput)}\n\n--- Related Decisions ---\n${stripAnsi(decisionsOutput)}`;

      return {
        content: [{ type: "text" as const, text: combined }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to get spec context: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_spec_assign
// Assign spec to current session
server.tool(
  "lore_spec_assign",
  "Assign a spec/goal to the current session. Signals 'I'm working on this.'",
  {
    goal_id: z.string().describe("Goal ID to assign"),
  },
  async ({ goal_id }) => {
    const args = ["spec", "assign", goal_id];

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to assign spec: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_spec_progress
// Update spec phase or current task
server.tool(
  "lore_spec_progress",
  "Update spec phase or current task. Track progress through SDD lifecycle.",
  {
    goal_id: z.string().describe("Goal ID to update"),
    phase: z
      .enum(["specify", "plan", "tasks", "implement"])
      .optional()
      .describe("New phase to set"),
    task_id: z.string().optional().describe("Current task ID being worked on"),
  },
  async ({ goal_id, phase, task_id }) => {
    const args = ["spec", "progress", goal_id];

    if (phase) {
      args.push("--phase", phase);
    }
    if (task_id) {
      args.push("--task", task_id);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to update spec progress: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_spec_complete
// Mark spec complete with outcome
server.tool(
  "lore_spec_complete",
  "Mark spec complete and record outcome. Closes the loop on a specification.",
  {
    goal_id: z.string().describe("Goal ID to complete"),
    status: z
      .enum(["completed", "failed", "abandoned"])
      .describe("Outcome status"),
    notes: z.string().optional().describe("Notes about the outcome (e.g., PR number, blockers)"),
  },
  async ({ goal_id, status, notes }) => {
    const args = ["spec", "complete", goal_id, "--status", status];

    if (notes) {
      args.push("--notes", notes);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to complete spec: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// =============================================================================
// Analysis Tools - Failures, Triggers, Impact
// =============================================================================

// Tool: lore_failures
// Query failure reports
server.tool(
  "lore_failures",
  "Query failure reports from Lore. Find recurring issues and blockers.",
  {
    error_type: z
      .string()
      .optional()
      .describe("Filter by type: Timeout, NonZeroExit, UserDeny, ToolError, LogicError"),
  },
  async ({ error_type }) => {
    const args = ["failures"];
    if (error_type) {
      args.push("--type", error_type);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to query failures: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_triggers
// Error types hitting Rule of Three
server.tool(
  "lore_triggers",
  "Find recurring failure types (Rule of Three). Surfaces systemic issues worth addressing.",
  {
    threshold: z
      .number()
      .optional()
      .describe("Minimum occurrences to trigger (default: 3)"),
  },
  async ({ threshold }) => {
    const args = ["triggers"];
    if (threshold) {
      args.push("--threshold", String(threshold));
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to get triggers: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_impact
// Check project dependencies and relationships
server.tool(
  "lore_impact",
  "Impact analysis: check what depends on a project and its relationships.",
  {
    project: z.string().describe("Project name to analyze"),
  },
  async ({ project }) => {
    try {
      const output = runLore(["registry", "show", project]);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Impact analysis failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// =============================================================================
// Query Tools - Direct data file reads (no shell, fast)
// =============================================================================

/**
 * Safely read a file, returning empty string on any error.
 */
function readDataFile(path: string): string {
  try {
    return readFileSync(path, "utf-8");
  } catch {
    return "";
  }
}

/**
 * Case-insensitive substring match against multiple fields.
 */
function matchesTopic(topic: string, ...fields: (string | undefined | null)[]): boolean {
  const lower = topic.toLowerCase();
  return fields.some((f) => f != null && f.toLowerCase().includes(lower));
}

// Tool: lore_query_patterns
// Direct read of patterns.yaml with filtering
server.tool(
  "lore_query_patterns",
  "Query learned patterns from Lore. Filters by topic, project, tags, and confidence. Returns structured results with metadata.",
  {
    topic: z.string().describe("Search term matched against name, category, context, problem, solution"),
    project: z.string().optional().describe("Filter by source project"),
    tags: z.array(z.string()).optional().describe("Filter where category matches ALL given tags"),
    limit: z.number().optional().describe("Max results (default 5)"),
  },
  async ({ topic, project: _project, tags, limit }) => {
    const maxResults = limit ?? 5;

    try {
      const raw = readDataFile(`${LORE_DIR}/patterns/data/patterns.yaml`);
      if (!raw) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ results: [], _meta: { token_estimate: 10, result_count: 0, truncated: false } }) }],
        };
      }

      const parsed = parseYaml(raw);
      const allPatterns: Array<Record<string, unknown>> = parsed?.patterns ?? [];

      let filtered = allPatterns.filter((p) =>
        matchesTopic(
          topic,
          p.name as string,
          p.category as string,
          p.context as string,
          p.problem as string,
          p.solution as string,
        )
      );

      if (tags && tags.length > 0) {
        filtered = filtered.filter((p) => {
          const cat = (p.category as string) ?? "";
          return tags.every((t) => cat.toLowerCase() === t.toLowerCase());
        });
      }

      // Sort by created_at descending
      filtered.sort((a, b) => {
        const da = (a.created_at as string) ?? "";
        const db = (b.created_at as string) ?? "";
        return db.localeCompare(da);
      });

      const totalCount = filtered.length;
      const truncated = totalCount > maxResults;
      filtered = filtered.slice(0, maxResults);

      const results = filtered.map((p) => {
        const conf = (p.confidence as number) ?? 0;
        const confidenceLabel = conf >= 0.7 ? "established" : conf >= 0.3 ? "emerging" : "deprecated";
        const solution = (p.solution as string) ?? "";
        return {
          id: p.id,
          title: p.name,
          tags: [p.category].filter(Boolean),
          summary: solution.slice(0, 200),
          body: `Context: ${p.context ?? ""}\nProblem: ${p.problem ?? ""}\nSolution: ${solution}`,
          source_project: "lore",
          created: p.created_at,
          confidence: confidenceLabel,
        };
      });

      const response = {
        results,
        _meta: {
          token_estimate: Math.ceil(JSON.stringify(results).length / 4),
          result_count: results.length,
          truncated,
        },
      };

      return {
        content: [{ type: "text" as const, text: JSON.stringify(response, null, 2) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Pattern query failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_query_journal
// Direct read of decisions.jsonl with filtering
server.tool(
  "lore_query_journal",
  "Query journal entries (decisions) from Lore. Filters by topic, date range, and entry type. Returns structured results with metadata.",
  {
    topic: z.string().optional().describe("Search term matched against decision, title, rationale, lesson_learned"),
    project: z.string().optional().describe("Filter by project"),
    after: z.string().optional().describe("Include entries after this ISO date (e.g., '2026-02-01')"),
    before: z.string().optional().describe("Include entries before this ISO date"),
    entry_type: z.string().optional().describe("Filter by type (e.g., 'architecture', 'implementation', 'refactor')"),
    limit: z.number().optional().describe("Max results (default 10)"),
  },
  async ({ topic, project: _project, after, before, entry_type, limit }) => {
    const maxResults = limit ?? 10;

    try {
      const raw = readDataFile(`${LORE_DIR}/journal/data/decisions.jsonl`);
      if (!raw) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ results: [], _meta: { token_estimate: 10, result_count: 0, truncated: false } }) }],
        };
      }

      const lines = raw.trim().split("\n").filter(Boolean);
      let entries: Array<Record<string, unknown>> = [];

      for (const line of lines) {
        try {
          entries.push(JSON.parse(line));
        } catch {
          // Skip malformed lines
        }
      }

      // Apply filters
      if (topic) {
        entries = entries.filter((e) =>
          matchesTopic(
            topic,
            e.decision as string,
            e.title as string,
            e.rationale as string,
            e.lesson_learned as string,
          )
        );
      }

      if (after) {
        entries = entries.filter((e) => (e.timestamp as string) >= after);
      }

      if (before) {
        entries = entries.filter((e) => (e.timestamp as string) <= before);
      }

      if (entry_type) {
        entries = entries.filter((e) => (e.type as string) === entry_type);
      }

      // Sort by timestamp descending
      entries.sort((a, b) => {
        const da = (a.timestamp as string) ?? "";
        const db = (b.timestamp as string) ?? "";
        return db.localeCompare(da);
      });

      const totalCount = entries.length;
      const truncated = totalCount > maxResults;
      entries = entries.slice(0, maxResults);

      const results = entries.map((e) => {
        const decision = (e.decision as string) ?? "";
        const alternatives = (e.alternatives as string[]) ?? [];
        return {
          id: e.id,
          title: (e.title as string) || decision.slice(0, 80),
          type: e.type,
          project: "lore",
          created: e.timestamp,
          summary: decision.slice(0, 300),
          body: `Decision: ${decision}\nRationale: ${e.rationale ?? ""}\nAlternatives: ${alternatives.join(", ")}\nLesson: ${(e.lesson_learned as string) || "none"}`,
          tags: (e.tags as string[]) ?? [],
        };
      });

      const response = {
        results,
        _meta: {
          token_estimate: Math.ceil(JSON.stringify(results).length / 4),
          result_count: results.length,
          truncated,
        },
      };

      return {
        content: [{ type: "text" as const, text: JSON.stringify(response, null, 2) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Journal query failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_query_graph
// Direct read of graph.json with BFS traversal and cross-referencing
server.tool(
  "lore_query_graph",
  "Query Lore's knowledge graph. Finds entities by name, traverses relationships, and cross-references patterns and journal entries.",
  {
    entity: z.string().describe("Entity name to search for (case-insensitive substring match)"),
    relation: z.string().optional().describe("Filter edges by relation type (e.g., 'relates_to', 'depends_on', 'implements')"),
    depth: z.number().optional().describe("BFS traversal depth (default 1)"),
  },
  async ({ entity, relation, depth }) => {
    const maxDepth = depth ?? 1;

    try {
      const raw = readDataFile(`${LORE_DIR}/graph/data/graph.json`);
      if (!raw) {
        return {
          content: [{ type: "text" as const, text: JSON.stringify({ results: [], _meta: { token_estimate: 10, result_count: 0, truncated: false } }) }],
        };
      }

      const graph = JSON.parse(raw) as {
        nodes: Record<string, { type: string; name: string; data: Record<string, unknown>; created_at: string }>;
        edges: Array<{ from: string; to: string; relation: string; weight: number; bidirectional: boolean; created_at?: string }>;
      };

      const nodes = graph.nodes ?? {};
      const edges = graph.edges ?? [];

      // Find matching seed nodes
      const entityLower = entity.toLowerCase();
      const seedIds = Object.keys(nodes).filter((id) =>
        nodes[id].name.toLowerCase().includes(entityLower)
      );

      if (seedIds.length === 0) {
        const response = {
          results: [],
          _meta: { token_estimate: 10, result_count: 0, truncated: false },
        };
        return {
          content: [{ type: "text" as const, text: JSON.stringify(response, null, 2) }],
        };
      }

      // BFS traversal
      const visited = new Set<string>(seedIds);
      let frontier = [...seedIds];
      const collectedEdges: Array<{ from: string; to: string; relation: string; weight: number; bidirectional: boolean }> = [];

      for (let d = 0; d < maxDepth; d++) {
        const nextFrontier: string[] = [];

        for (const nodeId of frontier) {
          for (const edge of edges) {
            const isFrom = edge.from === nodeId;
            const isTo = edge.to === nodeId;
            if (!isFrom && !isTo) continue;
            if (relation && edge.relation !== relation) continue;

            collectedEdges.push(edge);
            const neighbor = isFrom ? edge.to : edge.from;
            if (!visited.has(neighbor)) {
              visited.add(neighbor);
              nextFrontier.push(neighbor);
            }
          }
        }

        frontier = nextFrontier;
      }

      // Cross-reference: search patterns and journal for entity name
      const patternsRaw = readDataFile(`${LORE_DIR}/patterns/data/patterns.yaml`);
      const relatedPatterns: string[] = [];
      if (patternsRaw) {
        const parsed = parseYaml(patternsRaw);
        const patterns: Array<Record<string, unknown>> = parsed?.patterns ?? [];
        for (const p of patterns) {
          if (matchesTopic(entity, p.name as string)) {
            relatedPatterns.push(p.id as string);
          }
        }
      }

      const journalRaw = readDataFile(`${LORE_DIR}/journal/data/decisions.jsonl`);
      const relatedJournal: string[] = [];
      if (journalRaw) {
        for (const line of journalRaw.trim().split("\n").filter(Boolean)) {
          try {
            const entry = JSON.parse(line);
            if (matchesTopic(entity, entry.decision as string)) {
              relatedJournal.push(entry.id as string);
            }
          } catch {
            // Skip malformed lines
          }
        }
      }

      // Build results per seed node
      const results = seedIds.map((seedId) => {
        const node = nodes[seedId];
        const nodeEdges = collectedEdges.filter(
          (e) => e.from === seedId || e.to === seedId
        );

        const relations = nodeEdges.map((e) => {
          const isOutbound = e.from === seedId;
          const targetId = isOutbound ? e.to : e.from;
          const targetNode = nodes[targetId];
          return {
            target: targetNode?.name ?? targetId,
            type: e.relation,
            direction: isOutbound ? "outbound" : "inbound",
            metadata: {
              weight: e.weight,
              bidirectional: e.bidirectional,
            },
          };
        });

        return {
          entity: node.name,
          relations,
          related_patterns: relatedPatterns,
          related_journal: relatedJournal,
        };
      });

      const response = {
        results,
        _meta: {
          token_estimate: Math.ceil(JSON.stringify(results).length / 4),
          result_count: results.length,
          truncated: false,
        },
      };

      return {
        content: [{ type: "text" as const, text: JSON.stringify(response, null, 2) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Graph query failed: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Start the server
async function main() {
  console.error("[lore-mcp] Starting Lore MCP server...");
  console.error(`[lore-mcp] LORE_DIR: ${LORE_DIR}`);

  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error("[lore-mcp] Server connected and ready");
}

main().catch((error) => {
  console.error("[lore-mcp] Fatal error:", error);
  process.exit(1);
});
