import { spawn, type ChildProcessWithoutNullStreams } from 'child_process';
import { createWriteStream, type WriteStream } from 'fs';
import { mkdir } from 'fs/promises';
import os from 'os';
import path from 'path';

export type McpServerStatus = 'starting' | 'attached' | 'failed';

export interface LaunchOptions {
  /** Unique identifier for the server, used to name the log file. */
  id: string;
  command: string;
  args?: string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
}

export interface LaunchedServer {
  child: ChildProcessWithoutNullStreams;
  logPath: string;
  status: McpServerStatus;
  updateStatus(status: McpServerStatus): void;
  dispose(): void;
}

const LOG_DIRECTORY = path.join(
  os.homedir(),
  '.local',
  'state',
  'claude-desktop',
  'mcp'
);

const DEBUG_ENABLED = process.env.MCP_DEBUG === '1';

function createLogStream(id: string): { stream: WriteStream; logPath: string } {
  const timestamp = new Date().toISOString();
  const logPath = path.join(LOG_DIRECTORY, `${id}.log`);
  const stream = createWriteStream(logPath, { flags: 'a' });
  stream.write(`\n==== Launch ${timestamp} ====\n`);
  return { stream, logPath };
}

async function ensureLogDirectory(): Promise<void> {
  await mkdir(LOG_DIRECTORY, { recursive: true });
}

export async function launchServer(options: LaunchOptions): Promise<LaunchedServer> {
  await ensureLogDirectory();
  const { stream, logPath } = createLogStream(options.id);

  if (DEBUG_ENABLED) {
    stream.write(
      `[debug] command: ${options.command} ${options.args?.join(' ') ?? ''}\n`
    );
    stream.write(`[debug] cwd: ${options.cwd ?? process.cwd()}\n`);
    if (options.env) {
      stream.write(`[debug] env: ${JSON.stringify(options.env)}\n`);
    }
    console.info(
      `[MCP] launching ${options.id}:`,
      JSON.stringify(
        {
          command: options.command,
          args: options.args ?? [],
          cwd: options.cwd ?? process.cwd(),
          env: options.env ?? {}
        },
        null,
        2
      )
    );
  }

  const child = spawn(options.command, options.args ?? [], {
    cwd: options.cwd,
    env: { ...process.env, ...options.env },
    stdio: ['pipe', 'pipe', 'pipe']
  });

  let status: McpServerStatus = 'starting';

  const forward = (source: NodeJS.ReadableStream, channel: 'stdout' | 'stderr') => {
    source.on('data', (chunk) => {
      stream.write(`[${channel}] ${chunk}`);
    });
  };

  forward(child.stdout, 'stdout');
  forward(child.stderr, 'stderr');

  child.once('exit', (code, signal) => {
    stream.write(`\n[exit] code=${code ?? 'null'} signal=${signal ?? 'null'}\n`);
    stream.end();
    if (DEBUG_ENABLED) {
      console.info(
        `[MCP] server ${options.id} exited`,
        JSON.stringify({ code, signal })
      );
    }
  });

  child.once('error', (error) => {
    stream.write(`\n[error] ${error instanceof Error ? error.stack ?? error.message : error}\n`);
  });

  const launched: LaunchedServer = {
    child,
    logPath,
    status,
    updateStatus(next) {
      status = next;
      if (DEBUG_ENABLED) {
        stream.write(`[status] ${next}\n`);
        console.info(`[MCP] ${options.id} -> ${next}`);
      } else {
        stream.write(`[status] ${next}\n`);
      }
    },
    dispose() {
      if (!child.killed) {
        child.kill();
      }
    }
  };

  return launched;
}
