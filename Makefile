.PHONY: build test run telegram worker-test doctor clean

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
