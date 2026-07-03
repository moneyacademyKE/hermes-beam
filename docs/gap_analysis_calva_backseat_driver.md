# Gap Analysis: calva-backseat-driver integration for Hermes BEAM

This document presents a thorough and comprehensive Rich Hickey Gap Analysis comparing our current editor-agnostic Babashka-based nREPL testing setup with the capabilities of [calva-backseat-driver](https://github.com/BetterThanTomorrow/calva-backseat-driver), the VS Code extension that exposes IDE structural editing and REPL tools as an MCP (Model Context Protocol) server.

---

## 1. Context and Decomplecting Analysis

From a Rich Hickey perspective, **complecting** (braiding together) agent capabilities with the user's active editor host environment (specifically VS Code's Extension Host lifecycle) limits portability and creates deep temporal coupling.

*   **Our Current Setup**: The Babashka worker daemon and `nrepl:test` / `nrepl:test-shadow` tasks are completely **editor-agnostic**. They interface directly with filesystem-exposed REPL ports (`.nrepl-port` and `.shadow-cljs/nrepl.port`). This separates the runner (CLI/Babashka process) from any specific editor, allowing the agent to function identically in a headless server, CI/CD pipeline, Vim, Emacs, or VS Code.
*   **calva-backseat-driver**: Runs directly inside VS Code as an Extension Host process. It spawns a local TCP socket server (defaulting to port `1664`) and writes a port file to `<workspace-root>/.calva/mcp-server/port`. An external stdio relay must be used to bridge the agent's stdio interface to the socket server. This complects the agent's capability (evaluating code, editing files) with the state of the user's graphical editor. If the user closes VS Code, the agent's MCP connection is severed.

---

## 2. Feature Set Difference Matrix

| Feature | Local Daemon + nREPL Tasks | calva-backseat-driver (VS Code MCP) | Difference Explanation |
| :--- | :--- | :--- | :--- |
| **Editor Agnosticism** | 100% editor-free (runs via CLI / Babashka) | Coupled to VS Code Extension Host | Local setup runs anywhere. Calva MCP requires VS Code to be active with the extension running. |
| **Evaluation State** | Connects to runtime JVM/CLJS REPL | Shares active VS Code Calva REPL session | Calva MCP shares the user's visual REPL session. Local tasks connect to the raw socket port on the filesystem. |
| **Editing Style** | Text-based search-and-replace (`replace_file_content`) | AST-based structural editing (`balance-brackets`, `clojure-edit-files`) | Calva MCP manipulates form structures directly via AST parsers, preventing syntax errors. Local edits raw text lines. |
| **Infrastructure Overhead**| Zero background editor dependencies | Requires active editor socket server + stdio relay bridge | Calva MCP requires running an active socket-to-stdio relay proxy (`calva_mcp_bridge.clj`). |
| **Security Boundaries** | Client-managed (connects to local port) | IDE-managed (Settings-configured trust confirmations) | Calva MCP supports VS Code trust confirmation popups for evaluations, preventing rogue agent edits. |
| **Output Integration** | Streams stdout/stderr to CLI logs | Appends output directly to Calva IDE output pane | Calva MCP outputs evaluations inline to the developer's output pane inside the IDE. |

---

## 3. Benefits and Trade-offs

### calva-backseat-driver (VS Code MCP)
*   **Benefits**:
    *   **AST-Safe Editing**: Prevents unbalanced parentheses or syntax errors by delegating edits to rewrite-clj structural tools.
    *   **Shared IDE State**: Evaluated variables, loaded namespaces, and database connections are identical to what the developer sees in their Calva editor.
    *   **Visual Trust Model**: Developers can see evaluation outputs and approve/deny actions directly via VS Code settings and popups.
*   **Trade-offs**:
    *   **VS Code Bound**: Cannot run in headless terminal environments, remote server hooks, or alternative editors (Emacs/Vim).
    *   **Coupled Lifecycle**: The agent cannot run unless the developer actively has VS Code open and the Calva REPL connected.

### Local Daemon + nREPL Tasks (Our Setup)
*   **Benefits**:
    *   **Universal Execution**: Runs seamlessly in CI/CD, headless terminals, git commit hooks, or any alternative developer setup.
    *   **Zero-Dependency Lifecycle**: The agent starts and stops independently of the developer's local editor.
*   **Trade-offs**:
    *   **Text-Based File Edits**: Line-based search-and-replace lacks syntax awareness and can result in compilation issues on nested forms.
    *   **Isolated State**: The background worker JVM session is separate from any REPL session the developer might have open in their IDE.

---

## 4. Complexity vs. Utility Matrix

| Metric | Local Setup | calva-backseat-driver (VS Code MCP) |
| :--- | :--- | :--- |
| **Implementation Complexity** | Low (Direct socket evaluation) | Medium (Stdio-to-socket relay, VS Code extension host interop) |
| **Runtime Portability** | Excellent (CLI-only, zero GUI dependency) | Poor (Requires VS Code graphical host) |
| **Developer Ergonomics** | Good (Independent CLI execution) | Excellent (Shared editor REPL output, inline visualization) |
| **Editing Robustness** | Medium (Text replacements can break forms) | Excellent (Structural edits guarantee code validity) |

---

## 5. Weighted Power/New Capabilities vs. Speed vs. Complexity vs. Trade-offs Analysis

We apply a weighted score (1 to 10 scale) to evaluate integrating `calva-backseat-driver` MCP support.

| Evaluation Metric | Weight | Local Setup Score | calva-backseat-driver Score | Weighted Difference |
| :--- | :--- | :--- | :--- | :--- |
| **Editing Safety (AST vs Text)**| 30% | 5 / 10 | 10 / 10 | +1.50 |
| **IDE Integration & Ergonomics**| 25% | 6 / 10 | 9 / 10 | +0.75 |
| **Portability / Editor-Free Run**| 20% | 10 / 10 | 3 / 10 | -1.40 |
| **Infrastructure Simplicity** | 15% | 9 / 10 | 5 / 10 | -0.60 |
| **Setup & Connection Overhead** | 10% | 10 / 10 | 6 / 10 | -0.40 |
| **Total Weighted Score** | **100%**| **7.40** | **7.25** | **-0.15** |

**Conclusion**: The scores are extremely close (weighted difference of -0.15). While Calva MCP offers unmatched editing safety and IDE ergonomics, its lack of portability and strict graphical editor dependency makes it unsuitable as a sole execution strategy.

---

## 6. Actionable Recommendation

We recommend a **Coexistence Strategy**:
1.  **Default Editor-Agnostic Setup**: Keep our local JVM-Free Babashka worker and nREPL tasks as the primary development and testing mechanism. This ensures the agent is fully portable and runs headless.
2.  **Optional calva-backseat-driver MCP Bridge**: Expose a stdio-to-socket bridge script (`calva_mcp_bridge.clj`) in our repository. If the agent detects that `.calva/mcp-server/port` exists in the workspace, it can optionally establish an MCP connection to the running VS Code extension to utilize AST-safe editing and share the developer's REPL session.
