#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');

const BINARIES = {
  'linux-x64': 'ztd-linux-x64',
  'linux-arm64': 'ztd-linux-arm64',
  'linux-arm': 'ztd-linux-arm',
  'darwin-x64': 'ztd-darwin-x64',
  'darwin-arm64': 'ztd-darwin-arm64',
  'win32-x64': 'ztd-win32-x64.exe',
};

const key = `${process.platform}-${process.arch}`;
const binary = BINARIES[key];

if (!binary) {
  const supported = Object.keys(BINARIES).join(', ');
  console.error(`ztd: unsupported platform "${key}". Supported platforms: ${supported}`);
  process.exit(1);
}

const result = spawnSync(path.join(__dirname, binary), process.argv.slice(2), { stdio: 'inherit' });
if (result.error) {
  console.error(`ztd: failed to run binary: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
