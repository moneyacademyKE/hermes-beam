# Commands

Run these commands from the repository root.

| Command | Description |
| --- | --- |
| `make build` | Build the Gleam/Erlang Hermes BEAM app in `hermes_beam/`. |
| `make test` | Run the full Hermes BEAM Gleam test suite. |
| `make run` | Start the interactive Hermes BEAM runner. |
| `make telegram` | Start the supervised Telegram gateway. Requires `HERMES_TELEGRAM_TOKEN`. |
| `make worker-test` | Run worker/supervisor-focused tests for subagent orchestration. |
| `make doctor` | Check required tools, runtime directories, credentials, optional MCP command wiring, Babashka availability, and Telegram hardening hints without starting the REPL or gateway. |
| `make clean` | Remove generated Hermes BEAM build output and common crash/log artifacts. |

## Direct Gleam Commands

If you do not want to use `make`, run the underlying commands directly:

```sh
cd hermes_beam
gleam build
gleam test
gleam run
gleam run -- --doctor
gleam run -- --telegram
```

Worker-focused validation:

```sh
cd hermes_beam
gleam test --target erlang supervisor_test
gleam test --target erlang uds_test
gleam test --target erlang telegram_gateway_test
```

## Environment

Copy `.env.example` to `.env` for local configuration. Keep secrets out of git.

Run `make doctor` after changing `.env` or production host configuration. Warnings are used for optional integrations and hardening hints; missing Erlang, Gleam, repository files, or an unusable Hermes runtime directory are errors.

## Removed Surfaces

Legacy Python/Node packaging, Nix, Docker Compose, PyPI/uv, website/docs deployment, Windows installer workflows, optional WhatsApp bridge assets, and scratch Gleam prototypes are not active commands and have been removed from the repository. Do not treat them as supported Hermes BEAM entry points without an explicit revival plan.
