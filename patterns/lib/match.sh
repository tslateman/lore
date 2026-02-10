#!/usr/bin/env bash
# Pattern matching functions
# Matches code/context against known patterns and anti-patterns

# Extract keywords from text for matching
extract_keywords() {
    local text="$1"
    # Convert to lowercase, extract words, remove common words
    echo "$text" | tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]' '\n' | \
        grep -v -E '^(the|a|an|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|could|should|may|might|must|shall|can|to|of|in|for|on|with|at|by|from|as|into|through|during|before|after|above|below|between|under|again|further|then|once|here|there|when|where|why|how|all|each|every|both|few|more|most|other|some|such|no|nor|not|only|own|same|so|than|too|very|just|also|now|and|but|if|or|because|until|while|although|though|after|before|since|unless)$' | \
        sort -u
}

# Calculate keyword overlap score
calculate_match_score() {
    local keywords1="$1"
    local keywords2="$2"

    local count1
    count1=$(echo "$keywords1" | wc -w)
    local count2
    count2=$(echo "$keywords2" | wc -w)

    if [[ $count1 -eq 0 || $count2 -eq 0 ]]; then
        echo "0"
        return
    fi

    local matches=0
    for word in $keywords1; do
        if echo "$keywords2" | grep -qw "$word"; then
            matches=$((matches + 1))
        fi
    done

    # Jaccard-like similarity
    local union=$((count1 + count2 - matches))
    if [[ $union -eq 0 ]]; then
        echo "0"
    else
        # Scale to 0-100 for easier handling in bash
        echo $((matches * 100 / union))
    fi
}

# Check if content contains specific code patterns
check_code_patterns() {
    local content="$1"
    local pattern_type="$2"

    case "$pattern_type" in
        bash_arithmetic)
            # Check for potentially problematic bash arithmetic
            if echo "$content" | grep -qE '\(\([a-zA-Z_]+\+\+\)\)|\(\([a-zA-Z_]+--\)\)'; then
                echo "found"
                return 0
            fi
            ;;
        baked_credentials)
            # Check for potential hardcoded credentials
            if echo "$content" | grep -qiE '(password|secret|api_key|apikey|token|credential).*=.*["\x27][^"\x27]+["\x27]'; then
                echo "found"
                return 0
            fi
            ;;
        set_e_without_trap)
            # Check for set -e without error handling
            if echo "$content" | grep -q 'set -e' && ! echo "$content" | grep -qE 'trap.*ERR|trap.*EXIT'; then
                echo "found"
                return 0
            fi
            ;;
        unsafe_rm)
            # Check for potentially dangerous rm commands
            if echo "$content" | grep -qE 'rm\s+-rf?\s+(/|\$\{?[A-Z_]+\}?/)'; then
                echo "found"
                return 0
            fi
            ;;
    esac

    echo "not_found"
}

# Check patterns against file or code
check_patterns() {
    local target="$1"
    local verbose="$2"

    local content=""
    local is_file=false

    # Determine if target is a file or inline code
    if [[ -f "$target" ]]; then
        content=$(cat "$target")
        is_file=true
        echo -e "${BLUE}Checking file:${NC} $target"
    else
        content="$target"
        echo -e "${BLUE}Checking code snippet${NC}"
    fi

    echo ""

    local found_issues=false
    local found_suggestions=false

    # Check for specific code anti-patterns
    echo -e "${YELLOW}=== Anti-Pattern Checks ===${NC}"

    # Bash arithmetic check
    if [[ $(check_code_patterns "$content" "bash_arithmetic") == "found" ]]; then
        found_issues=true
        echo -e "${RED}[!] Potential issue: Unsafe bash arithmetic${NC}"
        echo "    Pattern: ((var++)) or ((var--)) with set -e"
        echo "    Problem: Returns exit code 1 when var is 0, causing script to exit"
        echo "    Fix: Use var=\$((var + 1)) instead"
        if [[ "$verbose" == "true" ]]; then
            echo ""
            echo "    Matching lines:"
            echo "$content" | grep -nE '\(\([a-zA-Z_]+\+\+\)\)|\(\([a-zA-Z_]+--\)\)' | sed 's/^/      /'
        fi
        echo ""
    fi

    # Baked credentials check
    if [[ $(check_code_patterns "$content" "baked_credentials") == "found" ]]; then
        found_issues=true
        echo -e "${RED}[!] Potential issue: Hardcoded credentials${NC}"
        echo "    Symptom: Credentials stored directly in code"
        echo "    Risk: Credential exfiltration, security breach"
        echo "    Fix: Use environment variables or credential broker"
        if [[ "$verbose" == "true" ]]; then
            echo ""
            echo "    Matching lines:"
            echo "$content" | grep -niE '(password|secret|api_key|apikey|token|credential).*=.*["\x27][^"\x27]+["\x27]' | sed 's/^/      /'
        fi
        echo ""
    fi

    # set -e without trap check
    if [[ $(check_code_patterns "$content" "set_e_without_trap") == "found" ]]; then
        found_issues=true
        echo -e "${YELLOW}[?] Suggestion: set -e without error trap${NC}"
        echo "    Pattern: Using set -e without trap for cleanup"
        echo "    Consider: Add 'trap cleanup_function EXIT' for proper cleanup"
        echo ""
    fi

    # Unsafe rm check
    if [[ $(check_code_patterns "$content" "unsafe_rm") == "found" ]]; then
        found_issues=true
        echo -e "${RED}[!] Potential issue: Dangerous rm command${NC}"
        echo "    Pattern: rm -rf with root path or unquoted variable"
        echo "    Risk: Accidental deletion of critical files"
        echo "    Fix: Always quote variables and verify paths before deletion"
        if [[ "$verbose" == "true" ]]; then
            echo ""
            echo "    Matching lines:"
            echo "$content" | grep -nE 'rm\s+-rf?\s+(/|\$\{?[A-Z_]+\}?/)' | sed 's/^/      /'
        fi
        echo ""
    fi

    if [[ "$found_issues" == "false" ]]; then
        echo -e "${GREEN}No anti-patterns detected.${NC}"
    fi

    echo ""

    # Now check against stored patterns for suggestions
    echo -e "${BLUE}=== Pattern Suggestions ===${NC}"

    local content_keywords
    content_keywords=$(extract_keywords "$content")

    # Read patterns and check for matches
    local pattern_count=0
    while IFS= read -r line; do
        if [[ "$line" =~ context:\ \"(.*)\" ]]; then
            local context="${BASH_REMATCH[1]}"
            local context_keywords
            context_keywords=$(extract_keywords "$context")
            local score
            score=$(calculate_match_score "$content_keywords" "$context_keywords")

            if [[ $score -gt 20 ]]; then
                found_suggestions=true
                pattern_count=$((pattern_count + 1))

                # Get the pattern details
                echo -e "${CYAN}Match ($score% relevance):${NC}"
                # This is simplified - in production, we'd parse the full pattern
                echo "  Context: $context"
            fi
        fi
    done < "$PATTERNS_FILE"

    if [[ "$found_suggestions" == "false" ]]; then
        echo -e "${GREEN}No specific pattern suggestions for this code.${NC}"
    fi

    echo ""

    # Summary
    if [[ "$found_issues" == "true" ]]; then
        echo -e "${YELLOW}Summary: Issues found. Review the warnings above.${NC}"
        return 1
    else
        echo -e "${GREEN}Summary: Code looks good!${NC}"
        return 0
    fi
}

# Match context against patterns for relevance
match_patterns_to_context() {
    local context="$1"
    local limit="${2:-5}"

    local context_keywords
    context_keywords=$(extract_keywords "$context")

    local matches=()
    local scores=()

    # Parse patterns and calculate scores
    local current_id=""
    local current_name=""
    local current_context=""
    local current_solution=""
    local current_confidence=""
    local in_pattern=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*\"(.*)\" ]]; then
            # Save previous pattern if exists and has a score
            if [[ -n "$current_id" && -n "$current_context" ]]; then
                local pattern_keywords
                pattern_keywords=$(extract_keywords "$current_context $current_name")
                local score
                score=$(calculate_match_score "$context_keywords" "$pattern_keywords")

                if [[ $score -gt 10 ]]; then
                    # Weight by confidence
                    local weighted_score
                    weighted_score=$(echo "$score * ${current_confidence:-0.5}" | bc 2>/dev/null || echo "$score")
                    matches+=("$current_id|$current_name|$current_context|$current_solution|$weighted_score")
                fi
            fi

            current_id="${BASH_REMATCH[1]}"
            current_name=""
            current_context=""
            current_solution=""
            current_confidence=""
            in_pattern=true
        elif [[ "$in_pattern" == "true" ]]; then
            if [[ "$line" =~ name:[[:space:]]*\"(.*)\" ]]; then
                current_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ context:[[:space:]]*\"(.*)\" ]]; then
                current_context="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ solution:[[:space:]]*\"(.*)\" ]]; then
                current_solution="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ confidence:[[:space:]]*([0-9.]+) ]]; then
                current_confidence="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$PATTERNS_FILE"

    # Don't forget the last pattern
    if [[ -n "$current_id" && -n "$current_context" ]]; then
        local pattern_keywords
        pattern_keywords=$(extract_keywords "$current_context $current_name")
        local score
        score=$(calculate_match_score "$context_keywords" "$pattern_keywords")

        if [[ $score -gt 10 ]]; then
            matches+=("$current_id|$current_name|$current_context|$current_solution|$score")
        fi
    fi

    # Sort by score and return top matches
    printf '%s\n' "${matches[@]}" | sort -t'|' -k5 -rn | head -n "$limit"
}
