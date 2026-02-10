#!/usr/bin/env bash
# Pattern capture functions
# Extracts, categorizes, and stores patterns and anti-patterns

# Generate a unique ID for patterns
generate_pattern_id() {
    local prefix="$1"
    local timestamp
    timestamp=$(date +%s)
    local random_suffix
    # Use od as a portable alternative to xxd
    random_suffix=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
    echo "${prefix}-${timestamp:(-6)}-${random_suffix}"
}

# Get current date in ISO format
get_current_date() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Validate category
validate_category() {
    local category="$1"
    local valid_categories="bash git testing architecture naming security docker api performance general"

    if [[ " $valid_categories " == *" $category "* ]]; then
        return 0
    else
        echo -e "${YELLOW}Warning: Unknown category '$category'. Using 'general' instead.${NC}" >&2
        echo "general"
        return 1
    fi
}

# Validate severity
validate_severity() {
    local severity="$1"
    local valid_severities="low medium high critical"

    if [[ " $valid_severities " == *" $severity "* ]]; then
        return 0
    else
        echo -e "${YELLOW}Warning: Unknown severity '$severity'. Using 'medium' instead.${NC}" >&2
        echo "medium"
        return 1
    fi
}

# Escape string for YAML
yaml_escape() {
    local str="$1"
    # Replace backslashes first, then quotes
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    echo "$str"
}

# Capture a new pattern
capture_pattern() {
    local name="$1"
    local context="$2"
    local solution="$3"
    local problem="$4"
    local category="$5"
    local origin="$6"
    local example_bad="$7"
    local example_good="$8"

    # Validate and set defaults
    if ! validate_category "$category" >/dev/null 2>&1; then
        category="general"
    fi

    if [[ -z "$origin" ]]; then
        origin="session-$(date +%Y-%m-%d)"
    fi

    local id
    id=$(generate_pattern_id "pat")
    local created_at
    created_at=$(get_current_date)

    # Build examples YAML
    local examples_yaml=""
    if [[ -n "$example_bad" || -n "$example_good" ]]; then
        examples_yaml="
      examples:"
        if [[ -n "$example_bad" ]]; then
            examples_yaml="$examples_yaml
        - bad: \"$(yaml_escape "$example_bad")\""
        fi
        if [[ -n "$example_good" ]]; then
            examples_yaml="$examples_yaml
        - good: \"$(yaml_escape "$example_good")\""
        fi
    fi

    # Build the pattern YAML entry
    local pattern_yaml="
    - id: \"$id\"
      name: \"$(yaml_escape "$name")\"
      context: \"$(yaml_escape "$context")\"
      problem: \"$(yaml_escape "$problem")\"
      solution: \"$(yaml_escape "$solution")\"
      category: \"$category\"
      origin: \"$origin\"
      confidence: 0.5
      validations: 0
      created_at: \"$created_at\"$examples_yaml"

    # Insert pattern into YAML file
    # We insert after the "patterns:" line
    local temp_file
    temp_file=$(mktemp)

    awk -v pattern="$pattern_yaml" '
        /^patterns:/ {
            print
            if (getline nextline > 0) {
                if (nextline == "" || nextline ~ /^\[\]$/) {
                    # Empty patterns array, insert our pattern
                    print pattern
                } else {
                    # Non-empty, insert before first pattern
                    print pattern
                    print nextline
                }
            } else {
                print pattern
            }
            next
        }
        { print }
    ' "$PATTERNS_FILE" > "$temp_file"

    mv "$temp_file" "$PATTERNS_FILE"

    echo -e "${GREEN}Captured pattern:${NC} $name"
    echo -e "  ${CYAN}ID:${NC} $id"
    echo -e "  ${CYAN}Category:${NC} $category"
    echo -e "  ${CYAN}Origin:${NC} $origin"

    if [[ -n "$context" ]]; then
        echo -e "  ${CYAN}Context:${NC} $context"
    fi
    if [[ -n "$solution" ]]; then
        echo -e "  ${CYAN}Solution:${NC} $solution"
    fi
}

# Capture a new anti-pattern
capture_anti_pattern() {
    local name="$1"
    local symptom="$2"
    local fix="$3"
    local risk="$4"
    local severity="$5"
    local category="$6"

    # Validate and set defaults
    if ! validate_category "$category" >/dev/null 2>&1; then
        category="general"
    fi

    if ! validate_severity "$severity" >/dev/null 2>&1; then
        severity="medium"
    fi

    local id
    id=$(generate_pattern_id "anti")
    local created_at
    created_at=$(get_current_date)

    # Build the anti-pattern YAML entry
    local anti_pattern_yaml="
    - id: \"$id\"
      name: \"$(yaml_escape "$name")\"
      symptom: \"$(yaml_escape "$symptom")\"
      risk: \"$(yaml_escape "$risk")\"
      fix: \"$(yaml_escape "$fix")\"
      category: \"$category\"
      severity: \"$severity\"
      created_at: \"$created_at\""

    # Insert anti-pattern into YAML file
    local temp_file
    temp_file=$(mktemp)

    awk -v anti_pattern="$anti_pattern_yaml" '
        /^anti_patterns:/ {
            print
            if (getline nextline > 0) {
                if (nextline == "" || nextline ~ /^\[\]$/) {
                    print anti_pattern
                } else {
                    print anti_pattern
                    print nextline
                }
            } else {
                print anti_pattern
            }
            next
        }
        { print }
    ' "$PATTERNS_FILE" > "$temp_file"

    mv "$temp_file" "$PATTERNS_FILE"

    echo -e "${RED}Captured anti-pattern:${NC} $name"
    echo -e "  ${CYAN}ID:${NC} $id"
    echo -e "  ${CYAN}Category:${NC} $category"
    echo -e "  ${CYAN}Severity:${NC} $severity"

    if [[ -n "$symptom" ]]; then
        echo -e "  ${CYAN}Symptom:${NC} $symptom"
    fi
    if [[ -n "$fix" ]]; then
        echo -e "  ${CYAN}Fix:${NC} $fix"
    fi
}

# Validate a pattern (increase confidence)
validate_pattern() {
    local id="$1"

    if ! grep -q "id: \"$id\"" "$PATTERNS_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Pattern '$id' not found${NC}" >&2
        return 1
    fi

    # Update validations count and confidence
    local temp_file
    temp_file=$(mktemp)

    awk -v id="$id" '
        BEGIN { found = 0; in_pattern = 0 }
        /id:.*'"$id"'/ {
            found = 1
            in_pattern = 1
        }
        in_pattern && /validations:/ {
            match($0, /validations: ([0-9]+)/, arr)
            old_val = arr[1] + 0
            new_val = old_val + 1
            sub(/validations: [0-9]+/, "validations: " new_val)
        }
        in_pattern && /confidence:/ {
            match($0, /confidence: ([0-9.]+)/, arr)
            old_conf = arr[1] + 0
            # Increase confidence, max 0.99
            new_conf = old_conf + (1 - old_conf) * 0.1
            if (new_conf > 0.99) new_conf = 0.99
            sub(/confidence: [0-9.]+/, sprintf("confidence: %.2f", new_conf))
            in_pattern = 0
        }
        { print }
    ' "$PATTERNS_FILE" > "$temp_file"

    mv "$temp_file" "$PATTERNS_FILE"

    echo -e "${GREEN}Validated pattern:${NC} $id"
    echo -e "  Confidence increased."
}

# Show details for a specific pattern
show_pattern() {
    local id="$1"

    # Check if it's a pattern or anti-pattern
    local section=""
    if [[ "$id" == pat-* ]]; then
        section="patterns"
    elif [[ "$id" == anti-* ]]; then
        section="anti_patterns"
    else
        # Try to find it
        if grep -q "id: \"$id\"" "$PATTERNS_FILE" 2>/dev/null; then
            : # Found
        else
            echo -e "${RED}Error: Pattern '$id' not found${NC}" >&2
            return 1
        fi
    fi

    # Extract and display the pattern
    awk -v id="$id" '
        BEGIN { in_pattern = 0; indent = "" }
        /- id:.*'"$id"'/ {
            in_pattern = 1
            indent = ""
            match($0, /^[[:space:]]*/)
            base_indent = RLENGTH
        }
        in_pattern {
            if (NR > 1 && /^[[:space:]]*- id:/ && $0 !~ id) {
                in_pattern = 0
                next
            }
            if (NR > 1 && /^[a-z_]+:/ && !/^[[:space:]]/) {
                in_pattern = 0
                next
            }
            print
        }
    ' "$PATTERNS_FILE"
}

# List patterns
list_patterns() {
    local type="$1"
    local category="$2"
    local format="$3"

    case "$format" in
        yaml)
            list_patterns_yaml "$type" "$category"
            ;;
        json)
            list_patterns_json "$type" "$category"
            ;;
        table|*)
            list_patterns_table "$type" "$category"
            ;;
    esac
}

list_patterns_table() {
    local type="$1"
    local category="$2"

    if [[ "$type" == "all" || "$type" == "patterns" ]]; then
        echo -e "\n${BLUE}=== Patterns ===${NC}"
        echo -e "${CYAN}ID\t\t\t\tName\t\t\t\tCategory\tConfidence${NC}"
        echo "--------------------------------------------------------------------------------"

        awk -v cat="$category" '
            BEGIN { in_patterns = 0; in_entry = 0 }
            /^patterns:/ { in_patterns = 1; next }
            /^anti_patterns:/ { in_patterns = 0 }
            in_patterns && /- id:/ {
                in_entry = 1
                gsub(/.*id: "/, "")
                gsub(/".*/, "")
                id = $0
            }
            in_entry && /name:/ {
                gsub(/.*name: "/, "")
                gsub(/".*/, "")
                name = $0
            }
            in_entry && /category:/ {
                gsub(/.*category: "/, "")
                gsub(/".*/, "")
                entry_cat = $0
            }
            in_entry && /confidence:/ {
                gsub(/.*confidence: /, "")
                conf = $0
                if (cat == "" || entry_cat == cat) {
                    printf "%-24s\t%-32s\t%-12s\t%.2f\n", id, substr(name, 1, 32), entry_cat, conf
                }
                in_entry = 0
            }
        ' "$PATTERNS_FILE"
    fi

    if [[ "$type" == "all" || "$type" == "anti-patterns" ]]; then
        echo -e "\n${RED}=== Anti-Patterns ===${NC}"
        echo -e "${CYAN}ID\t\t\t\tName\t\t\t\tCategory\tSeverity${NC}"
        echo "--------------------------------------------------------------------------------"

        awk -v cat="$category" '
            BEGIN { in_anti = 0; in_entry = 0 }
            /^anti_patterns:/ { in_anti = 1; next }
            in_anti && /- id:/ {
                in_entry = 1
                gsub(/.*id: "/, "")
                gsub(/".*/, "")
                id = $0
            }
            in_entry && /name:/ {
                gsub(/.*name: "/, "")
                gsub(/".*/, "")
                name = $0
            }
            in_entry && /category:/ {
                gsub(/.*category: "/, "")
                gsub(/".*/, "")
                entry_cat = $0
            }
            in_entry && /severity:/ {
                gsub(/.*severity: "/, "")
                gsub(/".*/, "")
                sev = $0
                if (cat == "" || entry_cat == cat) {
                    printf "%-24s\t%-32s\t%-12s\t%s\n", id, substr(name, 1, 32), entry_cat, sev
                }
                in_entry = 0
            }
        ' "$PATTERNS_FILE"
    fi

    echo ""
}

list_patterns_yaml() {
    local type="$1"
    local category="$2"

    # Just output the raw YAML for now
    # A more sophisticated version would filter by type/category
    cat "$PATTERNS_FILE"
}

list_patterns_json() {
    local type="$1"
    local category="$2"

    # Simple YAML to JSON conversion
    # Requires yq or similar for production use
    echo "{"
    echo "  \"note\": \"JSON output requires yq. Install with: brew install yq or apt install yq\""
    echo "}"
}
