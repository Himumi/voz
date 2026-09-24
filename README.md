# VOZ

VOZ is a tool for managing [Zig](https://ziglang.org/) and [Zls](https://zigtools.org) versions.

## Denpendencies

- Zig compiler v0.16.0

## Usage

```
VOZ is a Zig Version Manager.

Usage: voz [command] [options]

Commands:

  install    Download and install selected Zig version
  use        Switch between Zig versions
  list       Print available Zig versions
  remove     Remove an installed Zig version

  help       Print this help and exit
  upgrade    Upgrade VOZ version
  version    Print VOZ version and exit

```

## Features

This is still a work in progress and is not yet at full desired features.

| Feature | Status | Notes |
|---------|--------|-------|
| Install | base | Need clean up, checksum, and minisign handlers |
| Use | none | none |
| list | base | Need to add outdated status for dev version |
| remove | none | none |
| help | done | none |
| upgrade | none | none |
| version | base | Hard coded version |
