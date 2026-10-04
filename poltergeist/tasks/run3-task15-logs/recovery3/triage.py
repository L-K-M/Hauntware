import json
from pathlib import Path
p = Path(__file__).parent
threads = json.loads((p/'threads.json').read_text())['data']['repository']['pullRequest']['reviewThreads']['nodes']
assert len(threads) == 90
triage = {}
def mark(numbers, disposition, reason):
    for number in numbers:
        assert number not in triage
        triage[number] = (disposition, reason)
mark([1,39,68], 'decline', 'Internal invariant; config derives from this bookmark. Keep assert and single call site, not a release crash/silent return.')
mark([2], 'decline', 'No-engine panes deliberately show unavailable; shell registers no connect callback without a session.')
mark([3,21,56], 'apply', 'Runtime veto and covering-route tests were red. Guard route.isCurrent before maybePop and route.isActive after it; boolean suggestions are incorrect.')
mark([4], 'apply', 'Existing CommandChordScope skips unmodified activators before duplicate diagnostics.')
mark([5,6,25,55], 'defer', 'Comment/locale/path-contract polish; stabilization. Typed-path normalization remains with path editing.')
mark([7,9], 'refute', 'loading is false during channel-open phases; existing exclusion cannot hide the connecting spinner.')
mark([8,10], 'apply', 'Existing path bar initState/didUpdateWidget seed and reset the tail reveal.')
mark([11,12,13,14,15,22,23,24,32,42,43,45,46,47,52,53,57,58,59,60,61,62,63,64,75,76,77,84], 'defer', 'Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.')
mark([16,17,18,34,35,36,49,50,51,65,66,67,85], 'defer', 'Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.')
mark([19,71], 'defer', 'Equivalent loading predicates; consolidation is optional, not a correctness fix.')
mark([20], 'decline', 'Teardown failures remain diagnostic after disposal; reporting does not mutate pane state.')
mark([26,27,28,86,89,90], 'apply', 'Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.')
mark([29], 'refute', 'AppEngine implements PaneEngineLanes; openLocalChannel is inherited and all app tests compile.')
mark([30], 'refute', '_beginBinding and _releaseBinding cancel/null the prior watch before the new subscribe; rebind test checks ownership.')
mark([31], 'defer', 'Only SingleActivator/CharacterActivator are registered. Unknown activator policy is speculative API hardening.')
mark([33], 'refute', 'PaneController.navigate returns void; wrapping in unawaited would not compile.')
mark([37,38,54], 'apply', 'STATUS explicitly keeps cancellation12 and unwired models/watch; pane-location20 now qualifies bookmark-sourced raw paths.')
mark([40,41,78,79], 'refute', 'Dart specializes int.clamp(int,int) to int. Existing analyzed controller and runtime cursor tests establish compilation and behavior.')
mark([44], 'decline', 'Null binding means a retired/no-op callback; no user action requires a new reported fault.')
mark([48], 'refute', 'Existing semantics test executes successfully; widget configuration finders do not prove the live exclusion tree. Overlay tests separately inspect exclusion and keyboard behavior.')
mark([69,70,80,87], 'apply', 'Existing cancel/status repairs remain; recovery adds red-first replacement-bind cancellation guard and reruns all status regressions.')
mark([72,73], 'decline', 'D21/02 shortcut table stays primary; never-reserved secondary and Tab remain. No shortcut-policy redesign here.')
mark([74], 'refute', 'Pane-local ExcludeSemantics already excludes stale rows. BlockSemantics risks hiding the sibling pane; keep existing boundary.')
mark([81], 'defer', 'Both sealed subclasses implement equality already. Additional abstract API requirements belong to location composition, item20.')
mark([82], 'refute', 'A backslash can be POSIX filename data. Last-separator detection would corrupt such paths; existing paneSeparator pins the leading-slash rule.')
mark([83], 'defer', 'Loading footer already announces the state. Additional progress semantics is optional presentation work.')
mark([88], 'apply', 'Existing UNC self-parent branches return the original spelling; pane_location tests retain strict no-op cases.')
assert set(triage) == set(range(1,91)), set(range(1,91))-set(triage)
lines = ['## Recovery thread dispositions', '', 'All 90 actual PR84 threads fetched with pagination; no nested comment page remains. Each row below corresponds to one inspected thread. Historical descriptions above remain history; this audit supersedes incorrect pop and numbering declines.', '']
for i,t in enumerate(threads,1):
    disposition,reason=triage[i]
    comment=t['comments']['nodes'][0]
    lines.append(f'- [{i}]({comment["url"]}) **{disposition}**: {reason}')
(p/'thread-dispositions.md').write_text('\n'.join(lines)+'\n')
(p/'thread-dispositions.json').write_text(json.dumps([{'id': t['id'], 'disposition': triage[i][0], 'reason':triage[i][1]} for i,t in enumerate(threads,1)],indent=2))
