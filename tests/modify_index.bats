#!/usr/bin/env bats
# tests/modify_index/modify_index.bats
# These tests verify error conditions and key behaviors of the modify_index script.
# The tests override PATH to use our curl mock so that no real HTTP calls are made.

setup() {
  # Prepend the mocks folder to PATH so that "curl" calls will use our mock.
  export PATH="$(pwd)/tests/mocks:$PATH"
  # Create a temporary directory if needed.
  TMPDIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "Displays usage when --help is provided" {
  run ../bin/modify_index.sh --help
  # The usage function calls exit, so we expect non-zero exit code.
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "Fails when required arguments are missing" {
  run ../bin/modify_index.sh --dest newindex --host http://fake:9200
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required arguments:"* ]]
}

@test "Fails when source equals destination index" {
  run ../bin/modify_index.sh --source duplicate --dest duplicate --host http://fake:9200
  [ "$status" -ne 0 ]
  [[ "$output" == *"Source index and destination index cannot be the same"* ]]
}

@test "Errors when a settings file is provided but does not exist" {
  run ../bin/modify_index.sh --source test_source --dest test_dest --host http://fake:9200 --settings missing_settings.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"Settings file 'missing_settings.json' not found"* ]]
}

@test "Processes non-interactive alias overwrite" {
  # Ensure that the index list returns the source index.
  export MOCK_INDICES='[{"index": "test_source"}]'
  # Simulate that the alias already exists.
  export MOCK_ALIAS_EXISTS="true"
  # Run with the non-interactive flag so the script auto-overwrites the alias.
  run ../bin/modify_index.sh --source test_source --dest test_dest --host http://fake:9200 --alias test_alias --noninteractive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Non-interactive mode: Overwriting alias 'test_alias'"* ]]
}

@test "Forces deletion of destination index when --force is set and dest already exists" {
  # Simulate that both the source and destination indices exist.
  export MOCK_INDICES='[{"index": "test_source"}, {"index": "test_dest"}]'
  run ../bin/modify_index.sh --source test_source --dest test_dest --host http://fake:9200 --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Forcing deletion of existing destination index 'test_dest'"* ]]
}

@test "Creates a backup when --backup is used" {
  export MOCK_INDICES='[{"index": "test_source"}]'
  run ../bin/modify_index.sh --source test_source --dest test_dest --host http://fake:9200 --backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Creating backup index"* ]]
}
