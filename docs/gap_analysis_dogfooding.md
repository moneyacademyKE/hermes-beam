# Gap Analysis: Dogfooding Automation and Verification Strategies

## 1. Introduction
This document performs a Rich Hickey Gap Analysis comparing different approaches for dogfooding and validating the `hermes_beam` REPL orchestrator and Babashka worker stack across a suite of complex goals.

---

## 2. Feature Comparison Matrix

| Feature | Option A: Manual CLI Commands | Option B: Automated Scripted Runner |
| :--- | :--- | :--- |
| **Automation** | None (Requires manual typing) | Full (Programmatic execution) |
| **Reproducibility** | Low (Vulnerable to typing/pacing errors) | High (Identical execution every run) |
| **Telemetry Capture**| Manual scroll-back inspect | Automatic log file capturing & assertions |
| **Scale** | Hard to scale to many goals | Easily scales to 5+ complex goals |
| **Process Isolation** | Shared console | Isolated subprocess per goal test |

---

## 3. Explanations of Feature Differences

### 1. Automation & Reproducibility
* **Option A**: Manual execution is slow and complects human input with the execution runtime. If a goal fails, reproducing it precisely is difficult.
* **Option B**: Writing an automated script (e.g. `dogfood_runner.clj` using Babashka) that spawns the CLI, feeds commands, watches stdout/stderr, and asserts success allows 100% reproducible test suites.

### 2. Telemetry & Failure Capture
* **Option B** dynamically captures the `agent.log` and `errors.log` generated during the run, validating that no exceptions or parse errors occurred at any point in the supervision tree.

---

## 4. Complexity vs. Utility

| Option | Implementation Complexity | Runtime Overhead | Diagnostic Utility | Reliability |
| :--- | :--- | :--- | :--- | :--- |
| **Option A (Manual)** | Very Low | Negligible | Low | Low |
| **Option B (Runner)** | Low | Negligible | High | High |

---

## 5. Actionable Recommendation

We recommend **Option B (Automated Scripted Runner)**. Creating a dedicated `scripts/dogfood_runner.clj` script to execute the 5 goals programmatically makes it highly reliable, easy to monitor, and robust.

### Recommended Action Plan
1. Create a `scripts/dogfood_runner.clj` test runner.
2. Define the 5 target goals as a data structure.
3. For each goal:
   - Clean/reset state.
   - Launch `./hermes repl` in a separate process.
   - Feed `/goal <desc>` to stdin.
   - Monitor output until completion or timeout.
   - Inspect logs for exceptions/errors.
4. If any bugs are found, diagnose and fix them.
