# ocs

>The threat model of the project is simple: agents shouldn't be able to access sensitive information like browser cookies, wallet keys, ssh keys, pgp keys, external devices, etc.
They should only have access to what is granted by the user. And `ocs` aims to do that with minimal overhead as possible, thus it uses bubblewrap.
However, be informed that this won't save your project files from getting nuked, that is not in scope of the project.
Also, since `ocs` uses bubblewrap, the host kernel is shared. A rouge agent could possibly escape if it takes use of a vulnerability in the host kernel.
If your threat model includes something like this, please use tools like [gVisor](http://github.com/google/gvisor), [Firecracker](https://github.com/firecracker-microvm/firecracker), or [Kata Containers](https://github.com/kata-containers/kata-containers) instead, that too is not in the scope of the project.
I will not be responsible for the loss of your files.

Run [opencode](https://opencode.ai) inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox. 
The agent sees only what you want it to see and nothing else. Requires no container runtime, no image, no daemon, just bubblewrap:)

## Install

```sh
git clone https://github.com/name/ocs && cd ocs && make install          # -> ~/.local/bin/ocs
```
Requires `bwrap`. On Arch:

```sh
sudo pacman -S bubblewrap
```

## Usage

```sh
~/P/ocs (master)> ocs
ocs 1.0.0
Run opencode inside a bubblewrap sandbox.

USAGE
  ocs [OPTIONS] <PROJECT> [-- OPENCODE_ARGS]

OPTIONS
  -a, --allow <DIR>  Read-write access to host directories
  -r, --ro <DIR>     Read-only access to host directories
  -d, --dev <DEV>    Expose a host device, by name or path
  -s, --serve        Run the web UI (opencode serve) instead of the terminal UI
  -p, --port <PORT>  Port for --serve; opencode picks the next free one otherwise
      --host <HOST>  Address for --serve, e.g. 0.0.0.0 to reach it from other devices
  -nn, --no-net      Unshare the network namespace; run fully offline
  -nc, --no-color    Disable coloured output (NO_COLOR is honoured too)
  -h, --help         Print this help
  -V, --version      Print version
```

## What the sandbox sees by *default*

| Path | Mode |
| --- | --- |
| `/usr` | ro |
| `/bin`, `/sbin`, `/lib`, `/lib64` | symlink |
| `/opt`, `~/.local/bin`, `~/.cargo/bin`, `~/go/bin` | ro, if present |
| `$BREW/{bin,Cellar,etc,lib,share}` | ro, only if opencode lives there |
| `~/.config/opencode` | **rw** |
| `~/.cache/opencode` | **rw** |
| `~/.local/share/opencode` | **rw** |
| `~/.local/state/opencode` | **rw** |
| `/etc/{resolv.conf,hosts,nsswitch.conf,passwd,group,localtime}` | ro |
| `/etc/ssl`, `/etc/ca-certificates` | ro |
| `/proc` | proc |
| `/dev` | dev | devtmpfs
| `/tmp`, `/run` | tmpfs |

## Environment

`ocs` starts the sandbox with `--clearenv`, so the host environment does not ride
along. `ocs` only reads:
`NO_COLOR`, `OCS_TEST_CMD` (test hook), and `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENCODE_API_KEY` are forwaded if set.

## Development

```sh
make lint    # shellcheck -S style
make test    # bats
make check   # both
```

## License

MIT. See [LICENSE](LICENSE).
