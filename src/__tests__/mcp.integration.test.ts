import { describe, expect, it, beforeEach } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { promises as fsp } from 'fs';
import { McpController } from '../main/electron';
import { McpProtocolError } from '../mcp/protocol';

const handshakeRequest = {
  jsonrpc: '2.0' as const,
  id: 'handshake',
  method: 'initialize',
  params: { client: 'test' }
};

function serverCommand(script: string): { command: string; args: string[] } {
  return {
    command: process.execPath,
    args: ['-e', script]
  };
}

describe('MCP runtime integration', () => {
  const tmpRoot = path.join(os.tmpdir(), 'mcp-tests');

  beforeEach(async () => {
    await fsp.mkdir(tmpRoot, { recursive: true });
  });

  it('attaches successfully to a well-behaved server', async () => {
    const controller = new McpController();
    const id = `success-${Date.now()}`;
    const script = `
      const readline = require('node:readline');
      const rl = readline.createInterface({ input: process.stdin });
      rl.on('line', (line) => {
        if (!line) return;
        const msg = JSON.parse(line);
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { ready: true } }) + '\\n');
        setTimeout(() => process.exit(0), 50);
      });
    `;
    const events: string[] = [];
    controller.on('status', (event) => {
      if (event.id === id) {
        events.push(event.status);
      }
    });

    const result = await controller.startServer({
      id,
      ...serverCommand(script),
      handshake: { request: handshakeRequest, timeoutMs: 500, retries: 1 }
    });

    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(events).toEqual(['starting', 'attached']);
    expect(result.logPath).toContain(`${id}.log`);
    expect(fs.existsSync(result.logPath)).toBe(true);
    const logContent = fs.readFileSync(result.logPath, 'utf8');
    expect(logContent).toContain('[status] attached');
  });

  it('emits failure when the handshake times out', async () => {
    const controller = new McpController();
    const id = `timeout-${Date.now()}`;
    const script = `
      setTimeout(() => {}, 2000);
    `;
    const events: { status: string; attempt: number }[] = [];
    controller.on('status', (event) => {
      if (event.id === id) {
        events.push({ status: event.status, attempt: event.attempt });
      }
    });

    await expect(
      controller.startServer({
        id,
        ...serverCommand(script),
        handshake: { request: handshakeRequest, timeoutMs: 100, retries: 2, backoffMs: 10 }
      })
    ).rejects.toBeInstanceOf(McpProtocolError);

    expect(events[0]).toMatchObject({ status: 'starting' });
    expect(events.at(-1)).toMatchObject({ status: 'failed' });
  });

  it('retries when the server initially responds with invalid JSON', async () => {
    const controller = new McpController();
    const id = `retry-${Date.now()}`;
    const marker = path.join(tmpRoot, `${id}.marker`);
    const script = `
      const fs = require('node:fs');
      const readline = require('node:readline');
      const marker = process.env.MCP_RETRY_MARKER;
      if (marker && !fs.existsSync(marker)) {
        fs.writeFileSync(marker, '1');
        process.stdout.write('not-json\\n');
        setTimeout(() => process.exit(1), 10);
      } else {
        const rl = readline.createInterface({ input: process.stdin });
        rl.on('line', (line) => {
          if (!line) return;
          const msg = JSON.parse(line);
          process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { ready: true } }) + '\\n');
          setTimeout(() => process.exit(0), 20);
        });
      }
    `;
    const events: string[] = [];
    controller.on('status', (event) => {
      if (event.id === id) {
        events.push(event.status);
      }
    });

    const result = await controller.startServer({
      id,
      ...serverCommand(script),
      env: { MCP_RETRY_MARKER: marker },
      handshake: { request: handshakeRequest, timeoutMs: 500, retries: 3, backoffMs: 10 }
    });

    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(events[0]).toBe('starting');
    expect(events.at(-1)).toBe('attached');
    const logContent = fs.readFileSync(result.logPath, 'utf8');
    expect(logContent).toContain('[status] failed');
    expect(logContent).toContain('[status] attached');
  });
});
