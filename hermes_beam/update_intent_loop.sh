#!/bin/bash
sed -i '' -e '710,713s/option.Option(mcp_client.McpClient)/option.Option(mcp_client.McpClient), supervisor_subj: process.Subject(subagent_supervisor.SupervisorMessage)/' src/hermes_beam.gleam
sed -i '' -e '729s/intent_loop(selector, mcp_client_opt)/intent_loop(selector, mcp_client_opt, supervisor_subj)/' src/hermes_beam.gleam
sed -i '' -e '731s/intent_loop(selector, mcp_client_opt)/intent_loop(selector, mcp_client_opt, supervisor_subj)/' src/hermes_beam.gleam
