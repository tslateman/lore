#!/usr/bin/env node
/**
 * Lore MCP Server
 *
 * Exposes Lore's knowledge base to AI agents via Model Context Protocol.
 * Six tools: search, context, related, remember, learn, resume.
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
