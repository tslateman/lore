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

    LORE_PATTERN_YAML="$pattern_yaml" awk '
        BEGIN { pattern = ENVIRON["LORE_PATTERN_YAML"] }
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

    LORE_ANTI_PATTERN_YAML="$anti_pattern_yaml" awk '
        BEGIN { anti_pattern = ENVIRON["LORE_ANTI_PATTERN_YAML"] }
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

    # Pure awk YAML-to-JSON conversion — no yq dependency
    awk -v filter_type="$type" -v filter_cat="$category" '
    BEGIN {
        in_patterns = 0; in_anti = 0; in_entry = 0; in_examples = 0
        pat_count = 0; anti_count = 0
        # Field names for patterns vs anti-patterns
    }

    # Track which top-level section we are in
    /^patterns:/ { in_patterns = 1; in_anti = 0; in_entry = 0; in_examples = 0; next }
    /^anti_patterns:/ { in_anti = 1; in_patterns = 0; in_entry = 0; in_examples = 0; next }

    # Detect start of a new entry (list item with id)
    (in_patterns || in_anti) && /^[[:space:]]*- id:[[:space:]]/ {
        # Flush previous entry if any
        if (in_entry) { flush_entry() }
        in_entry = 1; in_examples = 0
        field_count = 0; example_count = 0
        delete fields; delete field_order
        delete example_types; delete example_vals
        # Parse the id from this line
        val = $0
        sub(/.*id:[[:space:]]*"/, "", val)
        sub(/"[[:space:]]*$/, "", val)
        field_count++
        fields["id"] = val
        field_order[field_count] = "id"
        next
    }

    # Detect examples sub-array
    in_entry && /^[[:space:]]*examples:[[:space:]]*$/ {
        in_examples = 1
        next
    }

    # Example items: "- bad: ..." or "- good: ..."
    in_entry && in_examples && /^[[:space:]]*- (bad|good):[[:space:]]/ {
        line = $0
        # Determine example type without gawk capture groups
        etype = "bad"
        if (line ~ /- good:/) { etype = "good" }
        val = line
        sub(/.*- (bad|good):[[:space:]]*"/, "", val)
        sub(/"[[:space:]]*$/, "", val)
        example_count++
        example_types[example_count] = etype
        example_vals[example_count] = val
        next
    }

    # Regular field line: "      key: value" or "      key: \"value\""
    in_entry && /^[[:space:]]+[a-z_]+:[[:space:]]/ {
        # If we hit a non-example field after examples started, examples section ended
        if (in_examples && !/^[[:space:]]*- /) { in_examples = 0 }

        line = $0
        # Extract field name
        fname = line
        sub(/^[[:space:]]+/, "", fname)
        sub(/:.*/, "", fname)

        # Extract value
        val = line
        sub(/^[[:space:]]*[a-z_]+:[[:space:]]*/, "", val)

        # Strip surrounding quotes if present
        if (val ~ /^".*"$/) {
            sub(/^"/, "", val)
            sub(/"$/, "", val)
        }

        field_count++
        fields[fname] = val
        field_order[field_count] = fname
        next
    }

    function json_escape(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\t/, "\\t", s)
        return s
    }

    function is_numeric(v) {
        return v ~ /^[0-9]+(\.[0-9]+)?$/
    }

    function flush_entry() {
        if (!in_entry) return
        entry_cat = ("category" in fields) ? fields["category"] : ""

        # Apply category filter
        if (filter_cat != "" && entry_cat != filter_cat) {
            in_entry = 0
            return
        }

        # Determine which section this entry belongs to
        if (in_patterns) {
            pat_count++
            pat_entries[pat_count] = build_json()
        } else if (in_anti) {
            anti_count++
            anti_entries[anti_count] = build_json()
        }
        in_entry = 0
    }

    function build_json(    i, fname, val, result, first) {
        result = "{"
        first = 1
        for (i = 1; i <= field_count; i++) {
            fname = field_order[i]
            val = fields[fname]
            if (!first) result = result ","
            first = 0
            if (is_numeric(val)) {
                result = result "\n      \"" fname "\": " val
            } else {
                result = result "\n      \"" fname "\": \"" json_escape(val) "\""
            }
        }
        # Append examples if any
        if (example_count > 0) {
            result = result ",\n      \"examples\": ["
            for (i = 1; i <= example_count; i++) {
                if (i > 1) result = result ","
                result = result "\n        {\"" example_types[i] "\": \"" json_escape(example_vals[i]) "\"}"
            }
            result = result "\n      ]"
        }
        result = result "\n    }"
        return result
    }

    END {
        # Flush the last entry
        if (in_entry) { flush_entry() }

        show_pat = (filter_type == "all" || filter_type == "patterns")
        show_anti = (filter_type == "all" || filter_type == "anti-patterns")

        printf "{\n"
        first_section = 1

        if (show_pat) {
            first_section = 0
            printf "  \"patterns\": ["
            for (i = 1; i <= pat_count; i++) {
                if (i > 1) printf ","
                printf "\n    %s", pat_entries[i]
            }
            if (pat_count > 0) printf "\n  "
            printf "]"
        }

        if (show_anti) {
            if (!first_section) printf ","
            printf "\n  \"anti_patterns\": ["
            for (i = 1; i <= anti_count; i++) {
                if (i > 1) printf ","
                printf "\n    %s", anti_entries[i]
            }
            if (anti_count > 0) printf "\n  "
            printf "]"
        }

        printf "\n}\n"
    }
    ' "$PATTERNS_FILE"
}
