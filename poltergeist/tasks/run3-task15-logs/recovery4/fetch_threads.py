import json, subprocess
from pathlib import Path
out = Path(__file__).parent
query = '''query($cursor:String){repository(owner:"L-K-M",name:"Poltergeist"){pullRequest(number:84){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{id isResolved isOutdated path line comments(first:100){pageInfo{hasNextPage endCursor}nodes{id databaseId url body createdAt updatedAt author{login}}}}}}}}'''
threads=[]
cursor=None
pages=[]
while True:
    args=['gh','api','graphql','-f','query='+query]
    if cursor: args += ['-f','cursor='+cursor]
    page=json.loads(subprocess.check_output(args))
    pages.append(page)
    connection=page['data']['repository']['pullRequest']['reviewThreads']
    for thread in connection['nodes']:
        comments=thread['comments']
        while comments['pageInfo']['hasNextPage']:
            q='query($id:ID!,$cursor:String){node(id:$id){... on PullRequestReviewThread{comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{id databaseId url body createdAt updatedAt author{login}}}}}}'
            extra=json.loads(subprocess.check_output(['gh','api','graphql','-f','query='+q,'-f','id='+thread['id'],'-f','cursor='+comments['pageInfo']['endCursor']]))['data']['node']['comments']
            comments['nodes'].extend(extra['nodes'])
            comments['pageInfo']=extra['pageInfo']
        threads.append(thread)
    if not connection['pageInfo']['hasNextPage']: break
    cursor=connection['pageInfo']['endCursor']
(out/'threads-pages.json').write_text(json.dumps(pages,indent=2))
(out/'threads.json').write_text(json.dumps(threads,indent=2))
old=json.loads((out.parent/'recovery3/threads.json').read_text())['data']['repository']['pullRequest']['reviewThreads']['nodes']
old_comments={c['id']:c['body'] for t in old for c in t['comments']['nodes']}
lines=[]
for t in threads:
    for c in t['comments']['nodes']:
        if old_comments.get(c['id']) == c['body']: continue
        lines.append(f"## {t['id']} resolved={t['isResolved']} {t['path']}:{t['line']}\n{c['url']} {c['author']}\n{c['body']}\n")
(out/'new-feedback.md').write_text('\n'.join(lines))
print(f'{len(threads)} threads, {sum(not t["isResolved"] for t in threads)} unresolved, {len(lines)} new/edited comments; all pages fetched')
