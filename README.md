# CSB (Claude SandBox)

A CLI tool that creates isolated Linux virtual machines for safely running [Claude Code](https://claude.ai/code) in a sandboxed environment.

## Why?

Run Claude Code with peace of mind:

- **Isolated environment** - Claude operates in a VM, not on your host system
- **Network security** - Outbound traffic blocked by default, with allowlist for essential services (npm, PyPI, GitHub, Anthropic APIs)
- **Easy cleanup** - Destroy the VM when done, leaving no trace

## Requirements

- macOS with [Lima](https://lima-vm.io/) installed
- An Anthropic API key

```bash
brew install lima
```

## Installation

### System Install (Recommended)

```bash
git clone https://github.com/danyelf/claude-sandbox-maker.git
cd claude-sandbox-maker
./install.sh
```

This installs:
- `/usr/local/bin/csb` - the CLI
- `/usr/local/share/csb/` - support files (template, config)

To uninstall: `./install.sh --uninstall`

### Development Install

For hacking on csb itself, add the repo to your PATH:

```bash
git clone https://github.com/danyelf/claude-sandbox-maker.git
export PATH="$PATH:$(pwd)/claude-sandbox-maker/csb"
```

## Quick Start

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Navigate to your project
cd ~/my-project

# Start Claude in the sandbox
csb start

# Attach to the Claude session
csb attach
```

Your project directory is mounted at `/workspace` inside the VM.

## Parallel Agents

Run multiple isolated Claude agents in parallel, each with its own user and repo clone:

```bash
# Set GitHub token for git authentication
export GITHUB_TOKEN="ghp_..."

# Start isolated agents (each gets own Linux user)
csb start agent1
csb start agent2
csb start agent3

# List all sessions
csb list

# Attach to a specific agent
csb attach agent1
```

**Key features:**
- Each agent runs as a separate Linux user (`agent1`, `agent2`, etc.)
- Home directories are `chmod 700` - agents cannot see each other's files
- Git repo is cloned to `~/repo` for each agent (synced on start)
- Kernel-enforced isolation (not just instruction-following)

## Commands

| Command | Description |
|---------|-------------|
| `csb start` | Create a new shared Claude session in /workspace |
| `csb start <agent>` | Create an isolated agent with own user and repo clone |
| `csb attach [n]` | Attach to session n (default: most recent) |
| `csb attach <agent>` | Attach to an agent's session |
| `csb shell` | Open a bash shell in the VM |
| `csb list` | Show VM status and active sessions |
| `csb status` | Show VM state and configuration |
| `csb config` | Show how to adjust VM resources |
| `csb stop` | Shut down the VM |
| `csb destroy` | Permanently delete the VM |

## How It Works

1. **VM Creation**: On first run, csb creates a Debian 12 VM using Lima
2. **Provisioning**: Installs Node.js, Python, git, and Claude Code
3. **Network Rules**: Applies iptables rules blocking all outbound traffic except:
   - Package registries (npm, PyPI, Debian)
   - GitHub (for cloning repos)
   - Anthropic APIs (for Claude)
   - DNS and NTP
4. **Session Management**: Runs Claude Code in tmux sessions for easy attach/detach

## Configuration

VM resources can be adjusted via Lima:

```bash
limactl edit <vm-name>
```

Run `csb config` to see the VM name and instructions.

Default: 4 CPUs, 4GiB memory, 30GiB disk

## Debugging

Enable verbose output:

```bash
csb --verbose start
# or
CSB_VERBOSE=true csb start
```

## License

MIT
