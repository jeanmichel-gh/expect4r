# Focused review and cross-platform validation

Date: 2026-11-13. Reviewed baseline: `7247720` on `feature/expect4r-v2`, covering
P1–P6 and configurable interaction keys. This is a focused review by the implementation
assistant, not an independent external audit. Reproducible findings below are fixed
in the accompanying changes and covered by `test/core/review_regression_test.rb`.

## Findings and fixes

| Priority | Finding and concrete trigger | Fix |
|---|---|---|
| P1 | Overlapping secret occurrences were not fully covered: filtering `abcdef` with registered `abc` and `bcdef` produced `[REDACTED]def` | Merge all matching intervals, carry masked overlap across chunks and censor incomplete final prefixes |
| P2 | Direct Redactor use with non-ASCII text could mix regexp/string character indexes with byte slicing | Convert input to binary before searching and slicing; test `ésecret!` |
| P1 | Read-side deadline diagnostics could raise before fresh backpressure input was retained; ordinary receive diagnostics could also skip advancing redaction state | Retain protocol bytes and advance streaming redaction before invoking fallible callbacks/sinks |
| P1 | A transcript failure during overflow replaced `BufferOverflow` with `TransportError`, losing access to rejected bytes | Preserve overflow as the primary error and keep transcript/diagnostic failures in `cleanup_errors` |
| P2 | Remote EOF discarded a held escape prefix and could process newly ready keyboard input after closure | Return the held prefix in `InteractionResult#pending_input`; leave new keyboard input unread |

The overlap fix can emit more than one `[REDACTED]` marker for a contiguous masked
region when it spans successive emissions. Registered secret bytes remain covered.
Raw protocol IO, explicit result payloads and human terminal display remain raw by
contract; filtering still requires registration before receipt/transmission.

The overflow fix preserves the original error's `buffer` and `rejected` snapshots;
it does not silently disable capture limits. Diagnostic failures on otherwise normal
reads still propagate, with received bytes retained for explicit recovery. No automatic
command replay is introduced.

## Scope

Checked matching/consumption and staging, capture write accounting, streaming
redaction and diagnostic error precedence, recording/replay structure and timing,
manual interaction, and ownership/cleanup boundaries. Existing tests also cover
router modes, configuration depth, paging, ping and candidate cleanup. No additional
reproducible replay defect was identified in this pass; that is not a guarantee that
all timing/terminal/firmware edge cases are covered.

Regression cases include overlapping and fragmented literals, non-ASCII byte offsets,
sink failure plus overflow, receive diagnostics during writer backpressure, redactor
continuity after a failed read diagnostic, held escape prefixes at EOF, and fresh
keyboard input arriving with EOF.

## Validation

| Environment | Core | Router application | Legacy |
|---|---|---|---|
| Native macOS ARM64, rv Ruby 4.0.9 | 140 tests / 787 assertions, passed | 30 / 266, passed | 20 / 68, passed |
| Linux ARM64 container, Ruby 4.0.6 | 140 tests / 787 assertions, passed | 30 / 266, passed | 20 / 68, passed |

Each environment passed **190 tests / 1,121 assertions**. Linux used a disposable
source copy in the user's reachable VM; implementation changes remain in the Mac
checkout. The Linux run additionally passed local dialogue, record/replay and router
simulator examples, both gem builds, source-to-gem file-list/content comparisons,
and isolated core/companion installation checks. The final Mac gem builds and
installed-gem checks are recorded with the same review changes.

`git diff --check` passes. GitHub CI execution is a separate check after pushing.

## Remaining work

- Manually exercise interaction from the user's real Mac terminal: custom return
  key, terminal restoration, and return to automation. Automated PTY tests are useful
  but do not replace this user check.
- Review the public API and retained compatibility choices before release.
- Validate actual IOS/IOS-XR/Junos firmware and add sanitized device recordings.
- Push the branch and review the resulting draft PR/CI before merging or publishing.

No real-router compatibility or release-readiness approval is implied by these results.
