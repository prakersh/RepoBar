#!/usr/bin/env tsx
import process from 'node:process';
import { Command, Option } from 'commander';
import chalk from 'chalk';
import { requireToken, resolveEndpointConfig } from './github-env';
import { githubOptions, printJSON, printRateLimit, rateLimitReset, reportError, repositoryName, withSpinner } from './github-cli';
import type { GitHubOptions } from './github-cli';

type Reply<T> = { json: T; rateLimitReset?: number };
type Repository = { stargazers_count?: number; open_issues_count?: number; default_branch?: string };
type WorkflowRun = { status?: string; conclusion?: string };
type Traffic = { uniques?: number };
type Week = { total?: number };
type Comment = { created_at: string; user?: { login?: string }; body?: string; html_url?: string };
type Release = { draft?: boolean; name?: string; tag_name?: string; published_at?: string; created_at?: string; html_url?: string };

function repositoryClient(slug: string, command: Command) {
  const repo = repositoryName(slug);
  const options = githubOptions(command);
  const config = resolveEndpointConfig({ token: options.token, restHost: options.host });
  const token = requireToken(config.token);
  const base = new URL(config.restEndpoint);
  base.pathname = base.pathname.replace(/\/+$/, '') + '/';
  base.search = '';
  base.hash = '';
  const path = `repos/${encodeURIComponent(repo.owner)}/${encodeURIComponent(repo.name)}`;

  return {
    ...repo,
    options,
    async get<T>(suffix: string): Promise<Reply<T> & { status: number }> {
      const response = await fetch(new URL(path + suffix, base), {
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${token}`,
          'User-Agent': 'RepoBar-CLI',
        },
      });
      const body = await response.text();
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${body || response.statusText}`);
      if (!body && response.status !== 202) throw new Error(`Empty JSON response (status ${response.status})`);
      return {
        json: (body ? JSON.parse(body) : {}) as T,
        rateLimitReset: rateLimitReset(response),
        status: response.status,
      };
    },
  };
}

function present<T>(reply: Reply<T>, options: GitHubOptions, render: (json: T) => void) {
  if (options.json) printJSON(reply.json);
  else render(reply.json);
  printRateLimit(reply.rateLimitReset);
}

const program = new Command()
  .name('ghrest')
  .description('GitHub REST CLI helpers for RepoBar')
  .addOption(new Option('--token <token>', 'GitHub token (defaults to GITHUB_TOKEN)'))
  .addOption(new Option('--host <url>', 'REST API base (default https://api.github.com)'))
  .option('--json', 'Print raw JSON', false)
  .showHelpAfterError();

program.command('repo').argument('<owner/repo>').description('Fetch repository JSON')
  .action(async (slug: string, _options, command: Command) => {
    const client = repositoryClient(slug, command);
    const reply = await withSpinner('Fetching repo', () => client.get<Repository>(''));
    present(reply, client.options, (repo) => console.log([
      chalk.bold(client.fullName),
      `Stars: ${repo.stargazers_count ?? 'n/a'}`,
      `Issues: ${repo.open_issues_count ?? 'n/a'}`,
      `Default branch: ${repo.default_branch ?? 'n/a'}`,
    ].join('\n')));
  });

program.command('ci').argument('<owner/repo>').option('--branch <name>', 'Branch to filter', 'main')
  .description('Show latest Actions run for a branch')
  .action(async (slug: string, options: { branch: string }, command: Command) => {
    const client = repositoryClient(slug, command);
    const query = new URLSearchParams({ per_page: '1', branch: options.branch });
    const reply = await withSpinner('Fetching CI status', () => client.get<{ workflow_runs?: WorkflowRun[] }>(`/actions/runs?${query}`));
    present(reply, client.options, (json) => {
      const run = json.workflow_runs?.[0];
      console.log(run ? [
        chalk.bold(`${client.fullName}@${options.branch}`),
        `Status: ${run.status ?? 'unknown'}`,
        `Conclusion: ${run.conclusion ?? 'n/a'}`,
      ].join('\n') : 'No runs found.');
    });
  });

program.command('traffic').argument('<owner/repo>').description('Fetch traffic views and clones (requires repo admin permission)')
  .action(async (slug: string, _options, command: Command) => {
    const client = repositoryClient(slug, command);
    const [views, clones] = await withSpinner('Fetching traffic', () => Promise.all([
      client.get<Traffic>('/traffic/views'), client.get<Traffic>('/traffic/clones'),
    ]));
    present({ json: { views: views.json, clones: clones.json }, rateLimitReset: views.rateLimitReset ?? clones.rateLimitReset }, client.options, (json) => {
      console.log(chalk.bold(`${client.fullName} traffic (last 14d)`));
      console.log(`Unique visitors: ${json.views.uniques ?? 'n/a'}`);
      console.log(`Unique cloners: ${json.clones.uniques ?? 'n/a'}`);
    });
  });

program.command('heatmap').argument('<owner/repo>').description('Fetch commit_activity for heatmap (weekly buckets)')
  .action(async (slug: string, _options, command: Command) => {
    const client = repositoryClient(slug, command);
    const reply = await withSpinner('Fetching commit activity', () => client.get<Week[]>('/stats/commit_activity'));
    if (reply.status === 202) {
      if (client.options.json) printJSON(reply.json);
      else console.log(chalk.yellow('GitHub is computing stats; retry in ~1 minute.'));
      printRateLimit(reply.rateLimitReset);
      return;
    }
    present(reply, client.options, (weeks) => {
      const total = weeks.reduce((sum, week) => sum + (week.total ?? 0), 0);
      console.log(chalk.bold(client.fullName));
      console.log(`Weeks: ${weeks.length}, total commits: ${total}`);
    });
  });

program.command('activity').argument('<owner/repo>').description('Latest issue or PR comment')
  .action(async (slug: string, _options, command: Command) => {
    const client = repositoryClient(slug, command);
    const [issues, reviews] = await withSpinner('Fetching latest activity', () => Promise.all([
      client.get<Comment[]>('/issues/comments?per_page=1&sort=created&direction=desc'),
      client.get<Comment[]>('/pulls/comments?per_page=1&sort=created&direction=desc'),
    ]));
    const latest = [...issues.json, ...reviews.json].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
    present({ json: latest ?? {}, rateLimitReset: issues.rateLimitReset ?? reviews.rateLimitReset }, client.options, () => {
      if (!latest) { console.log('No comments found.'); return; }
      console.log(chalk.bold(client.fullName));
      console.log(`${latest.user?.login}: ${(latest.body ?? '').slice(0, 80)}…`);
      console.log(chalk.dim(latest.html_url ?? ''));
    });
  });

program.command('release').argument('<owner/repo>').description('Latest non-draft release (includes prereleases)')
  .action(async (slug: string, _options, command: Command) => {
    const client = repositoryClient(slug, command);
    const reply = await withSpinner('Fetching releases', () => client.get<Release[]>('/releases?per_page=10'));
    present(reply, client.options, (releases) => {
      const release = releases.find((item) => item.draft !== true);
      if (!release) { console.log('No releases found.'); return; }
      console.log(chalk.bold(client.fullName));
      console.log(`${release.name ?? release.tag_name} (${release.published_at ?? release.created_at ?? 'n/a'})`);
      console.log(chalk.dim(release.html_url ?? ''));
    });
  });

program.parseAsync(process.argv).catch(reportError);
