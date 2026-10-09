import json, subprocess, sys
from pathlib import Path
out = Path(__file__).parent
label = sys.argv[1]
data = json.loads(subprocess.check_output(['gh', 'pr', 'view', '95', '--repo', 'L-K-M/Poltergeist', '--json', 'url,headRefOid,body,state,mergeable,mergeStateStatus,mergedAt,mergeCommit']))
assert data['url'] == 'https://github.com/L-K-M/Poltergeist/pull/95'
assert data['headRefOid'] == (out / 'expected-head.txt').read_text().strip()
(out / f'pr-{label}.json').write_text(json.dumps(data, indent=2))
(out / f'body-{label}.md').write_text(data['body'])
print(data['url'], data['headRefOid'], data['state'], len(data['body']), data['mergeStateStatus'])
