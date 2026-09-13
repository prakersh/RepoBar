#!/usr/bin/env tsx
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { Command, Option } from 'commander';
import chalk from 'chalk';
import { z } from 'zod';
import { requireToken, resolveEndpointConfig } from './github-env';
import { githubOptions, printJSON, printRateLimit, printRaw, rateLimitReset, reportError, repositoryName, withSpinner } from './github-cli';

type GraphQLBody = { query: string; variables?: Record<string, unknown> };
type GraphQLResponse<T> = { data?: T; errors?: { message: string }[] };
type Release = { name?: string; tagName: string; publishedAt?: string; createdAt?: string; isLatest: boolean; isDraft: boolean; isPrerelease: boolean };
type RepoData = { repository: { issues: { totalCount: number }; pullRequests: { totalCount: number }; latestRelease?: Release | null } | null };
type ContributionDay = { date: string; contributionCount: number };
type ContributionData = { user: { contributionsCollection: { contributionCalendar: { weeks: { contributionDays: ContributionDay[] }[] } } } | null };

async function execute<T>(body: GraphQLBody, command: Command, message: string): Promise<T | undefined> {
  const options = githubOptions(command);
  const config = resolveEndpointConfig({ token: options.token, graphqlHost: options.host });
  const token = requireToken(config.token);
  const { response, raw } = await withSpinner(message, async () => {
    const response = await fetch(config.graphqlEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'User-Agent': 'RepoBar-CLI' },
      body: JSON.stringify(body),
    });
    return { response, raw: await response.text() };
  });
  if (options.raw) printRaw(raw);
  printRateLimit(rateLimitReset(response));

  let json: GraphQLResponse<T>;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new Error(`Invalid JSON response (status ${response.status})`);
  }
  if (!json || typeof json !== 'object') throw new Error('Invalid GraphQL response');
  if (!response.ok || json.errors?.length) {
    const message = json.errors?.map((error) => error.message).join('; ') || response.statusText;
    throw new Error(`${message} (status ${response.status})`);
  }
  if (options.raw) return;
  if (json.data == null) throw new Error('Empty GraphQL data');
  return json.data;
}

const contribQuery = `
query UserContributions($login: String!) {
  user(login: $login) {
    contributionsCollection {
      contributionCalendar {
        weeks {
          contributionDays { date contributionCount }
        }
      }
    }
  }
}`;

const program = new Command()
  .name('ghql')
  .description('Lightweight GitHub GraphQL runner for RepoBar debugging')
  .addOption(new Option('--token <token>', 'GitHub token (falls back to GITHUB_TOKEN)'))
  .addOption(new Option('--host <url>', 'GraphQL endpoint (default https://api.github.com/graphql)'))
  .option('--json', 'Print raw JSON', false)
  .option('--raw', 'Print the raw server response body', false)
  .showHelpAfterError();

program.command('repo').argument('<owner/repo>').description('Fetch repo snapshot (issues, PRs, latest stable release)')
  .action(async (slug: string, _options, command: Command) => {
    const { owner, name } = repositoryName(slug);
    const query = await fs.readFile(path.join(__dirname, '..', 'GraphQL', 'RepoSnapshot.graphql'), 'utf8');
    const data = await execute<RepoData>({ query, variables: { owner, name } }, command, 'Fetching repo snapshot');
    if (data === undefined) return;
    if (githubOptions(command).json) { printJSON(data); return; }
    const repo = data.repository;
    if (!repo) throw new Error('Repository not found');
    const release = repo.latestRelease?.isLatest && !repo.latestRelease.isDraft && !repo.latestRelease.isPrerelease ? repo.latestRelease : undefined;
    const releaseLine = release
      ? `${release.name ?? release.tagName} (${new Date(release.publishedAt ?? release.createdAt ?? 0).toLocaleDateString()})`
      : 'none';
    console.log([
      chalk.bold(`${owner}/${name}`),
      `Issues: ${repo.issues.totalCount}`,
      `PRs: ${repo.pullRequests.totalCount}`,
      `Latest stable release: ${releaseLine}`,
    ].join('\n'));
  });

program.command('contrib').argument('<login>').description('Fetch contribution calendar and flatten to day counts')
  .action(async (login: string, _options, command: Command) => {
    const data = await execute<ContributionData>({ query: contribQuery, variables: { login } }, command, 'Fetching contribution calendar');
    if (data === undefined) return;
    const days = data.user?.contributionsCollection.contributionCalendar.weeks.flatMap((week) => week.contributionDays) ?? [];
    if (githubOptions(command).json) printJSON(days);
    else {
      console.log(chalk.bold(login));
      console.log(`Total contributions: ${days.reduce((sum, day) => sum + day.contributionCount, 0)}`);
      console.log(`Days: ${days.length}`);
    }
  });

program.command('run').argument('<file>', 'Path to .graphql file').option('--vars <json>', 'Variables JSON string', '{}')
  .description('Run an arbitrary GraphQL query')
  .action(async (file: string, options: { vars: string }, command: Command) => {
    const query = await fs.readFile(path.resolve(file), 'utf8');
    const variables = z.record(z.string(), z.unknown()).parse(JSON.parse(options.vars));
    const data = await execute<Record<string, unknown>>({ query, variables }, command, 'Running query');
    if (data !== undefined) printJSON(data);
  });

program.parseAsync(process.argv).catch(reportError);
