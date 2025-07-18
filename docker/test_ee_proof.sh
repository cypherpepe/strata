#!/bin/bash

# An utility script that requests EE proof from the prover and wait for the result.
# P.S. the URLs are configured to be used with docker-compose-testing.yml

# --- CONFIGURATION PROFILES ---
MODE=${1:-local}  # default to 'local' if not specified

if [[ "$MODE" == "local" ]]; then
    RPC_URL="http://localhost:12603"
    PROVER_URL="http://localhost:12900"
elif [[ "$MODE" == "docker" ]]; then
    RPC_URL="http://localhost:8545"
    PROVER_URL="http://localhost:9851"
else
    echo "❌ Unknown mode: $MODE"
    echo "Usage: $0 [local|docker]"
    exit 1
fi

set -e  # stop on first error

# Function: get_block_info <block_number_or_tag> <output_file>
get_block_info() {
    local BLOCK_PARAM=$1
    local OUTPUT_FILE=$2
    local BLOCK_NUMBER_DEC

    if [[ "$BLOCK_PARAM" == "latest" ]]; then
        BLOCK_NUMBER_HEX="latest"
    else
        BLOCK_NUMBER_HEX=$(printf "0x%x" $BLOCK_PARAM)
    fi

    RESPONSE=$(curl -s -X POST --data "{
        \"jsonrpc\":\"2.0\",
        \"method\":\"eth_getBlockByNumber\",
        \"params\": [\"$BLOCK_NUMBER_HEX\", false],
        \"id\":1
    }" -H "Content-Type: application/json" $RPC_URL)

    BLOCK_HASH=$(echo $RESPONSE | jq -r '.result.hash')

    BLOCK_NUMBER_HEX_ACTUAL=$(echo $RESPONSE | jq -r '.result.number')
    BLOCK_NUMBER_DEC=$(( $(printf "%d" $BLOCK_NUMBER_HEX_ACTUAL) ))

    # Write JSON to file
    echo "{\"slot\": $BLOCK_NUMBER_DEC, \"blkid\": \"$BLOCK_HASH\"}" > "$OUTPUT_FILE"
}

# --- MAIN ---

# Temp files
START_FILE=$(mktemp)
END_FILE=$(mktemp)

# Fetch block 1
echo "Fetching block 1..."
get_block_info 1 "$START_FILE"

# Fetch latest block
echo "Fetching latest block..."
get_block_info latest "$END_FILE"

PARAMS_JSON=$(jq -s '.' "$START_FILE" "$END_FILE")

EE_PROOF_REQUEST_JSON=$(jq -n \
    --argjson params "$PARAMS_JSON" \
    '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "dev_strata_proveElBlocks",
        "params": [ $params ]
    }'
)

echo "EE Proof JSON-RPC call to send:"
echo "$EE_PROOF_REQUEST_JSON" | jq .

# POST to prover endpoint
echo "Sending the request to prove EE blocks..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$EE_PROOF_REQUEST_JSON" "$PROVER_URL")

PROOF_ID=$(echo "$RESPONSE" | jq -r '.result[0]')

echo "Got proof handle: $PROOF_ID"

# TODO change to 60
MAX_RETRIES=6000
# 5 minutes should be more than enough to proof a range of blocks in native mode.
#MAX_RETRIES=60
RETRY_COUNT=0

# Poll dev_strata_getProof
while true; do
    echo "Polling prover for proof result..."
    
    PROOF_QUERY=$(jq -n \
        --argjson proof_id "$PROOF_ID" \
        '{
            "jsonrpc": "2.0",
            "id": 1,
            "method": "dev_strata_getProof",
            "params": [ $proof_id ]
        }'
    )

    PROOF_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$PROOF_QUERY" "$PROVER_URL")
    READY=$(echo "$PROOF_RESPONSE" | jq '.result != null and .result != ""')

    if [[ "$READY" == "true" ]]; then
        echo "✅ Proof is ready!"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if (( RETRY_COUNT >= MAX_RETRIES )); then
        echo "❌ Error: Proof was not ready after $MAX_RETRIES attempts."
        exit 1
    fi

    echo "⏳ Proof not ready yet, waiting 5 seconds..."
    sleep 5
done

# Cleanup
rm -f "$START_FILE" "$END_FILE"