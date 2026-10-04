

## Corrective audit: status-watch termination

Opening counts above belong to `c753712`. A further runtime audit proved EOF/error still dismissed unhealed loss through `_endRecoveryWatch`. Three runtime failures in `watch-red.log` establish this as a correctness repair, not stabilization cleanup.

`994a2c0` keeps a retryable loss after watch failure/EOF while clearing stale status. Existing tests were corrected from “clear banner” to “clear status, retain loss, offer Retry”; a new delayed-listing test proves a dead watch cannot accept its old answer, while a valid explicit replacement does heal. No indefinite reconnect label.

Final local proof: unchanged supervisor file2 tests, focused90, full app566, analysis clean, capture harness pass. Fourteen recovery controller cases. Original c753712 logs retained in `c753712/`. The first review revision was superseded during execution by this demonstrated defect repair; it is not a completed review round or approval. Latest-head gates and complete feedback remain required.
