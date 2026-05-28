# dcd - A Dynamic Change Directory

`dcd` is a command-line tool to change your directory dynamically.

## How it works

dcd has three ways to change directories:

- `spawn`: It spawns the `terminal` configured, replacing `%s` with the new directory. It will only work if the terminal you use supports this operation, like [alacritty](https://alacritty.org/);
- `exec`: It changes the current path for `dcd` process and exec your current `shell` (configured or via `$SHELL`). If you exit the new shell, you'll go back to the previous process: `shell -> dcd`, `shell -> shell (new_dir)`, `shell`;
- `exec_quit`: It changes the current path for `dcd` process and exec your current `shell` (configured or via `$SHELL`). When you exit the shell, `dcd` will send a `SIGHUP` signal to the parent process, exiting the shell: `shell -> dcd`, `shell -> shell (new_dir)`, `<no remaining shell>`;

## How to use

- `dcd`: Opens an interactive picker. You can type the name and it will fuzzy match by name (with more weight) and directory. Pressing `Return` will change your directory using your `launch` mode;
- `dcd <name>`: Changes your directory to `<name>` using your `launch` mode;

### Commands

- `list`: Lists every directory in your config;
- `add <name> [<path>] [-r]`: Adds a directory in your config named `<name>`. If provided, it will add the `<path>`. If `<name>` already exists, `-r` will replace it;
- `rm <name>`: Removes the directory named `<name>`;

### Override configuration

- `--config <config-path>`: Uses the config in `<config-path>`;
- `--launch [exec, exec_quit, spawn]`: Launches using the provided launch mode;

## Compatibility

The program was tested only on Linux [NixOS](https://nixos.org/) 25.05. The `exec_quit` launch mode is only compatible with Linux.

## Flakes

Binaries available through [Nix flakes](https://nixos.wiki/wiki/Flakes): `dcd` and `dc`.
