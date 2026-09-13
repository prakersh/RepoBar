import process from 'node:process';
import type { Command } from 'commander';
import chalk from 'chalk';
import ora from 'ora';

export type GitHubOptions = { token?: string; host?: string; json?: boolean; raw?: boolean };

export function githubOptions(command: Command): GitHubOptions {
  return command.optsWithGlobals<GitHubOptions>();
}

export function repositoryName(slug: string) {
  const [owner, name, ...extra] = slug.split('/');
  if (!owner || !name || extra.length || [owner, name].some((part) => part === '.' || part === '..')) {
    throw new Error('Use owner/repo format.');
  }
  return { owner, name, fullName: slug };
}

export async function withSpinner<T>(message: string, operation: () => Promise<T>): Promise<T> {
  const spinner = ora(message).start();
  try {
    return await operation();
  } finally {
    spinner.stop();
  }
}

export function rateLimitReset(response: Response): number | undefined {
  const header = response.headers.get('x-ratelimit-reset');
  return header ? Number.parseInt(header, 10) : undefined;
}

export function printRateLimit(reset?: number) {
  if (!reset || !Number.isFinite(reset)) return;
  console.error(chalk.dim(`rate limit resets ${new Date(reset * 1000).toLocaleTimeString()}`));
}

export function printJSON(value: unknown) {
  console.log(JSON.stringify(value, null, 2));
}

export function printRaw(body: string) {
  process.stdout.write(body);
  if (!body.endsWith('\n')) process.stdout.write('\n');
}

export function reportError(error: unknown) {
  console.error(chalk.red(error instanceof Error ? error.message : String(error)));
  process.exitCode = 1;
}
