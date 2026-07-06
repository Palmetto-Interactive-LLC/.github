<div align="center">

<img src="palmetto-wordmark.png" alt="Palmetto Interactive" width="300">

**Developer tools for agentic software teams, built porchside.**

Charleston-based AI studio building agentic developer tools, multi-agent orchestration, and custom AI products.

[palmettointeractive.com](https://palmettointeractive.com) · [info@palmettointeractive.com](mailto:info@palmettointeractive.com)

</div>

---

## What We Build

We design and ship production agentic systems and developer tools: multi-agent orchestration with real tool use, local and hosted automation infrastructure, and full-stack custom AI products. We also build high-performance websites and Shopify stores, and provide AI strategy and enablement for businesses across the Lowcountry.

**Studio disciplines**
- Agentic systems — planner/controller/evals architectures, real tool use (file edits, shell, browsers, APIs)
- Developer tools — MCP servers, terminal orchestration, worktree automation, hosted runners, and Temporal-backed workflows
- Custom AI products — Rust · TypeScript · Postgres, 0→1 MVPs in 6–12 week sprints
- Strategy & Advisory — AI enablement and roadmapping

---

## Open Source

### [Lantern](https://github.com/Palmetto-Interactive-LLC/Lantern)

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/Palmetto-Interactive-LLC/Lantern/blob/main/LICENSE)
[![CI](https://github.com/Palmetto-Interactive-LLC/Lantern/actions/workflows/ci.yml/badge.svg)](https://github.com/Palmetto-Interactive-LLC/Lantern/actions/workflows/ci.yml)
[![Issues](https://img.shields.io/github/issues/Palmetto-Interactive-LLC/Lantern)](https://github.com/Palmetto-Interactive-LLC/Lantern/issues)

A self-contained Rust binary that orchestrates squads of AI coding agents on your local machine — no cloud dependency, no credentials required.

Lantern runs as an MCP server, local terminal orchestrator, and Temporal client. It manages iTerm2 panes, git worktrees, agent-to-agent communication, and session state so you can run a coordinated team of specialized AI agents (architecture, security, data, UI, ops, QA, docs) against any codebase.

**→ [README & Quick Start](https://github.com/Palmetto-Interactive-LLC/Lantern#readme)**
**→ [Issues & Roadmap](https://github.com/Palmetto-Interactive-LLC/Lantern/issues)**

### [Marsh](https://github.com/Palmetto-Interactive-LLC/Marsh)

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/Palmetto-Interactive-LLC/Marsh/blob/main/LICENSE)
[![CI](https://github.com/Palmetto-Interactive-LLC/Marsh/actions/workflows/ci.yml/badge.svg)](https://github.com/Palmetto-Interactive-LLC/Marsh/actions/workflows/ci.yml)
[![Issues](https://img.shields.io/github/issues/Palmetto-Interactive-LLC/Marsh)](https://github.com/Palmetto-Interactive-LLC/Marsh/issues)

An MIT-licensed elastic runner platform for GitHub Actions. Marsh keeps GitHub as the scheduler, then creates short-lived self-hosted runners inside Daytona sandboxes when queued jobs need capacity.

Marsh is built for teams that want clean self-hosted runner labels without owning a long-lived runner fleet: JIT runner registration, one-job sandboxes, cache-aware runner images, and automatic teardown.

**→ [README & Quick Start](https://github.com/Palmetto-Interactive-LLC/Marsh#readme)**
**→ [Issues & Roadmap](https://github.com/Palmetto-Interactive-LLC/Marsh/issues)**

### [Sweetgrass](https://github.com/Palmetto-Interactive-LLC/Sweetgrass)

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/Palmetto-Interactive-LLC/Sweetgrass/blob/main/LICENSE)
[![CI](https://github.com/Palmetto-Interactive-LLC/Sweetgrass/actions/workflows/ci.yml/badge.svg)](https://github.com/Palmetto-Interactive-LLC/Sweetgrass/actions/workflows/ci.yml)
[![Issues](https://img.shields.io/github/issues/Palmetto-Interactive-LLC/Sweetgrass)](https://github.com/Palmetto-Interactive-LLC/Sweetgrass/issues)

An MIT-licensed visual workspace for Beads issue tracking. Sweetgrass is a heavily extended fork of the Beads Kanban UI, rebuilt into a polished developer workspace for local repositories, Git-aware task flow, agent notes, and project navigation.

Sweetgrass pairs a Next.js interface with a Rust server so teams can inspect Beads-backed work, epics, timelines, agents, and repo state without leaving the local development loop.

**→ [README & Quick Start](https://github.com/Palmetto-Interactive-LLC/Sweetgrass#readme)**
**→ [Issues & Roadmap](https://github.com/Palmetto-Interactive-LLC/Sweetgrass/issues)**

---

## Hosted Developer Tools

**[membl](https://membl.io)** — the Palmetto developer tools portal. Hosted versions of our tools, including Tide and Marsh, will become available there as they are ready for teams. *(in development)*

**Tide** — structured agent-loop execution and run history for moving from ad hoc prompts to repeatable developer workflows. *(hosted product in development)*

---

<div align="center">

Built in the open from Charleston, SC · 32.78°N 79.93°W

[palmettointeractive.com](https://palmettointeractive.com) · [info@palmettointeractive.com](mailto:info@palmettointeractive.com)

</div>
