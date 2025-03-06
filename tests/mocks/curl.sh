#!/bin/bash
# tests/mocks/curl.sh
# This mock simulates responses from Elasticsearch for testing purposes.
# It inspects the URL (and optionally environment variables) to decide on a response.

# Extract the URL argument (assumes one argument starting with "http")
url=""
for arg in "$@"; do
    if [[ "$arg" == http* ]]; then
        url="$arg"
        break
    fi
done

# A helper function to output a response body and an HTTP code on a new line.
respond() {
    local response="$1"
    local http_code="$2"
    echo -e "$response"
    echo "$http_code"
}

# If no URL is provided, simply return a default response.
if [[ -z "$url" ]]; then
    respond "dummy_response" "200"
    exit 0
fi

# Simulate the _cat/indices endpoint.
if [[ "$url" == *"/_cat/indices"* ]]; then
    if [[ -n "${MOCK_INDICES:-}" ]]; then
        respond "${MOCK_INDICES}" "200"
    else
        respond '[{"index": "test_source"}]' "200"
    fi
    exit 0
fi

# Simulate alias check requests.
if [[ "$url" == *"/_alias/"* ]]; then
    if [[ "${MOCK_ALIAS_EXISTS:-false}" == "true" ]]; then
        respond "" "200"
    else
        respond "" "404"
    fi
    exit 0
fi

# Simulate calls to _reindex.
if [[ "$url" == *"/_reindex"* ]]; then
    respond "OK" "200"
    exit 0
fi

# For PUT, DELETE, or other endpoints, return a generic OK.
respond "OK" "200"
exit 0
