#!/usr/bin/env bash
# branch_report_remote_envs.sh
#
# SUMMARY:
# - Scans ONLY local remote-tracking refs (no fetch/pull).
# - Excludes environment branches listed in ENV_BRANCHES.
# - Checks merge status into each environment branch.
# - Calculates commit age (days) and reachable commit count.
# - Generates recommendations: clean / review / critical.
# - Outputs a timestamped CSV report with a summary section.
# - Includes FULL commit ID for safe branch recovery.

ENV_BRANCHES=(dev qa prod main)

set -euo pipefail

# === Create reports folder & timestamped filename ===
REPORT_DIR="git_reports"
mkdir -p "$REPORT_DIR"

BASE_NAME="${1:-remote_env_report}"
TS="$(date +%Y-%m-%d_%H-%M-%S)"
OUTFILE="${REPORT_DIR}/${BASE_NAME}_${TS}.csv"

REMOTE="${2:-origin}"
REVIEW_DAYS="${3:-14}"

# Ensure inside git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not a git repository." >&2
  exit 2
fi

# CSV escape helper
csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

# Resolve env references
declare -A ENV_REF_MAP
for env in "${ENV_BRANCHES[@]}"; do
  if git show-ref --quiet "refs/heads/${env}"; then
    ENV_REF_MAP["$env"]="refs/heads/${env}"
  elif git show-ref --quiet "refs/remotes/${REMOTE}/${env}"; then
    ENV_REF_MAP["$env"]="refs/remotes/${REMOTE}/${env}"
  else
    ENV_REF_MAP["$env"]=""
  fi
done

# Optional main/master
MAIN_REF=""
if git show-ref --quiet refs/heads/main; then
  MAIN_REF="refs/heads/main"
elif git show-ref --quiet refs/heads/master; then
  MAIN_REF="refs/heads/master"
fi

# ===== CSV HEADER =====
header="full_ref,short_name_without_remote,commit_full,author,date_iso"
for env in "${ENV_BRANCHES[@]}"; do
  header+=",merged_into_${env}"
done
header+=",notes,recommendation,commit_age_days,last_activity_commits"
printf '%s\n' "$header" > "$OUTFILE"

# Collect remote refs
mapfile -t REFS < <(git for-each-ref --format='%(refname)' "refs/remotes/${REMOTE}" 2>/dev/null || true)

REFS_FILTERED=()
for r in "${REFS[@]}"; do
  [ -z "$r" ] && continue
  short="${r#refs/remotes/}"
  [[ "$short" == */HEAD ]] && continue
  REFS_FILTERED+=("$r")
done

# Summary counters
total_refs=0
refs_with_no_commit=0
refs_with_no_commit_for_count=0
declare -A ENV_MERGED_COUNT ENV_NOREF_COUNT ENV_NOCOMMIT_COUNT RECOMM_COUNT

for env in "${ENV_BRANCHES[@]}"; do
  ENV_MERGED_COUNT[$env]=0
  ENV_NOREF_COUNT[$env]=0
  ENV_NOCOMMIT_COUNT[$env]=0
done

RECOMM_COUNT[clean]=0
RECOMM_COUNT[review]=0
RECOMM_COUNT[critical]=0

earliest_date=""
latest_date=""

# Helper: ISO → epoch
iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && return
  date -d "$iso" +%s 2>/dev/null || true
}

# ===== PROCESS EACH REMOTE BRANCH =====
now_ts="$(date +%s)"

for ref in "${REFS_FILTERED[@]}"; do
  total_refs=$((total_refs + 1))

  notes=""
  short_full="${ref#refs/remotes/}"
  short_no_remote="${short_full#${REMOTE}/}"

  # ---- EXCLUDE ENV BRANCHES ----
  for env in "${ENV_BRANCHES[@]}"; do
    if [ "$short_no_remote" = "$env" ]; then
      continue 2
    fi
  done

  commit_full="$(git rev-parse --verify "$ref" 2>/dev/null || true)"

  if [ -n "$commit_full" ]; then
    author="$(git show -s --format='%an' "$commit_full")"
    date_iso="$(git show -s --format='%aI' "$commit_full")"
  else
    commit_full=""
    author=""
    date_iso=""
    notes="no-commit-found"
    refs_with_no_commit=$((refs_with_no_commit + 1))
  fi

  if [ -n "$date_iso" ]; then
    [[ -z "$earliest_date" || "$date_iso" < "$earliest_date" ]] && earliest_date="$date_iso"
    [[ -z "$latest_date"  || "$date_iso" > "$latest_date"  ]] && latest_date="$date_iso"
  fi

  merged_values=()
  merged_any=0
  merged_into_main_or_master=0

  for env in "${ENV_BRANCHES[@]}"; do
    env_ref="${ENV_REF_MAP[$env]}"

    if [ -z "$env_ref" ]; then
      merged_values+=("unknown-no-ref")
      ENV_NOREF_COUNT[$env]=$((ENV_NOREF_COUNT[$env] + 1))
      continue
    fi

    if [ -z "$commit_full" ]; then
      merged_values+=("no-commit")
      ENV_NOCOMMIT_COUNT[$env]=$((ENV_NOCOMMIT_COUNT[$env] + 1))
      continue
    fi

    if git merge-base --is-ancestor "$ref" "$env_ref" 2>/dev/null; then
      merged_values+=("yes")
      ENV_MERGED_COUNT[$env]=$((ENV_MERGED_COUNT[$env] + 1))
      merged_any=1
      if [ "$env" = "master" ] || [ "$env" = "main" ]; then
        merged_into_main_or_master=1
      fi
    else
      merged_values+=("no")
    fi
  done

  # ---- commit_age_days ----
  commit_age_days=""
  if [ -n "$date_iso" ]; then
    commit_epoch="$(iso_to_epoch "$date_iso")"
    [ -n "$commit_epoch" ] && commit_age_days=$(( (now_ts - commit_epoch) / 86400 ))
  fi

  # ---- last_activity_commits ----
  last_activity_commits=""
  if [ -n "$commit_full" ]; then
    cnt="$(git rev-list --count "$ref" 2>/dev/null || true)"
    if [ -n "$cnt" ]; then
      last_activity_commits="$cnt"
    else
      refs_with_no_commit_for_count=$((refs_with_no_commit_for_count + 1))
    fi
  fi

  # ===== RECOMMENDATION LOGIC =====
  recommendation="clean"

  if [ -z "$commit_full" ]; then
    recommendation="critical"
  else
    if [ "$merged_into_main_or_master" -eq 1 ]; then
      if [ -n "$commit_age_days" ] && [ "$commit_age_days" -lt "$REVIEW_DAYS" ]; then
        recommendation="review"
      else
        recommendation="clean"
      fi
    else
      if [ "$merged_any" -eq 1 ]; then
        recommendation="review"
      else
        recommendation="clean"   # ✅ NO MERGES ⇒ CLEAN
      fi
    fi
  fi

  for mv in "${merged_values[@]}"; do
    if [ "$mv" = "unknown-no-ref" ] && [ "$recommendation" = "clean" ]; then
      recommendation="review"
      break
    fi
  done

  RECOMM_COUNT[$recommendation]=$((RECOMM_COUNT[$recommendation] + 1))

  # ===== CSV ROW =====
  row=""
  row+=$(csv_escape "$ref"), 
  row+=$(csv_escape "$short_no_remote"), 
  row+=$(csv_escape "$commit_full"), 
  row+=$(csv_escape "$author"), 
  row+=$(csv_escape "$date_iso")

  for mv in "${merged_values[@]}"; do
    row+=","$(csv_escape "$mv")
  done

  row+=","$(csv_escape "$notes")
  row+=","$(csv_escape "$recommendation")
  row+=","$(csv_escape "${commit_age_days}")
  row+=","$(csv_escape "${last_activity_commits}")

  printf '%s\n' "$row" >>"$OUTFILE"
done

# ===== SUMMARY =====
{
  repo_name="$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")"
  repo_name="${repo_name##*/}"

  printf '\nRepository Summary - %s\n' "$repo_name"
  printf 'Total Remote References: %d\n\n' "$total_refs"

  printf 'Environment Merge Status\n'
  for env in "${ENV_BRANCHES[@]}"; do
    printf '%s: %d merged\n' "$env" "${ENV_MERGED_COUNT[$env]}"
  done

  printf '\nRecommendations\n'
  printf 'Clean: %d references\n' "${RECOMM_COUNT[clean]}"
  printf 'Review: %d references\n' "${RECOMM_COUNT[review]}"
  printf 'Critical: %d references\n' "${RECOMM_COUNT[critical]}"
} >> "$OUTFILE"

echo "Wrote: $OUTFILE"
