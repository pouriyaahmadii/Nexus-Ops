#!/usr/bin/env bash
# seed-qdrant-demo.sh - Create Qdrant collection "kb_demo" with sample documents
# for the showcase RAG step. Uses mock embeddings in DEMO_MODE=mock.

set -euo pipefail

QDRANT_HOST="${QDRANT_HOST:-qdrant}"
QDRANT_PORT="${QDRANT_PORT:-6333}"
QDRANT_API_KEY="${QDRANT_API_KEY:-}"
COLLECTION_NAME="kb_demo"
VECTOR_SIZE=384  # Mock embedding dimension

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

wait_for_qdrant() {
    local max_wait=60
    local waited=0
    log "Waiting for Qdrant at ${QDRANT_HOST}:${QDRANT_PORT}..."
    while [[ ${waited} -lt ${max_wait} ]]; do
        if curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
            "http://${QDRANT_HOST}:${QDRANT_PORT}/healthz" >/dev/null 2>&1; then
            log "Qdrant is ready"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "ERROR: Qdrant did not become ready in time"
    return 1
}

create_collection() {
    log "Creating collection: ${COLLECTION_NAME} (vector size: ${VECTOR_SIZE})"
    curl -fsS -X PUT -H "api-key: ${QDRANT_API_KEY}" \
        "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${COLLECTION_NAME}" \
        -d "{
            \"vectors\": {
                \"size\": ${VECTOR_SIZE},
                \"distance\": \"Cosine\"
            },
            \"optimizers_config\": {
                \"default_segment_number\": 2
            }
        }" >/dev/null
}

generate_mock_embedding() {
    local text="$1"
    # Deterministic mock embedding from text hash
    local hash=$(echo -n "${text}" | sha256sum | cut -d' ' -f1)
    local embedding=()
    for i in {0..95}; do
        local chunk="${hash:$((i*6)):6}"
        local val=$((0x${chunk} % 10000))
        embedding+=("$(echo "scale=6; ${val} / 10000.0" | bc -l)")
    done
    echo "[$(IFS=,; echo "${embedding[*]}")]"
}

upsert_points() {
    log "Upserting sample documents..."
    
    local documents=(
        "How to request a refund for a subscription charge"
        "Billing inquiry about unexpected charges on invoice"
        "Account cancellation and data deletion process"
        "Legal request for data access under GDPR"
        "Complaint about service downtime last week"
        "General question about API rate limits"
        "Refund policy for annual subscriptions"
        "How to update billing information"
        "Data retention and deletion policies"
        "Contacting legal department for subpoenas"
    )

    local points=()
    for i in "${!documents[@]}"; do
        local text="${documents[i]}"
        local embedding=$(generate_mock_embedding "${text}")
        local payload=$(jq -nc --arg text "${text}" --arg category "$(classify_category "${text}")" '{text: $text, category: $category}')
        points+=("{\"id\": $((i+1)), \"vector\": ${embedding}, \"payload\": ${payload}}")
    done

    local points_json="[$(IFS=,; echo "${points[*]}")]"
    
    curl -fsS -X PUT -H "api-key: ${QDRANT_API_KEY}" \
        "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${COLLECTION_NAME}/points" \
        -d "{\"points\": ${points_json}}" >/dev/null
    
    log "Upserted ${#documents[@]} documents"
}

classify_category() {
    local text="$1"
    local text_lower=$(echo "${text}" | tr '[:upper:]' '[:lower:]')
    
    if echo "${text_lower}" | grep -q "refund"; then echo "refund"
    elif echo "${text_lower}" | grep -q "billing\|charge\|invoice"; then echo "billing"
    elif echo "${text_lower}" | grep -q "cancel\|delet"; then echo "deletion"
    elif echo "${text_lower}" | grep -q "legal\|gdpr\|subpoena"; then echo "legal"
    elif echo "${text_lower}" | grep -q "complaint\|downtime"; then echo "complaint"
    else echo "general"; fi
}

verify_collection() {
    log "Verifying collection..."
    local count
    count=$(curl -fsS -H "api-key: ${QDRANT_API_KEY}" \
        "http://${QDRANT_HOST}:${QDRANT_PORT}/collections/${COLLECTION_NAME}" | \
        jq -r '.result.points_count // 0')
    log "Collection ${COLLECTION_NAME} has ${count} points"
}

main() {
    log "Seeding Qdrant demo collection..."
    wait_for_qdrant || exit 1
    create_collection
    upsert_points
    verify_collection
    log "Done!"
}

main "$@"