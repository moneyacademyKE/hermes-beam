# Gap Analysis: command-code CLI Agent integration for Hermes BEAM

This document presents a thorough and comprehensive Rich Hickey Gap Analysis comparing our current workspace-integrated agent setup (explicit markdown logs, local Datalog stack) with the capabilities of [command-code](https://github.com/CommandCodeAI/command-code), a CLI-based coding agent that learns user preferences via a neuro-symbolic "taste" profile.

---

## 1. Context and Decomplecting Analysis

From a Rich Hickey perspective, **complecting** (braiding together) agent learning data with a proprietary AI model architecture or external SaaS registry reduces transparency and creates tool lock-in.

*   **Our Current Setup**: We capture architectural decisions, design constraints, and bug resolutions inside explicit, human-readable files ([learnings.md](file:///Users/moe/Desktop/ayncoder/learnings.md) and [patterns.md](file:///Users/moe/Desktop/ayncoder/patterns.md)). This is **simple** (plain text data, decoupled from the model, version-controlled via Git, and directly inspectable by a developer). Any model (Gemini, Llama, Claude) can read and apply these rules contextually.
*   **command-code**: Uses the `taste-1` neuro-symbolic model architecture to learn a user's style ("taste") implicitly by tracking accept, reject, and edit actions during a CLI session. This data is **complected** (opaque, encoded inside model configuration layers, and tied to the CommandCodeAI SaaS sync registry via `npx taste push/pull`). If the backend server is unreachable, the taste profile cannot be shared or backed up.

---

## 2. Feature Set Difference Matrix

| Feature | Local Markdown Logs Setup | command-code (CLI Agent) | Difference Explanation |
| :--- | :--- | :--- | :--- |
| **Learning Capture** | Explicitly logged by the agent/developer | Implicitly captured via accept/reject/edit loop | Local requires writing structured entries. `command-code` extracts patterns from raw diff interactions. |
| **Taste Persistence** | Plain markdown files (`learnings.md`/`patterns.md`) | Neuro-symbolic profile (`taste-1` model config) | Local logs are transparent and editable. `command-code` config is opaque and model-dependent. |
| **Portability & Sharing** | Stored in Git; pushed/pulled via standard repo | Stored in SaaS registry; pushed/pulled via `taste` | Local utilizes standard git branches. `command-code` relies on custom `npx taste` sync commands. |
| **Interaction Interface** | IDE Editor / Chat Harness | Terminal CLI session (`cmd` command) | Local operates within editor panes. `command-code` runs in interactive terminal loops with autocomplete. |
| **Tool Execution** | Out-of-process Babashka UDS worker daemon | Direct CLI node shell executions | Local executes in structured failure domains. `command-code` runs commands directly in the shell. |
| **Dependency Lifecycle** | Self-contained project files | Globally installed CLI package (`pnpm i -g`) | Local requires zero global registry updates. `command-code` needs frequent global npm updates to stay aligned. |

---

## 3. Benefits and Trade-offs

### command-code (CLI Agent)
*   **Benefits**:
    *   **Zero-Overhead Learning**: Learning happens automatically in the background without requiring manual logs.
    *   **Interactive Shell Ergonomics**: The terminal console interface with `@` path completion and `/` commands is highly optimized for fast keyboard usage.
*   **Trade-offs**:
    *   **Black-Box Preferences**: Developers cannot easily edit, inspect, or audit what the agent has "learned" about their style.
    *   **Global Package Upkeep**: Global installation can conflict with node permission configurations and requires frequent update checks (`command_code_updater.clj`).

### Local Markdown Logs (Our Setup)
*   **Benefits**:
    *   **Absolute Transparency**: Every learning and design pattern is fully documented in plain text, making it clear, auditable, and easily editable by the developer.
    *   **Model Agnostic**: We can switch LLM providers or models instantly, and the new model will immediately read and respect all recorded style guidelines.
*   **Trade-offs**:
    *   **Manual Logging Cost**: The agent must spend tokens and execution time synthesizing and writing new entries to `learnings.md` and `patterns.md` at the end of sessions.

---

## 4. Complexity vs. Utility Matrix

| Metric | Local Setup | command-code (CLI Agent) |
| :--- | :--- | :--- |
| **Implementation Complexity** | Low (Plain markdown file append) | High (Neuro-symbolic feedback loops, custom shell parsing) |
| **Taste Auditability** | Excellent (Directly readable and editable) | Poor (Opaque vector/model embeddings) |
| **User Onboarding** | Instant (Standard git workflow) | Medium (Global node setup, SaaS account creation) |
| **Model Portability** | Excellent (Works with any LLM) | Poor (Tied to the `taste-1` model runtime) |

---

## 5. Weighted Power/New Capabilities vs. Speed vs. Complexity vs. Trade-offs Analysis

We apply a weighted score (1 to 10 scale) to evaluate integrating `command-code` or adopting its style.

| Evaluation Metric | Weight | Local Setup Score | command-code Score | Weighted Difference |
| :--- | :--- | :--- | :--- | :--- |
| **Taste Auditability & Control** | 30% | 10 / 10 | 4 / 10 | -1.80 |
| **Model Independence / Portability**| 25% | 10 / 10 | 3 / 10 | -1.75 |
| **Learning Capture Automation** | 20% | 6 / 10 | 9 / 10 | +0.60 |
| **Global Package Overhead** | 15% | 10 / 10 | 6 / 10 | -0.60 |
| **Onboarding Simplicity** | 10% | 10 / 10 | 7 / 10 | -0.30 |
| **Total Weighted Score** | **100%**| **9.20** | **5.35** | **-3.85** |

**Conclusion**: The local Markdown-based learnings setup dominates by +3.85. The transparency, control, and complete model agnosticism of git-controlled markdown logs represent a far simpler, more robust approach than opaque neuro-symbolic taste profiles.

---

## 6. Actionable Recommendation

We recommend the **Explicit Documentation Strategy**:
1.  **Maintain Explicit Logs**: Retain `learnings.md` and `patterns.md` as our primary mechanism for capturing coding taste and style rules. This guarantees simplicity, auditability, and Git integration.
2.  **CLI Upkeep Helper**: Add the Babashka version updater script (`command_code_updater.clj`) to the project. This allows developers to periodically verify that the globally installed `command-code` binary is up to date with the latest npm release without having to manually check version numbers.
