#!/usr/bin/env bash
# lock.sh - Portable file locking for append-only writes
#
# Uses mkdir (atomic on POSIX) as a lock. Falls back to unlocked
# writes if lock acquisition fails after timeout — never blocks
# the caller indefinitely.
#
# Usage:
#   source lib/lock.sh
#   lore_locked_append "$file" "$content"

_LOCK_TIMEOUT="${LORE_LOCK_TIMEOUT:-2}"  # seconds

# Acquire a lock for the given file path.
# Returns 0 on success, 1 on timeout.
_lore_lock() {
    local file="$1"
    local lockdir="${file}.lock"
    local deadline=$((SECONDS + _LOCK_TIMEOUT))

    while ! mkdir "$lockdir" 2>/dev/null; do
        if [[ $SECONDS -ge $deadline ]]; then
            # Stale lock check: remove locks older than 10 seconds
            if [[ -d "$lockdir" ]]; then
                local lock_age
                lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
                if [[ $lock_age -gt 10 ]]; then
                    rmdir "$lockdir" 2>/dev/null || true
                    continue
                fi
            fi
            return 1
        fi
        sleep 0.05
    done
    return 0
}

# Release the lock for the given file path.
_lore_unlock() {
    local file="$1"
    rmdir "${file}.lock" 2>/dev/null || true
}

# Append content to file with locking.
# Falls back to unlocked append on timeout (append is mostly atomic
# for small writes on local filesystems, so this is acceptable).
lore_locked_append() {
    local file="$1"
    local content="$2"

    if _lore_lock "$file"; then
        echo "$content" >> "$file"
        _lore_unlock "$file"
    else
        # Fallback: unlocked append (small writes are atomic on most FS)
        echo "$content" >> "$file"
    fi
}
