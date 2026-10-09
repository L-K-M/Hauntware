import json, subprocess, sys
from pathlib import Path
out = Path(__file__).parent
label = sys.argv[1]
def api(*args):
    return json.loads(subprocess.check_output(['gh', 'api', *args], timeout=90))
query = '''query($cursor:String){repository(owner:"L-K-M",name:"Poltergeist"){pullRequest(number:95){reviewThreads(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{id isResolved isOutdated path line comments(first:100){pageInfo{hasNextPage endCursor}nodes{id databaseId url body createdAt updatedAt author{login}}}}}}}}'''
threads, pages = [], []
cursor = None
while True:
    args = ['graphql', '-f', 'query=' + query]
    if cursor:
        args += ['-f', 'cursor=' + cursor]
    page = api(*args)
    pages.append(page)
    connection = page['data']['repository']['pullRequest']['reviewThreads']
    for thread in connection['nodes']:
        comments = thread['comments']
        while comments['pageInfo']['hasNextPage']:
            q = 'query($id:ID!,$cursor:String){node(id:$id){... on PullRequestReviewThread{comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor}nodes{id databaseId url body createdAt updatedAt author{login}}}}}}'
            extra = api('graphql', '-f', 'query=' + q, '-f', 'id=' + thread['id'], '-f', 'cursor=' + comments['pageInfo']['endCursor'])['data']['node']['comments']
            comments['nodes'].extend(extra['nodes'])
            comments['pageInfo'] = extra['pageInfo']
        threads.append(thread)
    if not connection['pageInfo']['hasNextPage']:
        break
    cursor = connection['pageInfo']['endCursor']
(out / f'threads-pages-{label}.json').write_text(json.dumps(pages, indent=2))
(out / f'threads-{label}.json').write_text(json.dumps(threads, indent=2))
text = []
for thread in threads:
    text.append(f"## THREAD {thread['id']} resolved={thread['isResolved']} outdated={thread['isOutdated']} {thread['path']}:{thread['line']}")
    for comment in thread['comments']['nodes']:
        text.append(f"{comment['url']} {comment['author']} updated={comment['updatedAt']}\n{comment['body']}\n")
for kind, endpoint in [('issues', 'issues/95/comments'), ('reviews', 'pulls/95/reviews'), ('inline', 'pulls/95/comments')]:
    pages = api('--paginate', '--slurp', f'repos/L-K-M/Poltergeist/{endpoint}?per_page=100')
    (out / f'{kind}-{label}.json').write_text(json.dumps(pages, indent=2))
    items = [item for page in pages for item in page]
    if kind != 'inline':
        for item in items:
            text.append(f"## {kind.upper()} {item['id']} {item.get('html_url')} commit={item.get('commit_id')}\n{item.get('body', '')}\n")
    print(kind, len(items), 'items;', len(pages), 'pages')
(out / f'feedback-{label}.md').write_text('\n'.join(text))
print(len(threads), 'threads;', sum(not t['isResolved'] for t in threads), 'unresolved; all pages fetched')
