#!/bin/bash

###############################################################################
# SCRIPT NAME: delete_from_log_push_remote.sh
#
# PURPOSE:
#   Use the local deletion log as the FINAL list of branches to delete
#   from the remote Git server.
#
#   Reads:
#     git_reports/deleted_branches_log.csv
#       columns: branch_name,full_commit_id,deletion_time_iso
#
#   For each unique branch_name:
#     - Runs: git push <remote> --delete <branch_name>
#
# USAGE:
#   ./delete_from_log_push_remote.sh           # uses origin by default
#   ./delete_from_log_push_remote.sh upstream  # custom remote
###############################################################################

LOG_DIR="git_reports"
LOG_FILE="$LOG_DIR/deleted_branches_log.csv"
REMOTE="${1:-origin}"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "❌ Log file not found: $LOG_FILE"
  exit 1
fi

echo "Using remote: $REMOTE"
echo "Reading deletion log: $LOG_FILE"
echo

# Optional: small helper to strip CR/newlines
strip_field() {
  local v="$1"
  v="${v%$'\r'}"
  v="${v%\"}"
  v="${v#\"}"
  printf '%s' "$v"
}

# Keep track of branches we've already processed (in case of duplicates)
declare -A SEEN

# Skip header and process each log line
tail -n +2 "$LOG_FILE" | while IFS=',' read -r branch_name full_commit_id deletion_time; do
  branch_clean=$(strip_field "$branch_name")

  [[ -z "$branch_clean" ]] && continue

  # skip duplicates
  if [[ -n "${SEEN[$branch_clean]}" ]]; then
    continue
  fi
  SEEN["$branch_clean"]=1

  echo "🔥 Deleting remote branch '$branch_clean' from '$REMOTE' ..."
  git push "$REMOTE" --delete "$branch_clean"

  echo "-----------------------------------------------------"
done

echo "===== ✅ REMOTE CLEANUP FROM LOG COMPLETE ====="
