#!/usr/bin/env node
/*
 * Lightweight MCP diagnostic harness for packaging CI.
 *
 * The upstream Windows release bundles MCP extensions as signed archives.
 * Those bundles are unpacked by the Electron launcher at runtime inside the
 * user's XDG state directory. When packaging on Linux we only ship those
 * archives, so CI needs to sanity check that the artifacts exist and look
 * healthy without actually booting the graphical app.
 */

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');

const args = new Set(process.argv.slice(2));
const verbose = args.has('--verbose');

function log(message) {
  const line = `[diagnose] ${message}`;
  console.log(line);
  diagnostics.push({ level: 'info', message, timestamp: new Date().toISOString() });
}

function debug(message) {
  if (!verbose) return;
  const line = `[diagnose:debug] ${message}`;
  console.log(line);
  diagnostics.push({ level: 'debug', message, timestamp: new Date().toISOString() });
}

function warn(message) {
  const line = `[diagnose:warn] ${message}`;
  console.warn(line);
  diagnostics.push({ level: 'warn', message, timestamp: new Date().toISOString() });
}

const diagnostics = [];

const workspace = process.env.GITHUB_WORKSPACE || process.cwd();
const xdgStateHome = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state');
const xdgCacheHome = process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
const xdgDataHome = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
const xdgConfigHome = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');

const diagnosticRoot = path.join(xdgStateHome, 'claude-desktop', 'mcp', 'diagnostics');
const bundleCacheRoot = path.join(xdgCacheHome, 'claude-desktop', 'mcp');
const bundleDataRoot = path.join(xdgDataHome, 'claude-desktop', 'mcp');

async function ensureDirectories() {
  for (const dir of [diagnosticRoot, bundleCacheRoot, bundleDataRoot]) {
    await fsp.mkdir(dir, { recursive: true });
  }
}

async function fileExists(filePath) {
  try {
    await fsp.access(filePath, fs.constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function discoverManifests(root, depth = 0, maxDepth = 4) {
  const manifests = [];
  if (depth > maxDepth) {
    return manifests;
  }
  let entries;
  try {
    entries = await fsp.readdir(root, { withFileTypes: true });
  } catch (error) {
    debug(`Skipping ${root}: ${error.message}`);
    return manifests;
  }
  for (const entry of entries) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.')) continue;
      manifests.push(...await discoverManifests(entryPath, depth + 1, maxDepth));
    } else if (entry.isFile() && entry.name.toLowerCase() === 'manifest.json') {
      manifests.push(entryPath);
    }
  }
  return manifests;
}

async function parseManifest(filePath) {
  try {
    const raw = await fsp.readFile(filePath, 'utf8');
    const json = JSON.parse(raw);
    return { json, raw };
  } catch (error) {
    return { error };
  }
}

function isMcpManifest(json) {
  if (!json || typeof json !== 'object') return false;
  if (json.type && typeof json.type === 'string' && json.type.toLowerCase().includes('mcp')) {
    return true;
  }
  if (json.mcp || json.mcpServer || json.mcpServers) {
    return true;
  }
  if (json.capabilities && typeof json.capabilities === 'object') {
    const keys = Object.keys(json.capabilities);
    return keys.some((key) => key.toLowerCase().includes('mcp'));
  }
  return false;
}

async function run() {
  await ensureDirectories();
  log(`Workspace root: ${workspace}`);
  debug(`State root: ${diagnosticRoot}`);

  const rootsToProbe = new Set([
    path.join(workspace, 'resources'),
    path.join(workspace, 'bundled-mcp'),
    path.join(workspace, 'build', 'bundled-mcp'),
    path.join(workspace, 'dist', 'bundled-mcp'),
    bundleDataRoot,
    bundleCacheRoot,
  ]);

  const customRoots = process.env.MCP_DIAG_EXTRA_ROOTS;
  if (customRoots) {
    for (const segment of customRoots.split(path.delimiter)) {
      if (!segment) continue;
      rootsToProbe.add(path.resolve(segment));
    }
  }

  const discovered = [];
  for (const root of rootsToProbe) {
    const exists = await fileExists(root);
    debug(`Probe ${root}: ${exists ? 'exists' : 'missing'}`);
    if (!exists) continue;
    const manifests = await discoverManifests(root);
    for (const manifestPath of manifests) {
      const { json, error } = await parseManifest(manifestPath);
      if (error) {
        warn(`Failed to parse manifest at ${manifestPath}: ${error.message}`);
        discovered.push({ manifestPath, status: 'parse-error', error: error.message });
        continue;
      }
      if (!isMcpManifest(json)) {
        debug(`Skipping non-MCP manifest ${manifestPath}`);
        continue;
      }
      discovered.push({ manifestPath, status: 'pending', manifest: json });
    }
  }

  if (discovered.length === 0) {
    warn('No bundled MCP manifests were found. Skipping runtime checks.');
    await emitSummary({
      status: 'skipped',
      reason: 'No manifests discovered',
      scannedRoots: Array.from(rootsToProbe),
      diagnostics,
    });
    return;
  }

  let failures = 0;
  for (const item of discovered) {
    if (item.status === 'parse-error') {
      failures += 1;
      continue;
    }
    const name = item.manifest?.name || path.basename(path.dirname(item.manifestPath));
    const logPath = path.join(diagnosticRoot, `${sanitizeFileName(name)}.log`);
    const lines = [];
    lines.push(`manifest: ${item.manifestPath}`);
    lines.push(`name: ${name}`);
    if (item.manifest?.version) {
      lines.push(`version: ${item.manifest.version}`);
    }
    const entry = item.manifest?.entry || item.manifest?.entryPoint || item.manifest?.main;
    if (entry) {
      const resolved = path.resolve(path.dirname(item.manifestPath), entry);
      const exists = await fileExists(resolved);
      lines.push(`entry: ${entry}`);
      lines.push(`entryResolved: ${resolved}`);
      lines.push(`entryExists: ${exists}`);
      if (!exists) {
        failures += 1;
        warn(`Missing entrypoint for ${name} (${resolved})`);
      }
    } else {
      warn(`Manifest ${name} does not declare an entry point`);
      failures += 1;
    }
    if (item.manifest?.capabilities) {
      lines.push(`capabilities: ${Object.keys(item.manifest.capabilities).join(', ')}`);
    }
    await fsp.writeFile(logPath, `${lines.join('\n')}\n`, 'utf8');
    debug(`Wrote diagnostic log ${logPath}`);
    item.status = 'checked';
  }

  await emitSummary({
    status: failures > 0 ? 'failed' : 'passed',
    scannedRoots: Array.from(rootsToProbe),
    manifestsChecked: discovered.length,
    failures,
    diagnostics,
  });

  if (failures > 0) {
    process.exitCode = 1;
  }
}

function sanitizeFileName(name) {
  return name.replace(/[^a-z0-9-_]+/gi, '_');
}

async function emitSummary(summary) {
  const summaryPath = path.join(diagnosticRoot, 'summary.json');
  await fsp.writeFile(summaryPath, JSON.stringify(summary, null, 2), 'utf8');
  log(`Wrote summary to ${summaryPath}`);
}

run().catch((error) => {
  console.error('[diagnose:error]', error);
  process.exitCode = 1;
});
