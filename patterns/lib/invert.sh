#!/usr/bin/env bash
# Anti-Pattern Inversion Logic
# Automatically converts harmful patterns into anti-patterns

# Threshold for automatic inversion (number of harmful flags)
INVERSION_THRESHOLD=3

# Invert a pattern into an anti-pattern
# Usage: invert_pattern <pattern_id> <reason>
invert_pattern() {
    local pattern_id="$1"
    local reason="$2"
    
    # Read pattern details
    local pattern_yaml
    pattern_yaml=$(show_pattern "$pattern_id") || return 1
    
    local name context problem solution category
    name=$(echo "$pattern_yaml" | grep "name:" | sed 's/.*name: "\(.*\)"/\1/')
    context=$(echo "$pattern_yaml" | grep "context:" | sed 's/.*context: "\(.*\)"/\1/')
    problem=$(echo "$pattern_yaml" | grep "problem:" | sed 's/.*problem: "\(.*\)"/\1/')
    solution=$(echo "$pattern_yaml" | grep "solution:" | sed 's/.*solution: "\(.*\)"/\1/')
    category=$(echo "$pattern_yaml" | grep "category:" | sed 's/.*category: "\(.*\)"/\1/')
    
    # Create anti-pattern details
    local anti_name="Avoid: $name"
    local symptom="$problem (Context: $context)"
    local fix="Do not use this pattern. Instead: $solution (See rationale)"
    local risk="$reason"
    
    echo -e "${YELLOW}Inverting harmful pattern '${name}' into anti-pattern...${NC}"
    
    # Capture the new anti-pattern
    capture_anti_pattern "$anti_name" "$symptom" "$fix" "$risk" "high" "$category"
    
    # Mark original pattern as deprecated
    deprecate_pattern "$pattern_id" "Converted to anti-pattern due to: $reason"
}

# Mark a pattern as deprecated
deprecate_pattern() {
    local id="$1"
    local reason="$2"
    
    local temp_file
    temp_file=$(mktemp)
    
    # Add [DEPRECATED] to name and set confidence to 0
    awk -v id="$id" -v reason="$reason" '
        BEGIN { in_pattern = 0 }
        /id:.*'"$id"'/ {
            in_pattern = 1
        }
        in_pattern && /name:/ {
            if ($0 !~ /\[DEPRECATED\]/) {
                sub(/name: "/, "name: \"[DEPRECATED] ")
            }
        }
        in_pattern && /confidence:/ {
            sub(/confidence: [0-9.]+/, "confidence: 0.0")
        }
        in_pattern && /^[[:space:]]*- id:/ && $0 !~ id {
            in_pattern = 0
        }
        { print }
    ' "$PATTERNS_FILE" > "$temp_file"
    
    mv "$temp_file" "$PATTERNS_FILE"
    
    echo -e "${YELLOW}Pattern $id marked as deprecated.${NC}"
}

# Check if a pattern should be inverted
check_inversion_trigger() {
    local pattern_id="$1"
    local flag_count="$2"
    local reason="$3"
    
    if [[ "$flag_count" -ge "$INVERSION_THRESHOLD" ]]; then
        invert_pattern "$pattern_id" "$reason"
    fi
}
