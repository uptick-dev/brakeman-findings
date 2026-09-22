#!/usr/bin/env bash
# Emit one JSONL finding per Brakeman warning.
# This script inspects exit codes itself -- a scanner that fails is a finding,
# not a reason to abort -- so errexit must stay off, including when a caller
# exports it through SHELLOPTS.
set -uo pipefail
set +e

command_line="${BRAKEMAN_COMMAND:-bundle exec brakeman}"
out="${FINDINGS_OUTPUT:-${RUNNER_TEMP:-/tmp}/findings/brakeman.jsonl}"
report="${RUNNER_TEMP:-/tmp}/brakeman-findings.json"
mkdir -p "$(dirname "$out")"
: > "$out"

# shellcheck disable=SC2086
$command_line --format json --output "$report" \
  --no-exit-on-warn --no-exit-on-error --quiet .
code=$?

emit_scan_failure() {
  jq -cn --arg detail "$1" --arg code "$code" '{
    key: "scan/brakeman",
    title: "Security scan: Brakeman could not complete",
    body: ("Brakeman exited \($code) without a usable report, so application code is currently unscanned.\n\n" + $detail)
  }' >> "$out"
  {
    echo "count=1"
    echo "completed=false"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "::warning::Brakeman did not complete; reporting the scan failure as a finding."
}

# `jq empty` succeeds on an empty file, so it cannot tell a clean report from no
# report at all. Check that the report has the shape it should.
if [ "$code" -gt 0 ] || ! jq -e '.warnings | type == "array"' "$report" >/dev/null 2>&1; then
  emit_scan_failure "$(tail -20 "$report" 2>/dev/null || echo 'No report was written.')"
  exit 0
fi

# The fingerprint is stable across line moves and refactors, which is exactly
# what an issue key needs. A line number is not.
jq -c '
  .warnings[]? |
  {
    key: ("brakeman/" + .fingerprint),
    title: ("Security: " + .warning_type + " in " + .file
            + " (" + .confidence + " confidence)"),
    body: (
      "**Check:** " + (.check_name // "unknown") + "  \n" +
      "**Confidence:** " + .confidence + "  \n" +
      "**Location:** `" + .file + ":" + ((.line // "?") | tostring) + "`"
      + (if .code then "\n\n```ruby\n" + .code + "\n```" else "" end)
      + "\n\n" + .message
      + (if .link then "\n\n[More on this check](" + .link + ")" else "" end)
      + "\n\nIf this is a false positive, record it with `brakeman -I` rather than closing the issue by hand: a closed issue is reopened as a new one on the next run."
    )
  }' "$report" >> "$out"

if [ "${CHECK_LATEST:-false}" = "true" ]; then
  # shellcheck disable=SC2086
  latest="$($command_line --ensure-latest --quiet --no-exit-on-warn --no-exit-on-error 2>&1)"
  latest_code=$?
  # 5 is specifically "not the latest version"; anything else is a clean run or
  # a problem the scan above already reported.
  if [ "$latest_code" -eq 5 ]; then
    detail="$(printf '%s\n' "$latest" | grep -i "not the latest" || echo "A newer Brakeman release is available.")"
    jq -cn --arg d "$detail" '{
      key: "tooling/brakeman-version",
      title: "Security: Brakeman is out of date",
      body: ($d + "\n\nUpdate the gem so new checks are actually running. Pull requests are not failed for this.")
    }' >> "$out"
  fi
fi

count="$(grep -c '' "$out")"
{
  echo "count=$count"
  echo "completed=true"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$count Brakeman finding(s)."
