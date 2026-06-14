# Gap Analysis: Stateful Cron Scheduler Actor in Gleam

This document details the design choices, analysis, and implementation details of the stateful `cron_scheduler` actor process built in Gleam.

## Design Context

To support dynamic scheduled automations in the BEAM runtime without relying on external system utilities (like OS-level `cron`), we built a custom stateful OTP actor. This actor manages a mutable list of active cron jobs using an immutable state model inside a BEAM process loop.

## Feature Analysis & Trade-offs

### 1. Actor State vs. Global Mutability
* **Choice**: A dedicated actor process holding the `List(CronJob)` list in state, modified exclusively via actor messages.
* **Trade-off**: Increases setup overhead by needing to spin up and supervise a process, but prevents concurrency bugs (race conditions, dirty reads) and fits the BEAM actor philosophy.

### 2. Pure vs. Side-Effecting Cron Matching
* **Choice**: The `match_cron` function is entirely pure and takes a `DateTime` and `erl_day_of_week` integer, return `Bool`.
* **Trade-off**: Easier testing, as tests don't need to manipulate process timers or wait on system clocks. The system clock is queried only once per `Tick` loop.

### 3. Spawned Tasks vs. Inline Execution
* **Choice**: Conversations are spawned inside `process.spawn(fn() { ... })`.
* **Trade-off**: The scheduler does not block if an LLM call or dynamic tool invocation takes minutes to complete. This ensures the scheduler remains highly responsive to user requests (e.g. `list_jobs`).

## Complexity vs. Utility

| Choice | Complexity | Utility |
| :--- | :--- | :--- |
| **Gregorian Minute Check** | Low | High (guarantees at-most-once execution per scheduled minute) |
| **0/7 Sunday Mapping** | Low | High (resolves cron vs Erlang day of week differences) |
| **Actor process.send_after** | Low | High (BEAM native timers) |
