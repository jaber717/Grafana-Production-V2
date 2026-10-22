# Getting the release from the private GitHub repository

> **Release 2.x lives in `jaber717/Grafana-Production-V2`** (private). Substitute that repository and the 2.x tag/file names in the commands below
> (`grafana-platform-2.0.0-rhel9-offline.tar.gz`). The table and commands that follow are kept from release 1.0.1 of `jaber717/Grafana`.
> A 2.0 offline archive can also be produced from the published 1.0.1 archive without further downloads: `tools/build-offline-bundle.sh --from-bundle <1.0.1 archive> dist`.

The repository `jaber717/Grafana` is **private**. Production servers should not hold GitHub credentials for long; pick the option that fits your network.

| Option | When | What the server needs |
|---|---|---|
| **A. Download on a workstation, copy to the server** (recommended) | servers without Internet, or when you do not want any GitHub credential on a server | nothing from GitHub |
| **B. Download on the server with a read-only token** | the server may reach `github.com` | a fine-grained token, used once |
| **C. `git clone` with a read-only deploy key** | you want to track a tag with git | an SSH deploy key on the server |

## What a release provides (exact locations)

For tag `v1.0.1` of `jaber717/Grafana` (replace the tag for other releases):

| Asset | Location (needs repository access) |
|---|---|
| Source of the tagged commit | `https://github.com/jaber717/Grafana/archive/refs/tags/v1.0.1.tar.gz` |
| **Offline bundle** (release + RPM + plugins + Node.js), ~320 MB | `https://github.com/jaber717/Grafana/releases/download/v1.0.1/grafana-platform-1.0.1-rhel9-offline.tar.gz` |
| SHA-256 of the bundle | `…/releases/download/v1.0.1/grafana-platform-1.0.1-rhel9-offline.tar.gz.sha256` |
| Release notes with the validated commit SHA and the acceptance summary | `https://github.com/jaber717/Grafana/releases/tag/v1.0.1` |

## A. Workstation download (GitHub CLI)
```bash
gh auth login                                   # once, interactively, on the workstation (your account has access to the private repo)
gh release download v1.0.1 --repo jaber717/Grafana --pattern 'grafana-platform-1.0.1-rhel9-offline.tar.gz*' --dir .
sha256sum -c grafana-platform-1.0.1-rhel9-offline.tar.gz.sha256
scp grafana-platform-1.0.1-rhel9-offline.tar.gz* admin@grafana-server:/tmp/        # or approved media for an air-gapped server
```
Then follow [OFFLINE.md](OFFLINE.md) (also for a server that *can* reach the Internet: the bundle simply avoids all downloads).

## B. Download on the server with a read-only token
1. In GitHub create a **fine-grained personal access token**: resource owner = your account, **only** repository `jaber717/Grafana`, permission **Contents: Read-only**, expiry ≤ 7 days.
2. On the server (not in shell history, not on a shared host):
   ```bash
   read -rs GH_TOKEN; export GH_TOKEN
   curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/jaber717/Grafana/releases/tags/v1.0.1 | jq -r '.assets[] | "\(.id) \(.name)"'
   curl -fSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" \
        -o grafana-platform-1.0.1-rhel9-offline.tar.gz https://api.github.com/repos/jaber717/Grafana/releases/assets/<id-from-the-list>
   unset GH_TOKEN
   ```
   Do the same for the `.sha256` asset, verify, and revoke the token in GitHub.

## C. Deploy key
```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/grafana_deploy -C "grafana-platform deploy key (read-only)"
# add /root/.ssh/grafana_deploy.pub in GitHub: repository Settings → Deploy keys → "Allow write access" UNCHECKED
GIT_SSH_COMMAND='ssh -i /root/.ssh/grafana_deploy -o IdentitiesOnly=yes' git clone --branch v1.0.1 --depth 1 git@github.com:jaber717/Grafana.git
```
After cloning, `git verify-tag` is not available (tags are not signed); compare `git rev-parse HEAD` with the commit SHA in the release notes.

## What is verified, and what is not
* The bundle's content is verified against SHA-256 values **pinned in the repository** (RPM, plugins, Node.js) and the RPM against the pinned Grafana Labs signing key; a tampered *asset* is detected by the `.sha256` file and by the installer.
* Release assets and tags are **not signed** with a project key. Trust in "this is the release the maintainers validated" rests on your GitHub access control and on comparing the commit SHA with the release notes. If you need signed releases, add `git tag -s` and detached signatures to your release process.
* No GitHub credential is ever stored by `grafana-platform`, and none is required after the files are on the server.
