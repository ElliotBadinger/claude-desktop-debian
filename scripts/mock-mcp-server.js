#!/usr/bin/env node
const { Server } = require('@modelcontextprotocol/sdk/server');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');

async function main() {
  const server = new Server({
    name: 'mock-mcp-server',
    version: '0.0.1-test'
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(error => {
  console.error('mock-mcp-server error:', error && error.stack ? error.stack : error);
  process.exit(1);
});
