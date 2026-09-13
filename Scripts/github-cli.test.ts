import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import path from 'node:path';
import { test, type TestContext } from 'node:test';

type Request = { method: string; url: string; authorization?: string; body: string };
type Reply = { status?: number; json?: unknown; body?: string };

async function fixture(t: TestContext, reply: (request: Request) => Reply) {
  const requests: Request[] = [];
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const recorded = {
      method: request.method ?? '', url: request.url ?? '',
      authorization: request.headers.authorization, body: Buffer.concat(chunks).toString(),
    };
    requests.push(recorded);
    const result = reply(recorded);
    response.writeHead(result.status ?? 200, { 'Content-Type': 'application/json', 'X-RateLimit-Reset': '2000000000' });
    response.end(result.body ?? JSON.stringify(result.json));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return { base: `http://127.0.0.1:${address.port}`, requests };
}

function run(script: string, args: string[], base: string, overrides: Record<string, string> = {}) {
  return new Promise<{ code: number; stdout: string; stderr: string }>((resolve, reject) => {
    execFile(process.execPath, ['--import', 'tsx', path.join(__dirname, script), ...args], {
      cwd: path.join(__dirname, '..'), timeout: 15000, maxBuffer: 1024 * 1024,
      env: {
        ...process.env, NO_COLOR: '1', GITHUB_TOKEN: 'fixture-fallback', GH_TOKEN: '', GITHUB_PAT: '',
        GITHUB_API: `${base}/api/v3`, GITHUB_GRAPHQL: `${base}/fallback/graphql`, ...overrides,
      },
    }, (error, stdout, stderr) => {
      if (error && typeof error.code !== 'number') { reject(error); return; }
      resolve({ code: error ? Number(error.code) : 0, stdout, stderr });
    });
  });
}

const repo = { stargazers_count: 5, open_issues_count: 3, default_branch: 'main' };
const graph = { data: { repository: { issues: { totalCount: 3 }, pullRequests: { totalCount: 2 }, latestRelease: null } }, extensions: { fixture: true } };

for (const placement of ['before', 'after']) {
  test(`REST honors global flags ${placement} the command and keeps JSON clean`, async (t) => {
    const f = await fixture(t, () => ({ json: repo }));
    const flags = ['--host', `${f.base}/enterprise/api/v3/`, '--token', 'fixture-override', '--json'];
    const args = placement === 'before' ? [...flags, 'repo', 'acme/widget'] : ['repo', 'acme/widget', ...flags];
    const result = await run('ghrest.ts', args, f.base);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), repo);
    assert.match(result.stderr, /rate limit resets/);
    assert.equal(f.requests[0].url, '/enterprise/api/v3/repos/acme/widget');
    assert.equal(f.requests[0].authorization, 'Bearer fixture-override');
  });

  test(`GraphQL honors global flags ${placement} the command`, async (t) => {
    const f = await fixture(t, () => ({ json: graph }));
    const flags = ['--host', `${f.base}/custom/graphql`, '--token', 'fixture-override', '--json'];
    const args = placement === 'before' ? [...flags, 'repo', 'acme/widget'] : ['repo', 'acme/widget', ...flags];
    const result = await run('ghql.ts', args, f.base);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), graph.data);
    assert.equal(f.requests[0].url, '/custom/graphql');
    assert.equal(f.requests[0].authorization, 'Bearer fixture-override');
    assert.deepEqual(JSON.parse(f.requests[0].body).variables, { owner: 'acme', name: 'widget' });
  });
}

test('CI preserves the branch query and raw workflow response', async (t) => {
  const workflows = { workflow_runs: [{ status: 'completed', conclusion: 'success' }] };
  const f = await fixture(t, () => ({ json: workflows }));
  const result = await run('ghrest.ts', ['ci', 'acme/widget', '--branch', 'feature/one & two', '--json'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), workflows);
  const url = new URL(f.requests[0].url, f.base);
  assert.equal(url.pathname, '/api/v3/repos/acme/widget/actions/runs');
  assert.equal(url.searchParams.get('branch'), 'feature/one & two');
  assert.equal(url.searchParams.get('per_page'), '1');
});

test('traffic combines both responses without diagnostics in JSON', async (t) => {
  const f = await fixture(t, (request) => ({ json: { uniques: request.url.endsWith('/views') ? 2 : 5 } }));
  const result = await run('ghrest.ts', ['traffic', 'acme/widget', '--json'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { views: { uniques: 2 }, clones: { uniques: 5 } });
  assert.equal(f.requests.length, 2);
});

test('pending heatmap with an empty response remains valid JSON', async (t) => {
  const f = await fixture(t, () => ({ status: 202, body: '' }));
  const result = await run('ghrest.ts', ['heatmap', 'acme/widget', '--json'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {});
  const text = await run('ghrest.ts', ['heatmap', 'acme/widget'], f.base);
  assert.equal(text.code, 0, text.stderr);
  assert.match(text.stdout, /GitHub is computing stats/);
});

test('activity selects the newest issue or review comment', async (t) => {
  const old = { created_at: '2026-01-01T00:00:00Z', body: 'old', user: { login: 'fixture' } };
  const latest = { ...old, created_at: '2026-02-01T00:00:00Z', body: 'new' };
  const f = await fixture(t, (request) => ({ json: [request.url.includes('/pulls/') ? latest : old] }));
  const result = await run('ghrest.ts', ['activity', 'acme/widget', '--json'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), latest);
});

test('missing release repository reports HTTP 404 instead of an array error', async (t) => {
  const f = await fixture(t, () => ({ status: 404, json: { message: 'Not Found' } }));
  const result = await run('ghrest.ts', ['release', 'acme/widget', '--json'], f.base);
  assert.equal(result.code, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /HTTP 404/);
  assert.doesNotMatch(result.stderr, /filter is not a function/);
});

test('empty release list keeps the existing text result', async (t) => {
  const f = await fixture(t, () => ({ json: [] }));
  const result = await run('ghrest.ts', ['release', 'acme/widget'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, 'No releases found.\n');
});

test('every REST command rejects a malformed repository before requesting', async (t) => {
  const f = await fixture(t, () => ({ json: {} }));
  for (const command of ['repo', 'ci', 'traffic', 'heatmap', 'activity', 'release']) {
    const result = await run('ghrest.ts', [command, 'acme/widget/extra'], f.base);
    assert.equal(result.code, 1, command);
    assert.match(result.stderr, /Use owner\/repo format/);
  }
  assert.equal(f.requests.length, 0);
});

test('contribution JSON remains a flattened day array', async (t) => {
  const days = [{ date: '2026-01-01', contributionCount: 2 }, { date: '2026-01-02', contributionCount: 3 }];
  const f = await fixture(t, () => ({ json: { data: { user: { contributionsCollection: { contributionCalendar: { weeks: [{ contributionDays: days }] } } } } } }));
  const result = await run('ghql.ts', ['contrib', 'fixture', '--json'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), days);
  assert.match(result.stderr, /rate limit resets/);
});

test('run keeps JSON stdout and sends validated variables', async (t) => {
  const f = await fixture(t, () => ({ json: { data: { viewer: { login: 'fixture' } } } }));
  const result = await run('ghql.ts', ['run', 'GraphQL/RepoSnapshot.graphql', '--vars', '{"owner":"acme","name":"widget"}'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { viewer: { login: 'fixture' } });
  assert.deepEqual(JSON.parse(f.requests[0].body).variables, { owner: 'acme', name: 'widget' });
});

test('raw takes precedence over JSON and preserves the complete server body', async (t) => {
  const body = JSON.stringify(graph) + '\n';
  const f = await fixture(t, () => ({ body }));
  const result = await run('ghql.ts', ['repo', 'acme/widget', '--json', '--raw'], f.base);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, body);
});

test('raw retains GraphQL error bodies while returning failure', async (t) => {
  const body = '{"errors":[{"message":"fixture denied"}],"extensions":{"fixture":true}}';
  const f = await fixture(t, () => ({ body }));
  const result = await run('ghql.ts', ['repo', 'acme/widget', '--raw'], f.base);
  assert.equal(result.code, 1);
  assert.equal(result.stdout, body + '\n');
  assert.match(result.stderr, /fixture denied/);
});

test('raw retains a malformed server body for debugging', async (t) => {
  const f = await fixture(t, () => ({ status: 503, body: 'fixture unavailable' }));
  const result = await run('ghql.ts', ['repo', 'acme/widget', '--raw'], f.base);
  assert.equal(result.code, 1);
  assert.equal(result.stdout, 'fixture unavailable\n');
  assert.match(result.stderr, /Invalid JSON response \(status 503\)/);
});

test('invalid variables and missing credentials fail before a request', async (t) => {
  const f = await fixture(t, () => ({ json: {} }));
  const invalid = await run('ghql.ts', ['run', 'GraphQL/RepoSnapshot.graphql', '--vars', '[]'], f.base);
  assert.equal(invalid.code, 1);
  const missing = await run('ghrest.ts', ['repo', 'acme/widget'], f.base, { GITHUB_TOKEN: '' });
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /GitHub token is required/);
  assert.equal(f.requests.length, 0);
});
