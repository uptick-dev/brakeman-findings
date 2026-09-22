#!/usr/bin/env bash
# Drives emit-findings.sh against a stubbed Brakeman covering the report shapes
# it has to distinguish, including the ones that must not read as clean.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

pass=0; fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
contains() { case "$2" in *"$1"*) echo yes;; *) echo no;; esac; }

setup() {
  WORK="$(mktemp -d)"
  export RUNNER_TEMP="$WORK"
  export GITHUB_OUTPUT="$WORK/gh_output"
  export FINDINGS_OUTPUT="$WORK/findings.jsonl"
  export CHECK_LATEST=false
  : > "$GITHUB_OUTPUT"
  mkdir -p "$WORK/bin"
}
# $1 = report JSON written to --output, $2 = exit code, $3 = ensure-latest exit
stub_brakeman() {
  cat > "$WORK/bin/brakeman" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--ensure-latest" ] && { echo "Brakeman is not the latest version"; exit ${3:-0}; }; done
out=""
while [ \$# -gt 0 ]; do [ "\$1" = "--output" ] && { out="\$2"; shift; }; shift; done
[ -n "\$out" ] && printf '%s' '$1' > "\$out"
exit ${2:-0}
STUB
  chmod +x "$WORK/bin/brakeman"
  export BRAKEMAN_COMMAND="$WORK/bin/brakeman"
}
run() { OUT="$(bash "$ROOT/emit-findings.sh" 2>&1)"; RC=$?; }
out_val() { local v; v="$(grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"; echo "${v:-unset}"; }
findings() { grep -c '' "$FINDINGS_OUTPUT" 2>/dev/null; true; }

WARNINGS='{"warnings":[{"warning_type":"SQL Injection","check_name":"SQL","confidence":"Medium","file":"app/models/user.rb","line":12,"fingerprint":"abc123","message":"Possible SQL injection","code":"User.where(params[:q])","link":"https://example.test/sql"},{"warning_type":"Cross-Site Scripting","check_name":"CrossSiteScripting","confidence":"High","file":"app/views/show.erb","line":3,"fingerprint":"def456","message":"Unescaped parameter"}]}'

echo "== one finding per warning, keyed by fingerprint =="
setup; stub_brakeman "$WARNINGS" 0
run
check "exit 0" "0" "$RC"
check "two findings" "2" "$(findings)"
check "count output" "2" "$(out_val count)"
check "completed" "true" "$(out_val completed)"
check "keyed by fingerprint" "yes" "$(contains '"key":"brakeman/abc123"' "$(cat "$FINDINGS_OUTPUT")")"
check "no line number in key" "no" "$(contains 'brakeman/app/models/user.rb:12' "$(cat "$FINDINGS_OUTPUT")")"
check "code block rendered" "yes" "$(contains 'User.where(params[:q])' "$(cat "$FINDINGS_OUTPUT")")"

echo "== a clean report emits nothing =="
setup; stub_brakeman '{"warnings":[]}' 0
run
check "no findings" "0" "$(findings)"
check "completed" "true" "$(out_val completed)"

echo "== an empty report is a scan failure, not a clean result =="
setup; stub_brakeman '' 0
run
check "exit 0" "0" "$RC"
check "one finding" "1" "$(findings)"
check "keyed scan/brakeman" "yes" "$(contains '"key":"scan/brakeman"' "$(cat "$FINDINGS_OUTPUT")")"
check "completed is false" "false" "$(out_val completed)"
check "warns" "yes" "$(contains '::warning::Brakeman did not complete' "$OUT")"

echo "== a non-zero exit is a scan failure =="
setup; stub_brakeman '{"warnings":[]}' 3
run
check "keyed scan/brakeman" "yes" "$(contains '"key":"scan/brakeman"' "$(cat "$FINDINGS_OUTPUT")")"
check "completed is false" "false" "$(out_val completed)"

echo "== a malformed report is a scan failure =="
setup; stub_brakeman 'not json at all' 0
run
check "keyed scan/brakeman" "yes" "$(contains '"key":"scan/brakeman"' "$(cat "$FINDINGS_OUTPUT")")"
check "completed is false" "false" "$(out_val completed)"

echo "== a report without a warnings array is a scan failure =="
setup; stub_brakeman '{"scan_info":{}}' 0
run
check "completed is false" "false" "$(out_val completed)"

echo "== an out-of-date Brakeman is its own finding =="
setup; stub_brakeman "$WARNINGS" 0 5
export CHECK_LATEST=true
run
check "three findings" "3" "$(findings)"
check "version finding present" "yes" "$(contains '"key":"tooling/brakeman-version"' "$(cat "$FINDINGS_OUTPUT")")"
check "still completed" "true" "$(out_val completed)"

echo "== an up-to-date Brakeman adds nothing =="
setup; stub_brakeman "$WARNINGS" 0 0
export CHECK_LATEST=true
run
check "two findings" "2" "$(findings)"

echo "== keys are unique =="
setup; stub_brakeman "$WARNINGS" 0
run
check "no duplicate keys" "0" "$(jq -r .key "$FINDINGS_OUTPUT" | sort | uniq -d | grep -c '')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
