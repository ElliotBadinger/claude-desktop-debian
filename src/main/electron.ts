import { EventEmitter } from 'events';
import type { HandshakeOptions } from '../mcp/protocol';
import { attachWithRetry } from '../mcp/protocol';
import { launchServer, type LaunchOptions } from '../mcp/launcher';

export type McpStatus = 'starting' | 'attached' | 'failed';

export interface McpStatusEvent {
  id: string;
  status: McpStatus;
  attempt: number;
  error?: unknown;
}

export interface StartServerOptions extends LaunchOptions {
  handshake: HandshakeOptions;
}

export interface StartResult {
  id: string;
  logPath: string;
}

const DEBUG_ENABLED = process.env.MCP_DEBUG === '1';

export class McpController extends EventEmitter {
  constructor() {
    super();
  }

  async startServer(options: StartServerOptions): Promise<StartResult> {
    const { id, handshake, command, args, cwd, env } = options;
    this.emitStatus({ id, status: 'starting', attempt: 1 });

    const launchConfig: LaunchOptions = { id, command, args, cwd, env };

    const result = await attachWithRetry(
      () => launchServer(launchConfig),
      handshake
    ).catch((error) => {
      const attempt = error instanceof Error && 'attempt' in error ? (error as any).attempt ?? 1 : 1;
      this.emitStatus({ id, status: 'failed', attempt, error });
      throw error;
    });

    this.emitStatus({ id, status: 'attached', attempt: result.attempt });

    result.process.once('exit', (code, signal) => {
      const exitInfo = { code, signal };
      if (DEBUG_ENABLED) {
        console.info(`[MCP] ${id} exited`, exitInfo);
      }
      this.emit('exit', { id, ...exitInfo });
    });

    return { id, logPath: result.logPath };
  }

  private emitStatus(event: McpStatusEvent): void {
    if (DEBUG_ENABLED) {
      console.info(`[MCP] status ${event.id}: ${event.status} (attempt ${event.attempt})`);
      if (event.error) {
        console.error(`[MCP] error ${event.id}:`, event.error);
      }
    }
    this.emit('status', event);
  }
}
