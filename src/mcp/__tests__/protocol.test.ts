import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PassThrough } from 'stream';
import { EventEmitter } from 'events';
import type { ChildProcessWithoutNullStreams } from 'child_process';
import { attachWithRetry, McpProtocolError, McpTimeoutError } from '../../mcp/protocol';
import type { LaunchedServer, McpServerStatus } from '../../mcp/launcher';

interface MockServer extends LaunchedServer {
  statuses: McpServerStatus[];
  disposed: boolean;
  child: ChildProcessWithoutNullStreams & {
    stdin: PassThrough;
    stdout: PassThrough;
    stderr: PassThrough;
    kill: ReturnType<typeof vi.fn>;
  };
}

function createChildProcess(): MockServer['child'] {
  const child = new EventEmitter() as ChildProcessWithoutNullStreams & {
    stdin: PassThrough;
    stdout: PassThrough;
    stderr: PassThrough;
    kill: ReturnType<typeof vi.fn>;
  };

  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const stderr = new PassThrough();

  const kill = vi.fn(() => {
    child.killed = true;
    child.emit('exit', null, null);
    return true;
  });

  Object.assign(child, {
    stdin,
    stdout,
    stderr,
    stdio: [stdin, stdout, stderr],
    killed: false,
    pid: 123,
    spawnargs: ['mock'],
    spawnfile: 'mock',
    exitCode: null,
    signalCode: null,
    connected: true,
    kill,
    send: vi.fn(() => true),
    disconnect: vi.fn(),
    unref: vi.fn(),
    ref: vi.fn()
  });

  return child;
}

function createLaunchedServer(
  responder: (server: MockServer) => void = () => {}
): MockServer {
  const child = createChildProcess();
  const server: MockServer = {
    child,
    logPath: '/tmp/mock.log',
    status: 'starting',
    statuses: [],
    disposed: false,
    updateStatus(status) {
      server.status = status;
      server.statuses.push(status);
    },
    dispose() {
      server.disposed = true;
      child.kill();
    }
  };

  responder(server);
  return server;
}

describe('attachWithRetry', () => {
  beforeEach(() => {
    vi.useRealTimers();
  });

  it('attaches successfully on the first attempt', async () => {
    const server = createLaunchedServer((mock) => {
      mock.child.stdin.on('data', () => {
        queueMicrotask(() => {
          mock.child.stdout.write(
            `${JSON.stringify({ jsonrpc: '2.0', id: 'handshake', result: { ok: true } })}\n`
          );
          mock.child.stdout.end();
        });
      });
    });

    const factory = vi.fn().mockResolvedValue(server);

    const result = await attachWithRetry(factory, {
      request: { jsonrpc: '2.0', id: 'handshake', method: 'initialize' },
      timeoutMs: 100,
      retries: 1
    });

    expect(result.response.result).toEqual({ ok: true });
    expect(server.statuses).toEqual(['starting', 'attached']);
    expect(server.disposed).toBe(false);
    expect(factory).toHaveBeenCalledTimes(1);
  });

  it('retries when the first response is invalid JSON', async () => {
    const first = createLaunchedServer((mock) => {
      mock.child.stdin.on('data', () => {
        queueMicrotask(() => {
          mock.child.stdout.write('not-json\n');
          mock.child.stdout.end();
        });
      });
    });

    const second = createLaunchedServer((mock) => {
      mock.child.stdin.on('data', () => {
        queueMicrotask(() => {
          mock.child.stdout.write(
            `${JSON.stringify({ jsonrpc: '2.0', id: 'handshake', result: { ok: true } })}\n`
          );
          mock.child.stdout.end();
        });
      });
    });

    const factory = vi
      .fn<[], Promise<MockServer>>()
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second);

    const result = await attachWithRetry(factory, {
      request: { jsonrpc: '2.0', id: 'handshake', method: 'initialize' },
      timeoutMs: 100,
      retries: 2,
      backoffMs: 1
    });

    expect(result.response.result).toEqual({ ok: true });
    expect(first.statuses).toContain('failed');
    expect(first.disposed).toBe(true);
    expect(second.statuses).toEqual(['starting', 'attached']);
    expect(factory).toHaveBeenCalledTimes(2);
  });

  it('propagates timeout errors with cause details after exhausting retries', async () => {
    const server = createLaunchedServer();
    const factory = vi.fn().mockResolvedValue(server);

    const error = await attachWithRetry(factory, {
      request: { jsonrpc: '2.0', id: 'handshake', method: 'initialize' },
      timeoutMs: 10,
      retries: 1
    }).catch((err) => err as McpProtocolError);

    expect(error).toBeInstanceOf(McpProtocolError);
    expect(error.cause).toBeInstanceOf(McpTimeoutError);
    expect(server.statuses).toContain('failed');
    expect(server.disposed).toBe(true);
    expect(factory).toHaveBeenCalledTimes(1);
  });
});
