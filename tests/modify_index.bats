#!/usr/bin/env bats
#
# tests/modify_index.bats

ES_HOST="http://localhost:9200"
SCRIPT="./script.sh"

#-------------------------------------------------------------------------
# Helper functions for Elasticsearch operations
#-------------------------------------------------------------------------

# Delete an index (ignore errors if it does not exist)
delete_index() {
  curl -s -X DELETE "$ES_HOST/$1?ignore_unavailable=true" > /dev/null
}

# Create an index (with default settings)
create_index() {
  curl -s -X PUT "$ES_HOST/$1" > /dev/null
}

# Add a dummy document to the given index
add_doc() {
  curl -s -X POST "$ES_HOST/$1/_doc" -H 'Content-Type: application/json' -d "$2" > /dev/null
}

# Refresh the given index so that documents are visible for search
refresh_index() {
  curl -s -X POST "$ES_HOST/$1/_refresh" > /dev/null
}

# Return the HTTP status code for the given index
get_index_status() {
  curl -s -o /dev/null -w "%{http_code}" "$ES_HOST/$1"
}

#-------------------------------------------------------------------------
# Debug helper function
#-------------------------------------------------------------------------

# assert_contains prints debug information if $output does not contain the expected substring.
assert_contains() {
  expected="$1"
  if ! [[ "$output" == *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
      return 1
  fi
  return 0
}

#-------------------------------------------------------------------------
# Test Cases
#-------------------------------------------------------------------------

@test "Display usage when required arguments are missing" {
  run $SCRIPT --host "$ES_HOST"
  [ "$status" -ne 0 ]
  assert_contains "Missing required arguments"
  assert_contains "Usage:"
}

@test "Display help message with -h flag" {
  run $SCRIPT -h
  [ "$status" -ne 0 ]
  assert_contains "Usage:"
}

@test "Error when source and destination indexes are identical" {
  run $SCRIPT --source same_index --dest same_index --host "$ES_HOST"
  [ "$status" -ne 0 ]
  assert_contains "Source index and destination index cannot be the same"
}

@test "Error when source index is not found" {
  # Ensure the source index does not exist.
  delete_index "test_nonexist_src"
  delete_index "test_new_dest"
  
  run $SCRIPT --source test_nonexist_src --dest test_new_dest --host "$ES_HOST" --noninteractive
  [ "$status" -ne 0 ]
  expected="Source index 'test_nonexist_src' does not exist."
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  # Cleanup destination index if it was inadvertently created.
  delete_index "test_new_dest"
}

@test "Error when destination index already exists without --force" {
  # Setup: create a source index with dummy data and pre-create the destination index.
  delete_index "test_src_exist"
  delete_index "test_dest_exist"
  
  create_index "test_src_exist"
  add_doc "test_src_exist" '{"dummy": "data"}'
  refresh_index "test_src_exist"
  
  create_index "test_dest_exist"
  
  run $SCRIPT --source test_src_exist --dest test_dest_exist --host "$ES_HOST" --noninteractive
  [ "$status" -ne 0 ]
  expected="Destination index 'test_dest_exist' already exists. Use --force to delete it."
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  # Cleanup indices.
  delete_index "test_src_exist"
  delete_index "test_dest_exist"
}

@test "Successful index creation when destination does not exist" {
  delete_index "test_src_success"
  delete_index "test_dest_success"
  
  # Create source index with dummy data.
  create_index "test_src_success"
  add_doc "test_src_success" '{"dummy": "data"}'
  refresh_index "test_src_success"
  
  run $SCRIPT --source test_src_success --dest test_dest_success --host "$ES_HOST" --noninteractive
  [ "$status" -eq 0 ]
  assert_contains "Creating destination index 'test_dest_success'"
  assert_contains "Index modification completed successfully."
  
  # Verify that destination index exists.
  status_code=$(get_index_status "test_dest_success")
  [ "$status_code" -eq 200 ]
  
  # Verify that source index was not deleted.
  src_status=$(get_index_status "test_src_success")
  [ "$src_status" -eq 200 ]
  
  # Cleanup.
  delete_index "test_src_success"
  delete_index "test_dest_success"
}

@test "Successful run with backup and replace options" {
  delete_index "test_src_backup"
  delete_index "test_dest_backup"
  
  backup_index="test_src_backup-backup-$(date '+%Y%m%d')"
  delete_index "$backup_index"
  
  # Create source index with dummy data.
  create_index "test_src_backup"
  add_doc "test_src_backup" '{"dummy": "data"}'
  refresh_index "test_src_backup"
  
  run $SCRIPT --source test_src_backup --dest test_dest_backup --host "$ES_HOST" --backup --replace --noninteractive
  [ "$status" -eq 0 ]
  
  expected_backup="Creating backup index"
  if [[ "$output" != *"$expected_backup"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected_backup'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected_backup"
  assert_contains "Reindexing data from backup"
  assert_contains "Deleting source index 'test_src_backup'"
  
  # Verify destination exists.
  dest_status=$(get_index_status "test_dest_backup")
  [ "$dest_status" -eq 200 ]
  
  # Verify that source index has been deleted.
  src_status=$(get_index_status "test_src_backup")
  [ "$src_status" -ne 200 ]
  
  # Verify that backup index exists.
  backup_status=$(get_index_status "$backup_index")
  [ "$backup_status" -eq 200 ]
  
  # Cleanup.
  delete_index "test_dest_backup"
  delete_index "$backup_index"
}

@test "Error when settings file is provided but not found" {
  delete_index "test_src_settings"
  delete_index "test_dest_settings"
  
  create_index "test_src_settings"
  add_doc "test_src_settings" '{"dummy": "data"}'
  refresh_index "test_src_settings"
  
  run $SCRIPT --source test_src_settings --dest test_dest_settings --host "$ES_HOST" --settings non_existent_settings.json --noninteractive
  [ "$status" -ne 0 ]
  expected="Settings file 'non_existent_settings.json' not found."
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  delete_index "test_src_settings"
  delete_index "test_dest_settings"
}

@test "Error when mappings file is provided but not found" {
  delete_index "test_src_mappings"
  delete_index "test_dest_mappings"
  
  create_index "test_src_mappings"
  add_doc "test_src_mappings" '{"dummy": "data"}'
  refresh_index "test_src_mappings"
  
  run $SCRIPT --source test_src_mappings --dest test_dest_mappings --host "$ES_HOST" --mappings non_existent_mappings.json --noninteractive
  [ "$status" -ne 0 ]
  expected="Mappings file 'non_existent_mappings.json' not found."
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  delete_index "test_src_mappings"
  delete_index "test_dest_mappings"
}

@test "Successful application of settings and mappings files" {
  delete_index "test_src_config"
  delete_index "test_dest_config"
  
  create_index "test_src_config"
  add_doc "test_src_config" '{"dummy": "data"}'
  refresh_index "test_src_config"
  
  # Create temporary settings file.
  settings_file=$(mktemp)
  cat > "$settings_file" <<EOF
{
  "index": {
    "number_of_shards": "1",
    "number_of_replicas": "0"
  }
}
EOF

  # Create temporary mappings file.
  mappings_file=$(mktemp)
  cat > "$mappings_file" <<EOF
{
  "properties": {
    "field1": {"type": "text"},
    "field2": {"type": "keyword"}
  }
}
EOF

  run $SCRIPT --source test_src_config --dest test_dest_config --host "$ES_HOST" --settings "$settings_file" --mappings "$mappings_file" --noninteractive
  [ "$status" -eq 0 ]
  assert_contains "Updating settings from"
  assert_contains "Updating mappings from"
  assert_contains "Index modification completed successfully."
  
  # Verify that the destination index settings match what we provided.
  dest_settings=$(curl -s "$ES_HOST/test_dest_config/_settings")
  shards=$(echo "$dest_settings" | jq -r '.[].settings.index.number_of_shards')
  [ "$shards" = "1" ]
  
  # Verify that the destination index mappings include "field1".
  dest_mappings=$(curl -s "$ES_HOST/test_dest_config/_mapping")
  has_field=$(echo "$dest_mappings" | jq '.[].mappings.properties | has("field1")')
  [ "$has_field" = "true" ]
  
  rm -f "$settings_file" "$mappings_file"
  delete_index "test_src_config"
  delete_index "test_dest_config"
}

@test "Interactive alias check aborts when user selects abort option" {
  # Setup: create a source index; ensure any prior alias is cleaned.
  delete_index "test_src_int_alias"
  delete_index "test_dest_int_alias"
  delete_index "dummy_alias"
  
  create_index "test_src_int_alias"
  add_doc "test_src_int_alias" '{"dummy": "data"}'
  refresh_index "test_src_int_alias"
  
  # Create a dummy index with alias "testalias" so that the alias exists.
  create_index "dummy_alias"
  curl -s -X POST "$ES_HOST/_aliases" -H 'Content-Type: application/json' \
      -d '{"actions":[{"add": {"index": "dummy_alias", "alias": "testalias"}}]}' > /dev/null
  
  # Run the script interactively by piping in "2" (to abort)
  run bash -c "printf '2\n' | $SCRIPT --source test_src_int_alias --dest test_dest_int_alias --host \"$ES_HOST\" --alias testalias"
  [ "$status" -ne 0 ]
  expected="User aborted."
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  delete_index "test_src_int_alias"
  delete_index "test_dest_int_alias"
  delete_index "dummy_alias"
}

@test "Interactive alias check prompts for new alias and proceeds" {
  # Setup: create a source index.
  delete_index "test_src_int_alias2"
  delete_index "test_dest_int_alias2"
  delete_index "dummy_alias2"
  
  create_index "test_src_int_alias2"
  add_doc "test_src_int_alias2" '{"dummy": "data"}'
  refresh_index "test_src_int_alias2"
  
  # Create a dummy index with alias "testalias" to trigger the interactive alias check.
  create_index "dummy_alias2"
  curl -s -X POST "$ES_HOST/_aliases" -H 'Content-Type: application/json' \
      -d '{"actions":[{"add": {"index": "dummy_alias2", "alias": "testalias"}}]}' > /dev/null
  
  # In interactive mode, choose option 3 (to specify a new alias "newalias") then option 1 to proceed.
  run bash -c "printf '3\nnewalias\n1\n' | $SCRIPT --source test_src_int_alias2 --dest test_dest_int_alias2 --host \"$ES_HOST\" --alias testalias"
  [ "$status" -eq 0 ]
  expected="Assigning alias 'newalias' to destination index 'test_dest_int_alias2'"
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  # Verify via ES that the new alias is associated with the destination index.
  alias_info=$(curl -s "$ES_HOST/_alias/newalias")
  echo "$alias_info" | grep -q "test_dest_int_alias2"
  
  delete_index "test_src_int_alias2"
  delete_index "test_dest_int_alias2"
  delete_index "dummy_alias2"
}

@test "Successful non-interactive alias assignment when alias does not exist" {
  delete_index "test_src_alias2"
  delete_index "test_dest_alias2"
  
  create_index "test_src_alias2"
  add_doc "test_src_alias2" '{"dummy": "data"}'
  refresh_index "test_src_alias2"
  
  run $SCRIPT --source test_src_alias2 --dest test_dest_alias2 --host "$ES_HOST" --alias testalias2 --noninteractive
  [ "$status" -eq 0 ]
  expected="Assigning alias 'testalias2' to destination index 'test_dest_alias2'"
  if [[ "$output" != *"$expected"* ]]; then
      echo "---------- DEBUG ----------"
      echo "Test: ${BATS_TEST_NAME}"
      echo "Expected output to contain: '$expected'"
      echo "Actual output:"
      echo "$output"
      echo "---------------------------"
  fi
  assert_contains "$expected"
  
  # Verify via ES that the alias exists on the destination index.
  alias_result=$(curl -s "$ES_HOST/_alias/testalias2")
  echo "$alias_result" | grep -q "test_dest_alias2"
  
  delete_index "test_src_alias2"
  delete_index "test_dest_alias2"
}
