#!/usr/bin/env python3
import json
import os
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'data' / 'dns_database.json'
TOKEN = os.environ.get('GITHUB_TOKEN', '')
UA = 'GamingDNS-Database-Updater/1.0'

IP_RE = re.compile(r'(?<!\d)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d)')
GAMING_WORDS = (
    'gaming', 'game', 'call of duty', 'cod mobile', 'pubg',
    'pubg mobile', 'mobile legends', 'mlbb', 'radar', 'shelter',
    'electro', 'luna-dns', 'luna dns'
)

PUBLIC_SOURCES = [
    ('GitHub public-dns-directory / all.txt',
     'https://raw.githubusercontent.com/trybyteful/public-dns-directory/main/resolvers/global/all.txt'),
    ('GitHub public-dns-directory / trusted.txt',
     'https://raw.githubusercontent.com/trybyteful/public-dns-directory/main/resolvers/global/trusted.txt'),
    ('public-dns.info', 'https://public-dns.info/nameservers.txt'),
    ('Luna-Dns', 'https://raw.githubusercontent.com/AsTheySayMehrab/Luna-Dns/main/README.md'),
]

GITHUB_QUERIES = [
    'gaming dns',
    'cod mobile dns',
    'pubg mobile dns',
    'mobile legends dns',
    'public dns resolver',
]


def request(url, headers=None, timeout=30):
    h = {'User-Agent': UA, 'Accept': '*/*'}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def text(url):
    try:
        status, body = request(url)
        if status != 200:
            return ''
        return body.decode('utf-8', errors='replace')
    except Exception as exc:
        print(f'[WARN] {url}: {exc}')
        return ''


def valid_ip(ip):
    try:
        parts = [int(x) for x in ip.split('.')]
        if len(parts) != 4 or any(x < 0 or x > 255 for x in parts):
            return False
        a, b, _, _ = parts
        if a in (0, 10, 127) or (a == 169 and b == 254):
            return False
        if a == 172 and 16 <= b <= 31:
            return False
        if a == 192 and b == 168:
            return False
        return True
    except Exception:
        return False


def ips_from(value):
    return {m.group(0) for m in IP_RE.finditer(value) if valid_ip(m.group(0))}


def is_gaming(value):
    low = value.lower()
    return any(word in low for word in GAMING_WORDS)


def add(items, ip, source, category, gaming):
    old = items.get(ip)
    if old is None:
        items[ip] = {
            'ip': ip,
            'source': source,
            'category': category,
            'gamingTagged': bool(gaming),
        }
        return
    # Prefer a gaming label/source if the same resolver appeared in multiple sources.
    if gaming and not old.get('gamingTagged'):
        old['gamingTagged'] = True
        old['category'] = 'Gaming / GitHub'
    if old.get('source') == 'Unknown source':
        old['source'] = source


def add_text(items, body, source, gaming_hint=False):
    gaming = gaming_hint or is_gaming(body) or is_gaming(source)
    category = 'Gaming / GitHub' if gaming else 'Public DNS'
    for ip in ips_from(body):
        add(items, ip, source, category, gaming)


def github_headers():
    h = {'Accept': 'application/vnd.github+json'}
    if TOKEN:
        h['Authorization'] = f'Bearer {TOKEN}'
    return h


def github_json(url):
    try:
        status, body = request(url, headers=github_headers(), timeout=30)
        if status != 200:
            print(f'[WARN] GitHub {status}: {url}')
            return None
        return json.loads(body.decode('utf-8', errors='replace'))
    except Exception as exc:
        print(f'[WARN] GitHub API: {exc}')
        return None


def collect_repository(items, repo):
    full = repo.get('full_name')
    branch = repo.get('default_branch') or 'main'
    if not full:
        return 0

    source_prefix = f'GitHub: {full}'
    count_before = len(items)
    api_root = f'https://api.github.com/repos/{full}'
    info = github_json(api_root)
    if info:
        branch = info.get('default_branch') or branch

    # README is the highest-value small document and often contains DNS lists.
    readme_url = f'https://raw.githubusercontent.com/{full}/{urllib.parse.quote(branch, safe="")}/README.md'
    body = text(readme_url)
    if body:
        add_text(items, body, source_prefix, is_gaming(body) or is_gaming(full))

    # Also inspect the repository tree and fetch only small DNS-looking files.
    tree_url = f'https://api.github.com/repos/{full}/git/trees/{urllib.parse.quote(branch, safe="")}?recursive=1'
    tree = github_json(tree_url)
    if not isinstance(tree, dict):
        return len(items) - count_before

    candidates = []
    for entry in tree.get('tree', []):
        if entry.get('type') != 'blob':
            continue
        path = entry.get('path', '')
        low = path.lower()
        if not low.endswith(('.txt', '.md', '.json', '.csv', '.yaml', '.yml', '.conf')):
            continue
        if any(k in low for k in ('dns', 'resolver', 'nameserver', 'nameservers')):
            size = int(entry.get('size') or 0)
            if size <= 1_000_000:
                candidates.append((path, size))

    for path, _ in candidates[:12]:
        raw = 'https://raw.githubusercontent.com/{}/{}/{}'.format(
            full, urllib.parse.quote(branch, safe=''), '/'.join(urllib.parse.quote(p, safe='') for p in path.split('/'))
        )
        body = text(raw)
        if body:
            add_text(items, body, source_prefix, is_gaming(body) or is_gaming(path) or is_gaming(full))

    return len(items) - count_before


def search_github(items):
    repos = {}
    for query in GITHUB_QUERIES:
        params = urllib.parse.urlencode({
            'q': query,
            'sort': 'updated',
            'order': 'desc',
            'per_page': '10',
        })
        data = github_json(f'https://api.github.com/search/repositories?{params}')
        if not isinstance(data, dict):
            continue
        for repo in data.get('items', []):
            if isinstance(repo, dict) and repo.get('full_name'):
                repos[repo['full_name']] = repo

    print(f'[INFO] GitHub repositories selected: {len(repos)}')
    total_added = 0
    for repo in repos.values():
        total_added += collect_repository(items, repo)
    return len(repos), total_added


def main():
    items = {}

    # Known high-quality public resolver directories.
    for source, url in PUBLIC_SOURCES:
        body = text(url)
        if body:
            add_text(items, body, source, is_gaming(source))
            print(f'[OK] {source}: {len(ips_from(body))} IPs')

    repo_count, repo_added = search_github(items)

    # Stable public resolvers are useful as a small baseline even if an external source is down.
    for ip in ('1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9', '149.112.112.112'):
        add(items, ip, 'Built-in public baseline', 'Public DNS', False)

    # Deterministic ordering: gaming first, then IP.
    rows = list(items.values())
    rows.sort(key=lambda x: (not x['gamingTagged'], tuple(int(p) for p in x['ip'].split('.'))))

    payload = {
        'schema': 2,
        'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'source_count': len(PUBLIC_SOURCES),
        'github_repository_count': repo_count,
        'count': len(rows),
        'items': rows,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'[DONE] {len(rows)} unique DNS resolvers written to {OUT}')
    print(f'[DONE] DNS candidates added from GitHub repositories: {repo_added}')


if __name__ == '__main__':
    main()
