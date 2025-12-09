#!/bin/bash

###############################################################################
# SCRIPT NAME: delete_clean_local_with_log.sh
#
# PURPOSE:
#   Deletes ONLY LOCAL refs for branches where recommendation = "clean":
#     - Local branches:          refs/heads/<branch>
#     - Remote-tracking branches: refs/remotes/<remote>/<branch>
#
#   And writes a recovery-friendly CSV log containing:
#     - Branch Name
#     - Full Commit ID (from CSV)
#     - Deletion Timestamp (UTC)
#
#   ✅ SAFE: Does NOT touch the actual remote server (no git push)
#   ✅ LOG: Writes log to git_reports/deleted_branches_log.csv
#
# INPUT:
#   git_reports/branches.csv
#     Columns (from your report script):
#       full_ref,short_name_without_remote,commit_full,author,
#       date_iso,merged_into_master,notes,recommendation,
#       commit_age_days,last_activity_commits
#
# OUTPUT:
#   git_reports/deleted_branches_log.csv
#
# RECOVERY:
#   To restore a branch:
#     git checkout -b <branch_name> <full_commit_id>
###############################################################################

LOG_DIR="git_reports"
CSV_FILE="$LOG_DIR/branches.csv"
LOG_FILE="$LOG_DIR/deleted_branches_log.csv"
RECOMMENDATION_TO_DELETE="clean"

# Helper: strip surrounding quotes and CR
strip_field() {
    local v="$1"
    v="${v%$'\r'}"   # strip CR if present
    v="${v%\"}"      # strip trailing "
    v="${v#\"}"      # strip leading "
    printf '%s' "$v"
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Ensure input CSV exists
if [[ ! -f "$CSV_FILE" ]]; then
    echo "❌ CSV file not found: $CSV_FILE"
    exit 1
fi

# Create log file with header if not exists
if [[ ! -f "$LOG_FILE" ]]; then
    echo "branch_name,full_commit_id,deletion_time_iso" > "$LOG_FILE"
fi

# Skip header and process each CSV row
tail -n +2 "$CSV_FILE" | while IFS=',' read -r \
    full_ref short_name commit_full author date_iso \
    merged_master notes recommendation commit_age_days last_activity_commits
do
    # Clean fields
    full_ref_clean=$(strip_field "$full_ref")
    short_name_clean=$(strip_field "$short_name")
    commit_full_clean=$(strip_field "$commit_full")
    recommendation_clean=$(strip_field "$recommendation")

    # Skip non-data lines (summary, blank, etc.)
    if [[ "$full_ref_clean" != refs/remotes/* ]]; then
        continue
    fi

    if [[ "$recommendation_clean" == "$RECOMMENDATION_TO_DELETE" ]]; then
        echo "▶ Candidate for deletion: $short_name_clean ($full_ref_clean, commit $commit_full_clean)"

        deleted_something=false

        # 1) Delete local branch if it exists
        if git show-ref --verify --quiet "refs/heads/$short_name_clean"; then
            DELETION_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            echo "$short_name_clean,$commit_full_clean,$DELETION_TIME" >> "$LOG_FILE"

            echo "  ✅ Deleting LOCAL branch: $short_name_clean"
            git branch -D "$short_name_clean"
            deleted_something=true
        fi

        # 2) Delete remote-tracking branch (local ref only), don’t touch server
        if git show-ref --verify --quiet "$full_ref_clean"; then
            DELETION_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            echo "$short_name_clean,$commit_full_clean,$DELETION_TIME" >> "$LOG_FILE"

            echo "  ✅ Deleting LOCAL REMOTE-TRACKING ref: $full_ref_clean"
            git update-ref -d "$full_ref_clean"
            deleted_something=true
        fi

        if [[ "$deleted_something" == false ]]; then
            echo "  ⚠️  No local refs found for: $short_name_clean ($full_ref_clean), skipping."
        else
            echo "  📝 Logged to: $LOG_FILE"
        fi
    else
        echo "⏭️  Skipping: $short_name_clean (recommendation: $recommendation_clean)"
    fi
done

echo "===== LOCAL CLEANUP COMPLETE ====="
echo "Recovery log saved to: $LOG_FILE"
