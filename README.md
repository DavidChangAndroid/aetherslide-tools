# aetherslide-tools

Public release channel for aetherAI FAE tools. Releases can be downloaded with `curl` or `wget` without authentication.

## Install

```bash
# Install the latest FAE_bashrc.
curl -fsSL https://github.com/DavidChangAndroid/aetherslide-tools/releases/download/fae_bashrc-latest/fae_bashrc.sh -o fae_bashrc.sh
bash fae_bashrc.sh

# Pin a specific version.
curl -fsSL https://github.com/DavidChangAndroid/aetherslide-tools/releases/download/fae_bashrc-v0.5/fae_bashrc.sh -o fae_bashrc.sh
```

Each tool has a moving `<tool>-latest` release and immutable `<tool>-v<version>` releases.

## Publish

The canonical source is maintained in the internal Obsidian vault. Versioned source files are published from the development machine with:

```bash
./publish.sh <tool>
```

The script selects the highest versioned source file, copies it into this repository, commits and pushes it, creates the pinned release, and updates the moving `latest` release.

## Registered tools

| Repository directory | Tool |
| --- | --- |
| `fae_bashrc` | Input-only FAE shell capture for hospital production hosts. |
| `set_configs` | Interactively fill aetherSlide `.env` resource limits. |
| `install_recorder` | Terminal recording and diff capture. |
| `chrome_debug` | Capture a Chrome bug report. |
| `site_config_collector` | Read-only site environment collector. |

To add a tool, add its source directory and filename prefix to `publish.sh` in `vault_dir_for` and `file_prefix_for`.
