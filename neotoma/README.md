# Neotoma for Yazi

This fork of [Yazi](https://github.com/sxyazi/yazi) adds a plugin for
**Neotoma disks**. Yazi still browses your local disks as usual. The plugin
adds the read-only `neotoma://` filesystem for cataloged disks, including
disks that aren't connected.

| On a Neotoma disk | Connected original | Disconnected disk |
| --- | --- | --- |
| Browse folders, names, sizes, dates | ✓ | ✓ |
| Search catalogs (`g N`) | ✓ | ✓ |
| Preview | ✓ (Yazi's normal previewers) | catalog details only |
| Copy out to a local folder (`y`, `p`) | ✓ | — |
| Rename, delete, write | — (read-only) | — |

A file whose original changed since Neotoma last cataloged it is treated as
unavailable until Neotoma rescans it.

## How it works

Everything Neotoma-specific lives in this `neotoma/` directory. Upstream files
are not modified.

- `neotoma.yazi/main.lua` is a Yazi *hub* VFS provider. Upstream Yazi already
  supports Lua VFS services, as used by `trash://`.
- The provider reads catalogs only through the read-only `neotoma` command-line
  tool, which ships with Neotoma, using its `--json` output:
  `neotoma disks`, `ls`, `stat`, `search` and `original`.
- Connected, unchanged originals become each file's *backing* path. Yazi's
  previewers, MIME detection and copy then read the real file directly.

URL layout:

```
neotoma:///@//                         all disks
neotoma://…/@…/<Disk · id>/<path>     a cataloged folder or file
neotoma://…/@…/.search/<query>        search results across all disks
```

## Install

1. Install the `neotoma` command-line tool, so that `neotoma disks` works.
2. Build this fork with `cargo build --release`, or use an upstream Yazi
   release new enough to have Lua VFS services.
3. Run `neotoma/install.sh`. It copies the plugin into Yazi's config directory.
   It also creates `vfs.toml`, `yazi.toml` and `keymap.toml` from `config/` when
   they don't exist; otherwise it prints the snippet to merge by hand.

Keys: `g n` opens the Neotoma disk list, and `g N` searches all catalogs.

A search shows at most 200 matches and says once, in a notice, when there are more.

Yazi asks every two seconds whether an open folder changed. The plugin answers with `neotoma revision`, which reads
three file times without opening the library, and lists a folder again only when that changes or half a minute has
passed (so a disk being connected or disconnected shows up). With an older `neotoma` that has no `revision`, every
open folder is listed again each time.

## Staying in sync with upstream

```sh
git remote add upstream https://github.com/sxyazi/yazi.git   # once
git fetch upstream
git merge upstream/main
```

All Neotoma code lives in `neotoma/`, so upstream merges don't conflict.
After a merge, re-check that the Lua VFS provider API (`M:provide`, `File`,
`Stat`, `fs.copy`) is unchanged.
