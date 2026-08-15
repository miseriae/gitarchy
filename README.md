# Gitarchy

Git status for watched repos in the Omarchy bar: dirty counts, branches, stash, ahead/behind, and lazygit.

## Features

- Branch name + total dirty count in the bar
- Per-repo panel: staged/modified/untracked counts, stash, ahead/behind
- Double-click a repo to open lazygit
- Per-repo actions: open lazygit, fetch, copy remote URL
- Click-to-reveal PR status (via GitHub CLI, when `gh` is installed)

## Requirements

- Omarchy 4.0 (Quattro shell)
- Git
- [lazygit](https://github.com/jesseduffield/lazygit) (optional, for lazygit integration)
- [GitHub CLI](https://cli.github.com/) (optional, for PR status)

## Install

```sh
omarchy plugin add https://github.com/miseriae/gitarchy.git --enable --section right
```

## Configure

Add the widget to your bar and set the repos to watch in `~/.config/omarchy/shell.json`:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "miseriae.gitarchy", "repos": ["~/projects/myproject"], "pollInterval": 30 }
      ]
    }
  }
}
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pollInterval` | int | 30 | Seconds between git status refreshes |
| `repos` | array | `[]` | Repo paths (strings) or `{ "path": ..., "name": ... }` objects |
| `showBranch` | bool | true | Show the primary branch in the bar |
| `showDirty` | bool | true | Show the total dirty count in the bar |

### Repo Entry

| Field | Type | Description |
|-------|------|-------------|
| `path` | string | Path to the git repository (supports `~`) |
| `name` | string | Display name (optional, defaults to folder name) |

## Usage

- **Click** the bar widget to open the status panel
- **Hover** to see per-repo tooltip
- **Click** a repo row to expand actions
- **Double-click** a repo row to open lazygit
- **Right-click** the bar widget to open lazygit for the primary repo
- **Middle-click** the bar widget to refresh now

## License

MIT
