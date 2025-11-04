# scsh

`scsh` is a tiny experimental shell written in Crystal.
It is **not** the Ruby-based `srsh` — this is its own thing.

This is version **0.1.0-BETA**.
It’s early, it’s rough, and it will probably change a lot.

The code is written by **RobertFlexx**, with some comment / doc help from ChatGPT.

## Requirements

* Crystal compiler installed (1.x recommended)
* A POSIX-like terminal (Linux, *BSD, macOS, etc.)

## Installation

### Clone the repository

```console
git clone https://github.com/RobertFlexx/scsh
cd scsh
```

### Build (recommended)

```console
crystal build scsh.cr -o scsh --release
```

### Or run directly (dev/testing)

```console
crystal run scsh.cr
```

## Usage

From inside the repo (or wherever you built the binary):

```console
./scsh
```

Inside `scsh` you can:

* Run normal commands (`ls`, `cat`, `grep`, etc.)
* Use builtins like:

  * `help` – show builtin commands
  * `systemfetch` – simple system info
  * `hist` / `clearhist` – view/clear shell history
  * `alias` / `unalias` – manage aliases
  * `cd`, `pwd`, `jobs`, `exit` / `quit`

## Optional: Add `scsh` to your PATH

After building:

```console
sudo ln -s "$(pwd)/scsh" /usr/local/bin/scsh
```

Now you can simply run:

```console
scsh
```

from anywhere.

## Contributing

Suggestions, issues, and PRs are welcome.
If something feels off, open an issue and yell at the shell, not at yourself :P
