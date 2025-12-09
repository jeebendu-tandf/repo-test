#!/bin/bash

###############################################################################
# SCRIPT NAME: push_restored_branches_to_remote.sh
#
# PURPOSE:
#   Push locally restored branches (already recreated) back to the remote
#   Git server, using the deletion log as the source of branch names.
#
# INPUT:
#   git_reports/deleted_branches_log.csv
#     Format:
#       branch_name,full_commit_id,deletion_time_iso
#
# BEHAVIOUR:
#   - For each UNIQUE branch_name in the log:
#       * If local branch exists (refs/heads/<branch_name>):
#             git push <remote> <branch_name>
#       * Else: print a warning (you said you already handle local restore)
#
# USAGE:
#   ./push_restored_branches_to_remote.sh        # uses origin
#   ./push_restored_branches_to_remote.sh upstream  # custom remote
###############################################################################

LOG_DIR="git_reports"
LOG_FILE="$LOG_DIR/deleted_branches_log.csv"
REMOTE="${1:-origin}"

# Strip quotes/CR
strip_field() {
  local v="$1"
  v="${v%$'\r'}"
  v="${v%\"}"
  v="${v#\"}"
  printf '%s' "$v"
}

# Ensure inside git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ Not a git repository."
  exit 1
fi

# Ensure log exists
if [[ ! -f "$LOG_FILE" ]]; then
  echo "❌ Log file not found: $LOG_FILE"
  exit 1
fi

echo "Remote: $REMOTE"
echo "Using log: $LOG_FILE"
echo

# To avoid pushing the same branch multiple times if logged multiple times
declare -A SEEN

# Skip header and process log rows
tail -n +2 "$LOG_FILE" | while IFS=',' read -r branch_name full_commit_id deletion_time; do
  branch_clean=$(strip_field "$branch_name")
  [[ -z "$branch_clean" ]] && continue

  # skip duplicates
  if [[ -n "${SEEN[$branch_clean]}" ]]; then
    continue
  fi
  SEEN["$branch_clean"]=1

  echo "▶ Checking branch: $branch_clean"

  if git show-ref --verify --quiet "refs/heads/$branch_clean"; then
    echo "   ✅ Local branch exists, pushing to '$REMOTE'..."
    git push "$REMOTE" "$branch_clean"
    echo "   ✅ Pushed: $branch_clean"
  else
    echo "   ⚠️ Local branch not found, NOT pushed: $branch_clean"
    echo "      (Restore it locally first, then re-run this script.)"
  fi

  echo "----------------------------------------"
done

echo "===== ✅ PUSH FROM LOG COMPLETE ====="
