#!/usr/bin/env bash

remove_fixture() {
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] || return 0

    local attempt
    for attempt in $(seq 1 50); do
        rm -rf "$dir" 2>/dev/null || true
        [[ -d "$dir" ]] || return 0
        sleep 0.1
    done

    rm -rf "$dir"
}
