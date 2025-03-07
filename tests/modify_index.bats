#!/usr/bin/env bats
# tests/modify_index.bats

setup() {
  fake_dir=$(mktemp -d)
  export PATH="$fake_dir:$PATH"

  # Write a fake curl script that simulates Elasticsearch API responses.
  # This fake version checks the URL being accessed and returns predictable
  # responses (body plus an HTTP code, on separate lines), as expected by the script.
  cat > "$fake_dir/curl" <<'EOF'
#!/bin/bash

if [[ "${FAKE_CURL_FAIL:-0}" -eq 1 ]]; then
    echo "Simulated curl failure" >&2
    exit 1
fi

# Find the URL argument (first argument starting with http:// or https://)
url=""
for arg in "$@"; do
    case "$arg" in
        http://*|https://*) url="$arg"; break ;;
    esac
done

case "$url" in
    *"_cat/indices?format=json"*)
        # Return fake JSON for indices list.
        body="${FAKE_CAT_INDICES:-'[ {\"index\": \"source_index\"} ]'}"
        echo "$body"
        echo "200"
        exit 0
        ;;
    *"/_alias/"*)
        # For alias check calls, return the fake status (default 404 = not found)
        echo "${FAKE_ALIAS_STATUS:-404}"
        exit 0
        ;;
    *"/_reindex"*)
        echo "reindexed"
        echo "200"
        exit 0
        ;;
    *"/_settings"*)
        echo "settings updated"
        echo "200"
        exit 0
        ;;
    *"/_mapping"*)
        echo "mappings updated"
        echo "200"
        exit 0
        ;;
    *"/_close"*)
        echo "closed"
        echo "200"
        exit 0
        ;;
    *"/_open"*)
        echo "opened"
        echo "200"
        exit 0
        ;;
    *)
        # For other calls—for creation, deletion, etc.—simulate based on -X option.
        if [[ " $* " =~ " -X DELETE " ]]; then
            echo "deleted"
        elif [[ " $* " =~ " -X PUT " ]]; then
            echo "created"
        elif [[ " $* " =~ " -X POST " ]]; then
            echo "post ok"
        else
            echo "OK"
        fi
        echo "200"
        exit 0
        ;;
esac
EOF
  chmod +x "$fake_dir/curl"
}

teardown() {
  rm -rf "$fake_dir"
}

SCRIPT="./bin/modify_index.sh"

###############################################################################
# Test: Missing required arguments
###############################################################################
@test "Display usage when required arguments are missing" {
  run "$SCRIPT" --host "http://localhost:9200"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Missing required arguments"* ]]
  [[ "$output" == *"Usage:"* ]]
}

###############################################################################
# Test: Help option
###############################################################################
@test "Display help message with -h flag" {
  run "$SCRIPT" -h
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Usage:"* ]]
}

###############################################################################
# Test: Source and destination indexes identical
###############################################################################
@test "Error when source and destination indexes are the same" {
  run "$SCRIPT" --source idx1 --dest idx1 --host "http://localhost:9200"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Source index and destination index cannot be the same"* ]]
}

###############################################################################
# Test: jq dependency missing (simulate by temporarily removing jq from PATH)
###############################################################################
@test "Error when jq is not installed" {
  original_PATH=$PATH
  fake_only_dir=$(mktemp -d)
  cp "$fake_dir/curl" "$fake_only_dir/"
  PATH="$fake_only_dir"

  run "$SCRIPT" --source idx1 --dest idx2 --host "http://localhost:9200"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"jq is not installed"* ]]

  PATH="$original_PATH"
  rm -rf "$fake_only_dir"
}

###############################################################################
# Test: Source index not found in fake indices list
###############################################################################
@test "Error when source index is missing from the list" {
  export FAKE_CAT_INDICES='[{"index": "other_index"}]'
  run "$SCRIPT" --source missing_index --dest new_index --host "http://localhost:9200"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Source index 'missing_index' does not exist."* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Destination index already exists without --force
###############################################################################
@test "Error when destination index already exists without --force" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}, {"index": "dest_idx"}]'
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Destination index 'dest_idx' already exists. Use --force to delete it."* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Successful run when destination index does not exist
###############################################################################
@test "Successful index creation when destination does not exist" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --noninteractive
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Creating destination index 'dest_idx'"* ]]
  [[ "$output" == *"Index modification completed successfully."* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Successful run with backup and replace options enabled
###############################################################################
@test "Successful run with backup and replace options" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --backup --replace --noninteractive
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Creating backup index"* ]]
  [[ "$output" == *"Reindexing data from backup"* ]]
  [[ "$output" == *"Deleting source index 'src_idx'"* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Settings file provided but not found
###############################################################################
@test "Error when settings file is provided but not found" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --settings non_existing_file.json --noninteractive
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Settings file 'non_existing_file.json' not found."* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Mappings file provided but not found
###############################################################################
@test "Error when mappings file is provided but not found" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --mappings non_existing_mapping.json --noninteractive
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Mappings file 'non_existing_mapping.json' not found."* ]]
  unset FAKE_CAT_INDICES
}

###############################################################################
# Test: Non-interactive alias assignment (simulate alias already exists)
###############################################################################
@test "Non-interactive alias assignment overwrites existing alias" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  export FAKE_ALIAS_STATUS=200  # Simulate that the alias exists.
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --alias myalias --noninteractive
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Non-interactive mode: Overwriting alias 'myalias'"* ]]
  unset FAKE_CAT_INDICES
  unset FAKE_ALIAS_STATUS
}

###############################################################################
# Test: Interactive alias check with user abort (simulate option 2)
###############################################################################
@test "Interactive alias check aborts when user selects abort option" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  export FAKE_ALIAS_STATUS=200
  run bash -c "printf '2\n' | $SCRIPT --source src_idx --dest dest_idx --host http://localhost:9200 --alias myalias"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"User aborted."* ]]
  unset FAKE_CAT_INDICES
  unset FAKE_ALIAS_STATUS
}

###############################################################################
# Test: Interactive alias check with new alias specification (simulate option 3)
###############################################################################
@test "Interactive alias check prompts for new alias and proceeds" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  export FAKE_ALIAS_STATUS=200
  run bash -c "printf '3\nnewalias\n1\n' | $SCRIPT --source src_idx --dest dest_idx --host http://localhost:9200 --alias myalias"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Assigning alias 'newalias' to destination index 'dest_idx'"* ]]
  unset FAKE_CAT_INDICES
  unset FAKE_ALIAS_STATUS
}

###############################################################################
# Test: Simulate curl command failure
###############################################################################
@test "Script exits when curl fails" {
  export FAKE_CAT_INDICES='[{"index": "src_idx"}]'
  export FAKE_CURL_FAIL=1
  run "$SCRIPT" --source src_idx --dest dest_idx --host "http://localhost:9200" --noninteractive
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Simulated curl failure"* ]]
  unset FAKE_CAT_INDICES
  unset FAKE_CURL_FAIL
}
