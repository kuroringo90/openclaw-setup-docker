# AGENTS.md - OpenClaw Manager

This repository contains a Docker management script for [OpenClaw](https://github.com/openclaw/openclaw), an AI agent framework.

## Repository Overview

- **Main file**: `openclaw-manager.sh` - A bash script for managing the OpenClaw Docker container on Arch Linux
- **Purpose**: Start, stop, restart, backup, and manage the OpenClaw container

## Build / Test Commands

There is no build process since this is a shell script. To validate the script:

```bash
# Check script syntax
bash -n openclaw-manager.sh

# Run shellcheck (if installed)
shellcheck openclaw-manager.sh

# Make executable
chmod +x openclaw-manager.sh
```

### Running the Script

```bash
./openclaw-manager.sh start      # Start the container
./openclaw-manager.sh stop       # Stop the container
./openclaw-manager.sh restart    # Restart the container
./openclaw-manager.sh shell      # Enter container shell
./openclaw-manager.sh logs       # View logs
./openclaw-manager.sh status     # Show status
./openclaw-manager.sh backup    # Create backup
./openclaw-manager.sh reset      # Reset everything
./openclaw-manager.sh update     # Update Docker image
./openclaw-manager.sh help       # Show help
```

## Code Style Guidelines

### Shell Script Conventions

- **Shebang**: Use `#!/bin/bash`
- **Error handling**: Always use `set -euo pipefail`
- **Variables**: Use `${VAR}` syntax, lowercase with underscores (e.g., `data_dir`)
- **Constants**: UPPERCASE with underscores (e.g., `CONTAINER_NAME`)
- **Functions**: Use `cmd_function_name()` format for CLI commands
- **Logging**: Use helper functions: `log_info`, `log_success`, `log_warn`, `log_error`

### Formatting

- Indentation: 4 spaces
- Max line length: 100 characters (soft limit)
- Use here-docs for multi-line strings
- Blank lines between logical sections

### Error Handling

- Always check prerequisites before running commands
- Use `command -v <cmd> &> /dev/null` to check for required tools
- Exit with code 1 on errors
- Provide helpful error messages with suggested solutions

### Comments

- Use `#` for section headers (e.g., `# ============================================`)
- Italian comments in this script (project convention)
- Keep comments brief and functional

### Variable Naming

| Type | Convention | Example |
|------|------------|---------|
| Constants | UPPER_CASE | `CONTAINER_NAME` |
| Config | Upper_Case | `DATA_DIR` |
| Local vars | lowercase | `uid`, `timestamp` |
| Functions | snake_case | `check_prereqs()` |
| CLI commands | cmd_verb | `cmd_start()` |

### Imports / Dependencies

- Check for required commands before use
- Use `command -v` to verify availability
- Docker and docker-compose required

### Best Practices

1. Use `local` for function-scoped variables
2. Quote all variable expansions: `"${VAR}"`
3. Use `[[ ]]` for bash conditionals (not `[ ]`)
4. Check command success with `|| exit 1`
5. Use descriptive function and variable names

## Docker Configuration

- **Image**: `ghcr.io/openclaw/openclaw:latest`
- **Container name**: `openclaw`
- **Data directory**: `~/.openclaw/`
- **Restart policy**: `unless-stopped`
- **Network**: host mode

## Important Notes

- This script is designed for Arch Linux (uses `pacman` in error messages)
- Container runs as UID 1000 (node user)
- Data persists in `~/.openclaw/data/`
- Backup files stored in `~/openclaw-backups/`
