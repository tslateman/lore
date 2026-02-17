#!/usr/bin/env node
/**
 * Lore MCP Server
 *
 * Exposes Lore's knowledge base to AI agents via Model Context Protocol.
 * 
 * Tools:
 *   Knowledge: search, context, related
 *   Capture: remember, learn
 *   Session: resume
 *   Intent: goals, spec
 *   Spec Management: spec_list, spec_context, spec_assign, spec_progress, spec_complete
 *   Delegation: delegate, tasks, claim_task, complete_task
 *   Analysis: failures, triggers, impact
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { execSync } from "child_process";
import { z } from "zod";

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
  },
  async ({ query, project, graph_depth, limit }) => {
    const args = ["search", query];

    if (graph_depth && graph_depth > 0) {
      args.push("--graph-depth", String(graph_depth));
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
// Delegation Tools - Agent Task Coordination
// =============================================================================

// Tool: lore_delegate
// Create a task for another agent
server.tool(
  "lore_delegate",
  "Create a delegated task for another agent to pick up. Tasks enable structured handoff of work between agents.",
  {
    title: z.string().describe("Task title - clear, actionable description"),
    description: z.string().optional().describe("Detailed task description"),
    context: z.string().optional().describe("Background context the assignee needs"),
    priority: z
      .enum(["critical", "high", "medium", "low"])
      .optional()
      .describe("Task priority (default: medium)"),
    for_agent: z.string().optional().describe("Target agent type (e.g., 'backend', 'frontend', 'reviewer')"),
    goal_id: z.string().optional().describe("Related goal ID if task supports a goal"),
    tags: z.string().optional().describe("Tags for categorization (comma-separated)"),
  },
  async ({ title, description, context, priority, for_agent, goal_id, tags }) => {
    const args = ["task", "create", title];

    if (description) {
      args.push("--description", description);
    }
    if (context) {
      args.push("--context", context);
    }
    if (priority) {
      args.push("--priority", priority);
    }
    if (for_agent) {
      args.push("--for", for_agent);
    }
    if (goal_id) {
      args.push("--goal", goal_id);
    }
    if (tags) {
      args.push("--tags", tags);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to create task: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_tasks
// List available tasks
server.tool(
  "lore_tasks",
  "List delegated tasks. Filter by status, priority, or target agent.",
  {
    status: z
      .enum(["pending", "claimed", "completed", "cancelled"])
      .optional()
      .describe("Filter by task status"),
    priority: z
      .enum(["critical", "high", "medium", "low"])
      .optional()
      .describe("Filter by priority"),
    for_agent: z.string().optional().describe("Filter by target agent type"),
  },
  async ({ status, priority, for_agent }) => {
    const args = ["task", "list"];

    if (status) {
      args.push("--status", status);
    }
    if (priority) {
      args.push("--priority", priority);
    }
    if (for_agent) {
      args.push("--for", for_agent);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to list tasks: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_task_show
// Show details for a specific task
server.tool(
  "lore_task_show",
  "Get full details for a delegated task including description and context.",
  {
    task_id: z.string().describe("Task ID to view"),
  },
  async ({ task_id }) => {
    const args = ["task", "show", task_id];

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to show task: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_claim_task
// Claim a task for this agent
server.tool(
  "lore_claim_task",
  "Claim a delegated task. Signals 'I'm working on this' to other agents.",
  {
    task_id: z.string().describe("Task ID to claim"),
    agent: z.string().optional().describe("Agent name claiming the task (default: session ID)"),
  },
  async ({ task_id, agent }) => {
    const args = ["task", "claim", task_id];

    if (agent) {
      args.push("--agent", agent);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to claim task: ${err.message}` }],
        isError: true,
      };
    }
  }
);

// Tool: lore_complete_task
// Complete a claimed task with outcome
server.tool(
  "lore_complete_task",
  "Mark a task as complete with optional outcome notes. Can also cancel a task.",
  {
    task_id: z.string().describe("Task ID to complete"),
    outcome: z.string().optional().describe("Summary of what was accomplished"),
    status: z
      .enum(["completed", "cancelled"])
      .optional()
      .describe("Final status (default: completed)"),
  },
  async ({ task_id, outcome, status }) => {
    const args = ["task", "complete", task_id];

    if (outcome) {
      args.push("--outcome", outcome);
    }
    if (status) {
      args.push("--status", status);
    }

    try {
      const output = runLore(args);
      return {
        content: [{ type: "text" as const, text: stripAnsi(output) }],
      };
    } catch (error: unknown) {
      const err = error as { message: string };
      return {
        content: [{ type: "text" as const, text: `Failed to complete task: ${err.message}` }],
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
    mission: z.string().optional().describe("Filter by mission ID"),
  },
  async ({ error_type, mission }) => {
    const args = ["failures"];
    if (error_type) {
      args.push("--type", error_type);
    }
    if (mission) {
      args.push("--mission", mission);
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
