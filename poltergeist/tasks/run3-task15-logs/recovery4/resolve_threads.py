import json, subprocess, sys
from pathlib import Path
p=Path(__file__).parent
reasons={
 'PRRT_kwDOUIzfcM6h6kpO':('refute','Pinned SDK entry-presence implementation and runtime animated/veto/local-history/covering-route evidence; retain isActive guard.'),
 'PRRT_kwDOUIzfcM6h6kpd':('defer','Duplicate-open assert is optional fake maintenance during stabilization.'),
 'PRRT_kwDOUIzfcM6h6kp1':('defer','Grammar nit deferred during stabilization; stable item identities retained.'),
 'PRRT_kwDOUIzfcM6h6zu0':('defer','Extra held-path fake coverage is optional; sibling refresh regression already asserts exact paths and isolation.'),
 'PRRT_kwDOUIzfcM6h6zvz':('defer','Future enablement-source comment is optional; current pane/workspace/session sources verified.'),
}
threads=json.loads((p/'threads.json').read_text())
assert {t['id'] for t in threads if not t['isResolved']} == set(reasons)
records=[]
for i,(thread_id,(disposition,reason)) in enumerate(reasons.items(),1):
    subprocess.run([sys.executable,str(p/'snapshot_pr.py'),f'preresolve-{i}'],check=True)
    query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}'
    result=json.loads(subprocess.check_output(['gh','api','graphql','-f','query='+query,'-f','id='+thread_id]))
    (p/f'resolve-{i}.json').write_text(json.dumps(result,indent=2))
    assert result['data']['resolveReviewThread']['thread']=={'id':thread_id,'isResolved':True}
    records.append({'id':thread_id,'disposition':disposition,'reason':reason,'isResolved':True})
(p/'new-thread-dispositions.json').write_text(json.dumps(records,indent=2))
