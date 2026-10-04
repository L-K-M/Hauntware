import json, subprocess, sys
from pathlib import Path
out = Path(__file__).parent
threads = json.loads((out / 'threads-restart.json').read_text())
major = '''Declined for the production path; the healthy-rebind premise does not cover failed bindings.

EngineHost._watch absorbs manager stream errors (engine_host.dart:531-550). EngineClient.watchServer only emits ServerStatus data; request failures complete futures, while isolate errors terminate and close streams (engine_client.dart:173-188,318-321,348-367,418-426). There is no production status addError -> later connected path. Blocked/disconnected clear bindings; reconnect.dart:340-399 removes permanently failed views from the rebind set. Their fs getter retains the failure, so explicit reopen remains necessary.

I did reproduce the synthetic surviving-error case with a still-usable retained channel. Connected reaches the controller, but the pane intentionally remains retryable. A successful direct retained-channel read and delayed explicit replacement prove it is not stranded and still requires accepted listing proof. Post-restart production-core lifetime59, app566, supervisor2 and supplemental probes2 pass; full logs retained in tasks/run3-task15-logs/reconnect/. Automatic recovery from errors in a future status adapter is deferred, not claimed implemented. No blanket failed->listing change is warranted during stabilization.'''
for index, thread in enumerate(threads):
    subprocess.run([sys.executable, str(out / 'snapshot_pr.py'), f'before-reply-{index}'], check=True)
    body = major if thread['path'].endswith('pane_controller.dart') else 'Deferred as a prose-only nit under the inherited >10-round stabilization rule. No optional source push. Runtime reds exposed the assumption; the implementation repaired it. Full disposition is appended to the PR body.'
    payload = out / f'reply-{index}.json'
    payload.write_text(json.dumps({'body': body}))
    comment_id = thread['comments']['nodes'][0]['databaseId']
    result = subprocess.check_output(['gh', 'api', f'repos/L-K-M/Poltergeist/pulls/95/comments/{comment_id}/replies', '-X', 'POST', '--input', str(payload)], timeout=60)
    (out / f'reply-result-{index}.json').write_bytes(result)
    subprocess.run([sys.executable, str(out / 'snapshot_pr.py'), f'before-resolve-{index}'], check=True)
    query = 'mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}'
    result = subprocess.check_output(['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'id=' + thread['id']], timeout=60)
    (out / f'resolve-{index}.json').write_bytes(result)
    assert json.loads(result)['data']['resolveReviewThread']['thread']['isResolved']
    print(thread['id'], 'replied and resolved')
