import { setTimeout as sleep } from 'timers/promises';
import type { ChildProcessWithoutNullStreams } from 'child_process';
import type { LaunchedServer } from './launcher';

export interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: string | number;
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: string | number;
  result?: unknown;
  error?: unknown;
}

export interface HandshakeOptions {
  request: JsonRpcRequest;
  timeoutMs?: number;
  retries?: number;
  backoffMs?: number;
}

export interface AttachResult {
  process: ChildProcessWithoutNullStreams;
  response: JsonRpcResponse;
  attempt: number;
  logPath: string;
}

export class McpProtocolError extends Error {
  constructor(message: string, readonly attempt: number, readonly cause?: unknown) {
    super(message);
    this.name = 'McpProtocolError';
  }
}

export class McpTimeoutError extends McpProtocolError {
  constructor(message: string, attempt: number) {
    super(message, attempt);
    this.name = 'McpTimeoutError';
  }
}

export class McpInvalidFrameError extends McpProtocolError {
  constructor(message: string, attempt: number, readonly frame?: string) {
    super(message, attempt);
    this.name = 'McpInvalidFrameError';
  }
}

async function readJsonRpcMessage(
  child: ChildProcessWithoutNullStreams,
  timeoutMs: number,
  attempt: number
): Promise<JsonRpcResponse> {
  const abort = new AbortController();
  const timeout = sleep(timeoutMs, undefined, { signal: abort.signal }).then(() => {
    throw new McpTimeoutError('Timed out waiting for MCP handshake response', attempt);
  });

  const framePromise = (async () => {
    const chunks: Buffer[] = [];
    for await (const chunk of child.stdout) {
      chunks.push(Buffer.from(chunk));
      const joined = Buffer.concat(chunks).toString('utf8');
      const newlineIndex = joined.indexOf('\n');
      if (newlineIndex === -1) {
        continue;
      }
      const frame = joined.slice(0, newlineIndex).trim();
      if (!frame) {
        continue;
      }
      try {
        const parsed = JSON.parse(frame) as JsonRpcResponse;
        if (parsed.jsonrpc !== '2.0') {
          throw new McpInvalidFrameError('Invalid jsonrpc version', attempt, frame);
        }
        if (parsed.id === undefined || parsed.id === null) {
          throw new McpInvalidFrameError('Missing id in handshake response', attempt, frame);
        }
        return parsed;
      } catch (error) {
        if (error instanceof McpProtocolError) {
          throw error;
        }
        throw new McpInvalidFrameError(
          `Failed to parse handshake response: ${(error as Error).message}`,
          attempt,
          frame
        );
      }
    }
    throw new McpTimeoutError('Stream ended before handshake completed', attempt);
  })();

  try {
    const response = await Promise.race([framePromise, timeout]);
    abort.abort();
    return response;
  } catch (error) {
    abort.abort();
    throw error;
  }
}

async function performHandshake(
  launched: LaunchedServer,
  options: Required<Pick<HandshakeOptions, 'request' | 'timeoutMs'>>,
  attempt: number
): Promise<JsonRpcResponse> {
  const payload = `${JSON.stringify(options.request)}\n`;
  launched.child.stdin.write(payload);
  const response = await readJsonRpcMessage(launched.child, options.timeoutMs, attempt);
  if (response.id !== options.request.id) {
    throw new McpInvalidFrameError('Handshake response id did not match request', attempt);
  }
  if (response.error) {
    throw new McpProtocolError('Server rejected handshake', attempt, response.error);
  }
  launched.updateStatus('attached');
  return response;
}

export type LaunchFactory = () => Promise<LaunchedServer> | LaunchedServer;

export async function attachWithRetry(
  factory: LaunchFactory,
  options: HandshakeOptions
): Promise<AttachResult> {
  const retries = options.retries ?? 3;
  const timeoutMs = options.timeoutMs ?? 5_000;
  const backoffMs = options.backoffMs ?? 250;

  let attempt = 0;
  let lastError: unknown;

  while (attempt < retries) {
    attempt += 1;
    let launched: LaunchedServer | undefined;
    try {
      launched = await factory();
      launched.updateStatus('starting');
      const response = await performHandshake(
        launched,
        { request: options.request, timeoutMs },
        attempt
      );
      return {
        process: launched.child,
        response,
        attempt,
        logPath: launched.logPath
      };
    } catch (error) {
      lastError = error;
      launched?.updateStatus('failed');
      launched?.dispose();
      if (attempt >= retries) {
        throw new McpProtocolError('Failed to establish MCP handshake', attempt, error);
      }
      await sleep(backoffMs * Math.pow(2, attempt - 1));
    }
  }

  throw new McpProtocolError('Failed to establish MCP handshake', retries, lastError);
}
