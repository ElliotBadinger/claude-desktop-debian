#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const process = require('node:process');
const { setTimeout: delay } = require('node:timers/promises');
const { Client } = require('@modelcontextprotocol/sdk/client');
const { StdioClientTransport } = require('@modelcontextprotocol/sdk/client/stdio.js');

const DEFAULT_TIMEOUT_MS = 15000;
const DEFAULT_RETRIES = 2;

function printUsage() {
  const script = path.basename(process.argv[1] || 'diagnose-mcp.js');
  console.error(`Usage: ${script} --server <name> [--timeout ms] [--retries n] [--verbose]`);
}

function parseArgs(argv) {
  const args = { server: undefined, timeout: DEFAULT_TIMEOUT_MS, retries: DEFAULT_RETRIES, verbose: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--server': {
        const value = argv[i + 1];
        if (!value) {
          throw new Error('--server requires a value');
        }
        args.server = value;
        i += 1;
        break;
      }
      case '--timeout': {
        const value = argv[i + 1];
        if (!value) {
          throw new Error('--timeout requires a value');
        }
        const parsed = Number.parseInt(value, 10);
        if (!Number.isFinite(parsed) || parsed <= 0) {
          throw new Error('--timeout must be a positive integer (milliseconds)');
        }
        args.timeout = parsed;
        i += 1;
        break;
      }
      case '--retries': {
        const value = argv[i + 1];
        if (!value) {
          throw new Error('--retries requires a value');
        }
        const parsed = Number.parseInt(value, 10);
        if (!Number.isFinite(parsed) || parsed < 0) {
          throw new Error('--retries must be a non-negative integer');
        }
        args.retries = parsed;
        i += 1;
        break;
      }
      case '--verbose':
        args.verbose = true;
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
        break;
      default:
        if (arg.startsWith('-')) {
          throw new Error(`Unknown argument: ${arg}`);
        }
    }
  }
  if (!args.server) {
    throw new Error('Missing required --server argument');
  }
  return args;
}

function resolveConfigPath() {
  if (process.env.CLAUDE_DESKTOP_CONFIG) {
    return process.env.CLAUDE_DESKTOP_CONFIG;
  }
  const configDir = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  return path.join(configDir, 'Claude', 'claude_desktop_config.json');
}

function loadConfig(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Configuration file not found at ${filePath}`);
  }
  const raw = fs.readFileSync(filePath, 'utf8');
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Failed to parse configuration: ${(error && error.message) || error}`);
  }
}

function resolveServerConfig(config, serverName) {
  const servers = (config && (config.mcpServers || config.mcp_servers)) || {};
  const server = servers[serverName];
  if (!server) {
    throw new Error(`Server '${serverName}' not found in configuration`);
  }
  if (server.disabled || server.enabled === false) {
    throw new Error(`Server '${serverName}' is disabled in configuration`);
  }
  if (server.transport && server.transport !== 'stdio') {
    throw new Error(`Server '${serverName}' uses unsupported transport '${server.transport}'. Only 'stdio' is supported.`);
  }
  if (!server.command || typeof server.command !== 'string') {
    throw new Error(`Server '${serverName}' is missing a string 'command' field`);
  }
  let args = [];
  if (Array.isArray(server.args)) {
    args = server.args.map(String);
  } else if (server.args && typeof server.args === 'object') {
    throw new Error(`Server '${serverName}' has invalid 'args' format; expected array of strings`);
  }
  const env = {};
  if (server.env && typeof server.env === 'object') {
    for (const [key, value] of Object.entries(server.env)) {
      if (value !== undefined && value !== null) {
        env[key] = String(value);
      }
    }
  }
  const cwd = server.cwd && typeof server.cwd === 'string' ? server.cwd : undefined;
  return {
    name: serverName,
    command: server.command,
    args,
    env,
    cwd
  };
}

function resolveStateDir(serverName) {
  const stateRoot = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
  const dir = path.join(stateRoot, 'claude-desktop', 'mcp', 'diagnostics', serverName, new Date().toISOString().replace(/[:.]/g, '-'));
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function createLogger(outputDir, verbose) {
  const logPath = path.join(outputDir, 'diagnose.log');
  const logStream = fs.createWriteStream(logPath, { flags: 'a' });
  function log(message) {
    const line = `[${new Date().toISOString()}] ${message}`;
    logStream.write(`${line}\n`);
    if (verbose) {
      console.log(line);
    }
  }
  function close() {
    logStream.end();
  }
  return { log, close, logPath };
}

async function runAttempt({ attempt, totalAttempts, serverConfig, timeout, log }) {
  const env = Object.assign({}, serverConfig.env);
  if (env.MCP_DEBUG === undefined) {
    env.MCP_DEBUG = process.env.MCP_DEBUG || '1';
  }

  const transport = new StdioClientTransport({
    command: serverConfig.command,
    args: serverConfig.args,
    env,
    cwd: serverConfig.cwd,
    stderr: 'pipe'
  });

  const stderrPath = path.join(serverConfig.outputDir, `server-stderr-attempt-${attempt + 1}.log`);
  const stderrStream = fs.createWriteStream(stderrPath, { flags: 'a' });
  const stderr = transport.stderr;
  if (stderr) {
    stderr.setEncoding('utf8');
    stderr.on('data', chunk => {
      stderrStream.write(chunk);
    });
  }

  const client = new Client({
    name: 'claude-desktop-diagnostics',
    version: '1.0.0'
  });

  transport.onerror = error => {
    log(`transport error: ${(error && error.message) || error}`);
  };
  client.onerror = error => {
    log(`client error: ${(error && error.message) || error}`);
  };

  log(`Attempt ${attempt + 1}/${totalAttempts}: launching '${serverConfig.command}' ${serverConfig.args.join(' ')}`);

  try {
    await client.connect(transport, { timeout });
    const serverInfo = client.getServerVersion();
    if (serverInfo) {
      log(`Handshake succeeded with server '${serverInfo.name}' (version ${serverInfo.version || 'unknown'})`);
    } else {
      log('Handshake succeeded but server version information was not provided.');
    }
    await client.close();
    await transport.close();
    stderrStream.end();
    return { success: true, serverInfo };
  } catch (error) {
    log(`Handshake failed: ${(error && error.stack) || error}`);
    try {
      await client.close();
    } catch (closeError) {
      log(`Error closing client: ${(closeError && closeError.message) || closeError}`);
    }
    try {
      await transport.close();
    } catch (closeError) {
      log(`Error closing transport: ${(closeError && closeError.message) || closeError}`);
    }
    stderrStream.end();
    throw error;
  }
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error((error && error.message) || error);
    printUsage();
    process.exit(1);
  }

  const configPath = resolveConfigPath();
  let config;
  try {
    config = loadConfig(configPath);
  } catch (error) {
    console.error((error && error.message) || error);
    process.exit(1);
  }

  let serverConfig;
  try {
    serverConfig = resolveServerConfig(config, args.server);
  } catch (error) {
    console.error((error && error.message) || error);
    process.exit(1);
  }

  const outputDir = resolveStateDir(args.server);
  const { log, close, logPath } = createLogger(outputDir, args.verbose);
  serverConfig.outputDir = outputDir;

  log(`Using configuration file ${configPath}`);
  log(`Logs and artifacts will be written to ${outputDir}`);
  log(`Timeout: ${args.timeout}ms, Retries: ${args.retries}`);

  const metadata = {
    server: args.server,
    command: serverConfig.command,
    args: serverConfig.args,
    cwd: serverConfig.cwd,
    attempts: [],
    createdAt: new Date().toISOString(),
    configPath
  };

  let success = false;
  let attemptError = null;
  for (let attempt = 0; attempt <= args.retries; attempt += 1) {
    const attemptInfo = { attempt: attempt + 1, startedAt: new Date().toISOString() };
    try {
      const result = await runAttempt({
        attempt,
        totalAttempts: args.retries + 1,
        serverConfig,
        timeout: args.timeout,
        log
      });
      attemptInfo.completedAt = new Date().toISOString();
      attemptInfo.success = true;
      attemptInfo.serverInfo = result.serverInfo || null;
      metadata.attempts.push(attemptInfo);
      success = true;
      break;
    } catch (error) {
      attemptError = error;
      attemptInfo.completedAt = new Date().toISOString();
      attemptInfo.success = false;
      attemptInfo.error = (error && error.message) || String(error);
      metadata.attempts.push(attemptInfo);
      if (attempt < args.retries) {
        log(`Retrying after failure (attempt ${attempt + 1} of ${args.retries + 1}).`);
        await delay(1000);
      }
    }
  }

  fs.writeFileSync(path.join(outputDir, 'metadata.json'), JSON.stringify(metadata, null, 2));
  close();

  if (!success) {
    console.error(`diagnose-mcp: failed to handshake with '${args.server}'. See ${logPath} for details.`);
    if (attemptError) {
      console.error((attemptError && attemptError.stack) || attemptError);
    }
    process.exit(2);
  }

  if (args.verbose) {
    console.log(`Diagnostics completed successfully. Detailed logs: ${logPath}`);
  }
}

main().catch(error => {
  console.error('diagnose-mcp encountered an unexpected error:', error && error.stack ? error.stack : error);
  process.exit(1);
});
