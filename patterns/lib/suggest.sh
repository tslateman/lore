#!/usr/bin/env bash
# Pattern suggestion functions
# Provides proactive suggestions based on context

# Suggest patterns for a given context
suggest_patterns() {
    local context="$1"
    local limit="${2:-5}"

    echo -e "${BLUE}=== Pattern Suggestions for Context ===${NC}"
    echo -e "Context: ${CYAN}$context${NC}"
    echo ""

    # Get keyword-based matches
    local matches
    matches=$(match_patterns_to_context "$context" "$limit")

    if [[ -z "$matches" ]]; then
        # No keyword matches, try category-based suggestions
        suggest_by_category "$context" "$limit"
        return
    fi

    local count=0
    echo -e "${GREEN}Recommended patterns:${NC}"
    echo ""

    while IFS='|' read -r id name pattern_context solution score; do
        count=$((count + 1))
        echo -e "${CYAN}$count. $name${NC} (relevance: $score%)"
        echo -e "   ${YELLOW}When:${NC} $pattern_context"
        echo -e "   ${GREEN}Solution:${NC} $solution"
        echo -e "   ${BLUE}ID:${NC} $id"
        echo ""
    done <<< "$matches"

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}No specific patterns found for this context.${NC}"
        suggest_by_category "$context" "$limit"
    fi

    # Also check for anti-patterns to warn about
    echo ""
    suggest_anti_patterns "$context"
}

# Suggest patterns based on detected category
suggest_by_category() {
    local context="$1"
    local limit="${2:-5}"

    # Detect category from context
    local category="general"

    if echo "$context" | grep -qiE 'bash|shell|script|sh\b'; then
        category="bash"
    elif echo "$context" | grep -qiE 'git|commit|branch|merge|rebase'; then
        category="git"
    elif echo "$context" | grep -qiE 'test|spec|assert|expect|mock'; then
        category="testing"
    elif echo "$context" | grep -qiE 'docker|container|image|dockerfile'; then
        category="docker"
    elif echo "$context" | grep -qiE 'api|endpoint|request|response|rest|graphql'; then
        category="api"
    elif echo "$context" | grep -qiE 'security|auth|password|token|credential|secret'; then
        category="security"
    elif echo "$context" | grep -qiE 'architecture|design|pattern|structure|module'; then
        category="architecture"
    elif echo "$context" | grep -qiE 'name|naming|convention|variable|function'; then
        category="naming"
    fi

    echo -e "${YELLOW}Suggesting patterns from category: $category${NC}"
    echo ""

    # List patterns from this category
    local count=0
    local in_patterns=false
    local current_id=""
    local current_name=""
    local current_category=""
    local current_context=""
    local current_solution=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^patterns: ]]; then
            in_patterns=true
            continue
        elif [[ "$line" =~ ^anti_patterns: ]]; then
            in_patterns=false
            continue
        fi

        if [[ "$in_patterns" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"(.*)\" ]]; then
                # Print previous if it matched
                if [[ -n "$current_id" && "$current_category" == "$category" ]]; then
                    count=$((count + 1))
                    if [[ $count -le $limit ]]; then
                        echo -e "${CYAN}$count. $current_name${NC}"
                        echo -e "   ${YELLOW}When:${NC} $current_context"
                        echo -e "   ${GREEN}Solution:${NC} $current_solution"
                        echo ""
                    fi
                fi
                current_id="${BASH_REMATCH[1]}"
                current_name=""
                current_category=""
                current_context=""
                current_solution=""
            elif [[ "$line" =~ name:[[:space:]]*\"(.*)\" ]]; then
                current_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ category:[[:space:]]*\"(.*)\" ]]; then
                current_category="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ context:[[:space:]]*\"(.*)\" ]]; then
                current_context="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ solution:[[:space:]]*\"(.*)\" ]]; then
                current_solution="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$PATTERNS_FILE"

    # Don't forget the last one
    if [[ -n "$current_id" && "$current_category" == "$category" && $count -lt $limit ]]; then
        count=$((count + 1))
        echo -e "${CYAN}$count. $current_name${NC}"
        echo -e "   ${YELLOW}When:${NC} $current_context"
        echo -e "   ${GREEN}Solution:${NC} $current_solution"
        echo ""
    fi

    if [[ $count -eq 0 ]]; then
        echo -e "No patterns found in category '$category'."
        echo -e "Run '${CYAN}patterns.sh list${NC}' to see all available patterns."
    fi
}

# Suggest relevant anti-patterns to watch out for
suggest_anti_patterns() {
    local context="$1"

    local context_keywords
    context_keywords=$(extract_keywords "$context")

    echo -e "${RED}=== Anti-Patterns to Watch Out For ===${NC}"
    echo ""

    local found=false
    local current_id=""
    local current_name=""
    local current_symptom=""
    local current_risk=""
    local current_fix=""
    local current_severity=""
    local in_anti=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^anti_patterns: ]]; then
            in_anti=true
            continue
        fi

        if [[ "$in_anti" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"(.*)\" ]]; then
                # Check previous anti-pattern for relevance
                if [[ -n "$current_id" ]]; then
                    local anti_keywords
                    anti_keywords=$(extract_keywords "$current_name $current_symptom $current_risk")
                    local score
                    score=$(calculate_match_score "$context_keywords" "$anti_keywords")

                    if [[ $score -gt 15 ]]; then
                        found=true
                        local severity_color="$YELLOW"
                        if [[ "$current_severity" == "critical" ]]; then
                            severity_color="$RED"
                        elif [[ "$current_severity" == "high" ]]; then
                            severity_color="$RED"
                        fi

                        echo -e "${severity_color}[${current_severity^^}] $current_name${NC}"
                        echo -e "   ${YELLOW}Symptom:${NC} $current_symptom"
                        echo -e "   ${RED}Risk:${NC} $current_risk"
                        echo -e "   ${GREEN}Fix:${NC} $current_fix"
                        echo ""
                    fi
                fi

                current_id="${BASH_REMATCH[1]}"
                current_name=""
                current_symptom=""
                current_risk=""
                current_fix=""
                current_severity=""
            elif [[ "$line" =~ name:[[:space:]]*\"(.*)\" ]]; then
                current_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ symptom:[[:space:]]*\"(.*)\" ]]; then
                current_symptom="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ risk:[[:space:]]*\"(.*)\" ]]; then
                current_risk="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ fix:[[:space:]]*\"(.*)\" ]]; then
                current_fix="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ severity:[[:space:]]*\"(.*)\" ]]; then
                current_severity="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$PATTERNS_FILE"

    # Check last anti-pattern
    if [[ -n "$current_id" ]]; then
        local anti_keywords
        anti_keywords=$(extract_keywords "$current_name $current_symptom $current_risk")
        local score
        score=$(calculate_match_score "$context_keywords" "$anti_keywords")

        if [[ $score -gt 15 ]]; then
            found=true
            local severity_color="$YELLOW"
            if [[ "$current_severity" == "critical" ]]; then
                severity_color="$RED"
            elif [[ "$current_severity" == "high" ]]; then
                severity_color="$RED"
            fi

            echo -e "${severity_color}[${current_severity^^}] $current_name${NC}"
            echo -e "   ${YELLOW}Symptom:${NC} $current_symptom"
            echo -e "   ${RED}Risk:${NC} $current_risk"
            echo -e "   ${GREEN}Fix:${NC} $current_fix"
            echo ""
        fi
    fi

    if [[ "$found" == "false" ]]; then
        echo -e "${GREEN}No specific anti-patterns to warn about for this context.${NC}"
    fi
}

# Get suggestions for a specific category
get_category_suggestions() {
    local category="$1"
    local limit="${2:-3}"

    echo -e "${BLUE}Top patterns for category: $category${NC}"
    echo ""

    local count=0
    awk -v cat="$category" -v lim="$limit" '
        BEGIN { in_patterns = 0; count = 0 }
        /^patterns:/ { in_patterns = 1; next }
        /^anti_patterns:/ { in_patterns = 0 }
        in_patterns && /- id:/ {
            gsub(/.*id: "/, ""); gsub(/".*/, "")
            id = $0
        }
        in_patterns && /name:/ {
            gsub(/.*name: "/, ""); gsub(/".*/, "")
            name = $0
        }
        in_patterns && /category:/ {
            gsub(/.*category: "/, ""); gsub(/".*/, "")
            entry_cat = $0
        }
        in_patterns && /solution:/ {
            gsub(/.*solution: "/, ""); gsub(/".*/, "")
            solution = $0
            if (entry_cat == cat && count < lim) {
                count++
                printf "%d. %s\n   Solution: %s\n\n", count, name, solution
            }
        }
    ' "$PATTERNS_FILE"
}

# Interactive suggestion mode (for potential future use)
interactive_suggest() {
    echo -e "${BLUE}Interactive Pattern Suggester${NC}"
    echo "Type your context or question, and I'll suggest relevant patterns."
    echo "Type 'quit' to exit."
    echo ""

    while true; do
        echo -n "> "
        read -r input

        if [[ "$input" == "quit" || "$input" == "exit" ]]; then
            echo "Goodbye!"
            break
        fi

        if [[ -n "$input" ]]; then
            echo ""
            suggest_patterns "$input"
            echo ""
        fi
    done
}
