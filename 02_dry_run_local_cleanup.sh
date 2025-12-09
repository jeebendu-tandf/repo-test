#!/bin/bash

###############################################################################
# SCRIPT NAME: delete_clean_local_with_log.sh
#
# PURPOSE:
#   Deletes ONLY LOCAL refs for branches where recommendation = "clean":
#     - Local branches:           refs/heads/<branch>
#     - Remote-tracking branches: refs/remotes/<remote>/<branch>
#
#   Column positions are detected from the CSV header by NAME, so
#   dynamic/variable merged_* columns do NOT break this script.
#
# INPUT:
#   git_reports/branches.csv
#     Must contain at least:
#       full_ref, short_name_without_remote, commit_full, recommendation
#
# OUTPUT:
#   git_reports/deleted_branches_log.csv
###############################################################################

LOG_DIR="git_reports"
CSV_FILE="$LOG_DIR/branches.csv"
LOG_FILE="$LOG_DIR/deleted_branches_log.csv"
RECOMMENDATION_TO_DELETE="clean"

strip_field() {
    local v="$1"
    v="${v%$'\r'}"
    v="${v%\"}"
    v="${v#\"}"
    printf '%s' "$v"
}

mkdir -p "$LOG_DIR"

if [[ ! -f "$CSV_FILE" ]]; then
    echo "❌ CSV file not found: $CSV_FILE"
    exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
    echo "branch_name,full_commit_id,deletion_time_iso" > "$LOG_FILE"
fi

# --- read header and detect column indices by name ---
{
    IFS= read -r header || { echo "❌ Empty CSV"; exit 1; }

    IFS=',' read -ra cols <<<"$header"

    idx_full_ref=-1
    idx_short_name=-1
    idx_commit_full=-1
    idx_recommendation=-1

    for i in "${!cols[@]}"; do
        name="$(strip_field "${cols[$i]}")"
        case "$name" in
            full_ref)                idx_full_ref=$i ;;
            short_name_without_remote) idx_short_name=$i ;;
            commit_full)             idx_commit_full=$i ;;
            recommendation)          idx_recommendation=$i ;;
        esac
    done

    if (( idx_full_ref < 0 || idx_short_name < 0 || idx_commit_full < 0 || idx_recommendation < 0 )); then
        echo "❌ Required columns not found in header."
        echo "   Need: full_ref, short_name_without_remote, commit_full, recommendation"
        exit 1
    fi

    # --- process data lines ---
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        IFS=',' read -ra fields <<<"$line"

        full_ref_raw="${fields[$idx_full_ref]:-}"
        short_name_raw="${fields[$idx_short_name]:-}"
        commit_full_raw="${fields[$idx_commit_full]:-}"
        recommendation_raw="${fields[$idx_recommendation]:-}"

        full_ref_clean=$(strip_field "$full_ref_raw")
        short_name_clean=$(strip_field "$short_name_raw")
        commit_full_clean=$(strip_field "$commit_full_raw")
        recommendation_clean=$(strip_field "$recommendation_raw")

        # skip summary / garbage lines
        [[ "$full_ref_clean" != refs/remotes/* ]] && continue

        # only act on recommendation = clean
        [[ "$recommendation_clean" != "$RECOMMENDATION_TO_DELETE" ]] && continue

        echo "▶ Candidate for deletion: $short_name_clean ($full_ref_clean, commit $commit_full_clean)"

        deleted_something=false
        deletion_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # 1) delete local branch if exists
        if git show-ref --verify --quiet "refs/heads/$short_name_clean"; then
            echo "$short_name_clean,$commit_full_clean,$deletion_time" >> "$LOG_FILE"
            echo "  ✅ Deleting LOCAL branch: $short_name_clean"
            git branch -D "$short_name_clean"
            deleted_something=true
        fi

        # 2) delete local remote-tracking ref if exists
        if git show-ref --verify --quiet "$full_ref_clean"; then
            echo "$short_name_clean,$commit_full_clean,$deletion_time" >> "$LOG_FILE"
            echo "  ✅ Deleting LOCAL REMOTE-TRACKING ref: $full_ref_clean"
            git update-ref -d "$full_ref_clean"
            deleted_something=true
        fi

        if [[ "$deleted_something" == false ]]; then
            echo "  ⚠️  No local refs found for: $short_name_clean ($full_ref_clean), skipping."
        else
            echo "  📝 Logged to: $LOG_FILE"
        fi

    done

} < "$CSV_FILE"

echo "===== LOCAL CLEANUP COMPLETE ====="
echo "Recovery log saved to: $LOG_FILE"
