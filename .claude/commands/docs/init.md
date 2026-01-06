---
description: ⚡⚡⚡⚡ Analyze the codebase and create initial documentation
---

## Phase 1: Parallel Codebase Scouting

1. Scan the codebase and calculate the number of files with LOC in each directory (skip credentials, cache or external modules directories, such as `.claude`, `.opencode`, `.git`, `tests`, `node_modules`, `__pycache__`, `secrets`, etc.)
2. Target directories **that actually exist** - adapt to project structure, don't hardcode paths
3. Main agent spawns multiple `scout` subagents via Task tool:
   - Write a detailed instructions prompt for each scout subagent with exact directories or files it should read
   - Each scout subagent has less than 200K tokens of context window
   - Amount of scouts depends on the current system resources available and project size in step 1
   - Each scout subagent must return a detailed summary report to a main agent
5. Main agent merges scout reports into context summary and delegate to `docs-manager` agent to update documentation (next phase)

## Phase 2: Documentation Creation (docs-manager Agent)

Pass the gathered file list to `docs-manager` agent to create initial documentation:
- `docs/project-overview-pdr.md`: Project overview and PDR (Product Development Requirements)
- `docs/codebase-summary.md`: Codebase summary
- `docs/code-standards.md`: Codebase structure and code standards
- `docs/system-architecture.md`: System architecture
- Update `README.md` with initial documentation (keep it under 300 lines)

Use `docs/` directory as the source of truth for documentation.

## Phase 3: Size Check (Post-Generation)

After docs-manager completes:
1. Run `wc -l docs/*.md 2>/dev/null | sort -rn` to check LOC
2. Use `docs.maxLoc` from session context (default: 800)
3. For files exceeding limit:
   - Report which files exceed and by how much
   - docs-manager should have already split proactively per Section 6 guidelines
   - If still oversized, ask user: split now or accept as-is?

**IMPORTANT**: **Do not** start implementing.