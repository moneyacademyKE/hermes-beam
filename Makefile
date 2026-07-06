.PHONY: build test run telegram discord a2a onboard release worker-test doctor clean install

HERMES_BEAM_DIR ?= hermes_beam
GLEAM ?= gleam

build:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) build

test:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) test

run:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) run

telegram:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) run -- --telegram

discord:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) run -- --discord

a2a:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) run -- --a2a

onboard:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) run -- --onboard

release:
	@command -v bb >/dev/null || { echo "missing Babashka: bb"; exit 1; }
	bb $(HERMES_BEAM_DIR)/scripts/release.bb

install: release
	@cp $(HERMES_BEAM_DIR)/build/release/hermes_beam /usr/local/bin/hermes || \
	 echo "Install manually: sudo cp $(HERMES_BEAM_DIR)/build/release/hermes_beam /usr/local/bin/hermes"

worker-test:
	cd $(HERMES_BEAM_DIR) && $(GLEAM) test --target erlang supervisor_test
	cd $(HERMES_BEAM_DIR) && $(GLEAM) test --target erlang uds_test
	cd $(HERMES_BEAM_DIR) && $(GLEAM) test --target erlang telegram_gateway_test

doctor:
	@command -v erl >/dev/null || { echo "missing Erlang/OTP: erl"; exit 1; }
	@command -v $(GLEAM) >/dev/null || { echo "missing Gleam: $(GLEAM)"; exit 1; }
	@command -v bb >/dev/null || echo "warning: missing Babashka: bb"
	@test -d $(HERMES_BEAM_DIR) || { echo "missing $(HERMES_BEAM_DIR)/"; exit 1; }
	@test -f $(HERMES_BEAM_DIR)/gleam.toml || { echo "missing $(HERMES_BEAM_DIR)/gleam.toml"; exit 1; }
	@test -f .env.example || { echo "missing .env.example"; exit 1; }
	@cd $(HERMES_BEAM_DIR) && $(GLEAM) run -- --doctor
clean:
	rm -rf $(HERMES_BEAM_DIR)/build
	rm -f $(HERMES_BEAM_DIR)/erl_crash.dump erl_crash.dump
	rm -f $(HERMES_BEAM_DIR)/*.log *.log
