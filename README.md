# brakeman-findings

Run Brakeman over the whole application and emit one JSONL finding per warning,
for [`security-findings-issues`](https://github.com/ten-thousand-hammers/security-findings-issues)
to track as issues.

Brakeman reports problems in code you wrote. There is no package to bump, so
nothing else raises them — Dependabot has no view of first-party source.

## Usage

```yaml
- name: Brakeman
  id: brakeman
  uses: ten-thousand-hammers/brakeman-findings@v1
  with:
    output: ${{ runner.temp }}/findings/brakeman.jsonl

- uses: ten-thousand-hammers/security-findings-issues@v1
  with:
    findings: ${{ runner.temp }}/findings.jsonl
    token: ${{ secrets.GITHUB_TOKEN }}
    close-resolved: ${{ steps.brakeman.outputs.completed }}
```

### Inputs

| input | default | description |
| --- | --- | --- |
| `brakeman-command` | `bundle exec brakeman` | How to invoke Brakeman. Use `brakeman` when it is installed standalone, or `bin/brakeman` for a binstub. |
| `output` | `$RUNNER_TEMP/findings/brakeman.jsonl` | JSONL file to append findings to. |
| `check-latest` | `false` | Also report Brakeman being out of date. See below. |

### Outputs

| output | description |
| --- | --- |
| `count` | Number of findings written. |
| `completed` | `false` when Brakeman produced no usable report. |

## Keys

Findings are keyed `brakeman/<fingerprint>`, using Brakeman's own fingerprint.
That is what it is for: it survives the warning moving to a different line, so
editing the file above a warning does not close its issue and open a new one.

A line number would not survive that, and must not be used.

A scan that could not run is keyed `scan/brakeman` instead, so it is visible
rather than silently absent.

## A scan that did not run is not a clean result

Brakeman exits non-zero for operational failures as well as findings, and an
empty file parses as valid JSON, so neither the exit code nor `jq empty` can
tell a clean report from no report. This checks that the report has the shape
it should — `.warnings` is an array — and otherwise emits a `scan/brakeman`
finding and sets `completed=false`.

Pass that to `security-findings-issues`' `close-resolved`. A run where the
scanner did not execute reports nothing, which is indistinguishable from
finding nothing; closing on it would retire live findings.

## `check-latest` is off by default

Brakeman's `--ensure-latest` exits 5 when a newer release exists. That is a gem
version bump, which Dependabot's bundler ecosystem already raises as a pull
request — and a pull request that fixes it beats an issue asking someone to.

Turn it on only where Dependabot does not watch the bundle.

## Tests

```bash
bash test/emit_test.sh
```

They run the real script against a stubbed Brakeman covering a normal report, a
clean report, an empty file, a non-zero exit, malformed JSON, a report with no
`warnings` array, and the out-of-date case.
