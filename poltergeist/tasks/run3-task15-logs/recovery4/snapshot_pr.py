import json, subprocess, sys
from pathlib import Path
p=Path(__file__).parent
label=sys.argv[1]
data=json.loads(subprocess.check_output(['gh','pr','view','84','--repo','L-K-M/Poltergeist','--json','url,headRefOid,body,state,mergeable,mergeStateStatus']))
assert data['url']=='https://github.com/L-K-M/Poltergeist/pull/84'
assert data['headRefOid']=='03f58198089c1020b54be3347df78d369ed14d95'
assert data['state']=='OPEN'
(p/f'pr-{label}.json').write_text(json.dumps(data,indent=2))
(p/f'body-{label}.md').write_text(data['body'])
print(data['url'],data['headRefOid'],len(data['body']),data['mergeStateStatus'])
