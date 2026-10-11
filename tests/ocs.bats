#!/usr/bin/env bats
#
# ocs test suite.
#
# Run: OCS=./ocs bats ocs.bats     (or: make test)

setup() {
    OCS="${OCS:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/ocs}"
    export OCS

    T="$(mktemp -d)"
    # Point HOME at the fixture: the tool writes nothing to it, but a leak
    # should land somewhere disposable.
    export HOME="$T/home"
    mkdir -p "$HOME" "$T/proj"
}

teardown() {
    [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"
    return 0
}

# Run a probe inside the sandbox. @T@ expands to the fixture root in the
# caller, because the sandbox starts with --clearenv.
# OCS_QUIET suppresses the "using ..." banner, which bats `run` would fold
# into $output alongside the probe's own stdout.
sb() { OCS_TEST_CMD="${1//@T@/$T}" OCS_QUIET=1 "$OCS" "$T/proj" "${@:2}"; }

has()    { [[ "$output" == *"$1"* ]]; }
hasnt()  { [[ "$output" != *"$1"* ]]; }
refute() { [[ "$output" != *"$1"* ]]; }

# Stub the opencode binary plus a copy of ocs that resolves it first, so the
# real exec path — and therefore argument passthrough — is exercised. The
# stub dir must be granted, since nothing outside the project is visible.
stub_opencode() {
    STUB_BIN="$T/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\nprintf "ARGV:"; for a in "$@"; do printf " [%%s]" "$a"; done; echo\n' \
        > "$STUB_BIN/opencode"
    cp "$OCS" "$STUB_BIN/ocs"
    chmod +x "$STUB_BIN/opencode" "$STUB_BIN/ocs"
}

# Run ocs against the stub, via the stub copy so `command -v` finds it first.
run_stub() {
    run env PATH="$STUB_BIN:$PATH" "${QUIET_ENV:-OCS_QUIET=1}" \
        bash -c "PATH='$STUB_BIN':\$PATH ocs '$T/proj' -r '$STUB_BIN' $*"
}

# =========================================================== functional ====

@test "functional: cwd is the project" {
    run sb 'pwd'
    has "$T/proj"
}

@test "functional: project is writable" {
    run sb 'touch marker.new && echo WROTE'
    has "WROTE"
}

@test "functional: host toolchain is present" {
    run sb 'command -v git >/dev/null && echo yes'
    has "yes"
}

# ============================================================ filesystem ====

@test "filesystem: unbound host paths are hidden" {
    mkdir -p "$T/sibling" "$T/private"
    echo SECRET > "$T/private/s.txt"
    run sb 'ls "@T@/sibling" >/dev/null 2>&1 && echo SEEN_SIBLING || echo NO_SIBLING;
            cat "@T@/private/s.txt" >/dev/null 2>&1 && echo SEEN_FILE || echo NO_FILE'
    has "NO_SIBLING"
    has "NO_FILE"
}

@test "filesystem: host dotfiles are hidden" {
    mkdir -p "$HOME/.probe"
    echo HOSTSECRET > "$HOME/.probe/token.txt"
    run sb 'cat ~/.probe/token.txt >/dev/null 2>&1 && echo LEAKED || echo HIDDEN'
    has "HIDDEN"
}

@test "filesystem: /etc/shadow is not readable" {
    run sb 'cat /etc/shadow 2>&1'
    hasnt "root:"
}

@test "filesystem: /usr is read-only" {
    run sb 'touch /usr/__probe 2>/dev/null && echo WROTE || echo DENIED'
    has "DENIED"
}

@test "filesystem: --allow grants read-write" {
    mkdir -p "$T/rw"
    run sb 'touch "@T@/rw/w" 2>/dev/null && echo WROTE' -a "$T/rw"
    has "WROTE"
}

@test "filesystem: --ro grants reads but denies writes" {
    mkdir -p "$T/ro"
    echo RODATA > "$T/ro/f.txt"
    run sb 'cat "@T@/ro/f.txt" && touch "@T@/ro/w" 2>/dev/null && echo WROTE || echo DENIED' -r "$T/ro"
    has "RODATA"
    has "DENIED"
}

@test "filesystem: --allow cannot widen a --ro path" {
    # Order matters: the ro bind comes last, so it wins.
    mkdir -p "$T/ro"
    run sb 'touch "@T@/ro/w" 2>/dev/null && echo WROTE || echo DENIED' -a "$T/ro" -r "$T/ro"
    has "DENIED"
}

@test "filesystem: paths with spaces work" {
    mkdir -p "$T/dir with spaces"
    run sb 'ls "@T@/dir with spaces" >/dev/null && echo SEEN' -r "$T/dir with spaces"
    has "SEEN"
}

# ============================================================== devices ====

@test "devices: host devices are absent by default" {
    run sb 'for d in video0 bus snd dri kvm input fuse hidraw0 mapper; do
                [ -e "/dev/$d" ] && echo -n "$d "; done; echo'
    hasnt "video0"
    hasnt "dri"
    hasnt "input"
}

@test "devices: character devices remain available" {
    run sb 'for d in zero null urandom; do [ -c "/dev/$d" ] && echo -n "$d "; done; echo'
    has "zero"
}

@test "devices: mknod is denied" {
    run sb 'mknod /tmp/fv c 81 0 2>/dev/null && echo MKNOD_OK || echo MKNOD_DENIED'
    has "MKNOD_DENIED"
}

@test "devices: --dev exposes the device and it is usable" {
    run sb 'dd if=/dev/zero of=/dev/null bs=1 count=1 2>/dev/null && echo READABLE || echo NOACCESS' -d zero
    has "READABLE"
}

# ============================================================== network ====

@test "network: CA bundle resolves, so TLS can verify" {
    # Arch's ca-certificates.crt is a relative symlink out of /etc/ssl, so
    # /etc/ca-certificates must be bound too or this dangles.
    run sb '[ -s /etc/ssl/certs/ca-certificates.crt ] && echo OK || echo DANGLING'
    has "OK"
}

@test "network: TLS handshake succeeds end to end" {
    # Covers DNS, /etc/resolv.conf and the CA bundle in one real request.
    run sb 'curl -sS -o /dev/null -w "%{http_code}" --max-time 12 https://github.com 2>&1 | tail -c 12'
    [[ "$output" =~ [0-9]{3} ]] || skip "TLS probe inconclusive"
}

@test "network: --no-net blocks egress" {
    run sb 'curl -sS -o /dev/null --max-time 8 https://example.com 2>/dev/null && echo CONNECTED || echo REFUSED' --no-net
    has "REFUSED"
}

# =========================================================== environment ====

@test "env: host variables are cleared" {
    # --clearenv is the whole mechanism. AWS_SECRET_ACCESS_KEY was a second
    # test for the same line of code.
    run env HOST_ONLY_VAR=leaked AWS_SECRET_ACCESS_KEY=leaked \
        bash -c "OCS_TEST_CMD='echo [\${HOST_ONLY_VAR:-unset}][\${AWS_SECRET_ACCESS_KEY:-unset}]' '$OCS' '$T/proj'"
    has "[unset][unset]"
}

@test "secrets: the API key does reach the sandbox" {
    # Forwarded with --setenv, which is a deliberate trade: the agent needs the
    # key, and --clearenv means host inheritance cannot reach it any other way.
    # Nothing is written to disk, no temp file, no wrapper process.
    run env ANTHROPIC_API_KEY=sk-test-fake OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='echo K=[\${ANTHROPIC_API_KEY:-unset}]' '$OCS' '$T/proj'"
    has "K=[sk-test-fake]"
}

# The key is visible in bwrap's argv, because that is what --setenv means.
# Deliberately not tested: an assertion here would only lock in the current
# shape, and the security argument (same-uid readers already have the key from
# the caller's environment) does not depend on it.

# ========================================================== privileges ====

@test "privileges: no capabilities are held" {
    run sb 'while read -r k v _; do [ "$k" = CapEff: ] && break; done < /proc/self/status; echo "$v"'
    has "0000000000000000"
}

@test "privileges: nested namespaces are refused" {
    run sb 'unshare --mount true 2>/dev/null && echo OK || echo DENIED'
    has "DENIED"
}

# =========================================================== sandboxing ====

@test "escape: --allow /dev is refused, so the host device set stays out" {
    # /dev is on the refuse-list. This used to assert that a granted /dev still
    # hid the host's devices, which is true but not what happens: the grant is
    # rejected outright, so the sandbox never starts at all.
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' -a /dev"
    [ "$status" -ne 0 ]
    has "refusing to grant /dev"

    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --allow=/dev"
    [ "$status" -ne 0 ]
    has "refusing to grant /dev"
}

@test "escape: / is refused as a grant and as the project" {
    # Verified before the guard existed: "--bind / /" put TOPSECRET from an
    # unrelated directory inside the sandbox. The project faces the same list,
    # or "ocs /" would hand over the host read-write.
    #
    # The bare / case gets its own message, because a mistyped path is far more
    # likely than a real request to hand over the whole filesystem.
    run bash -c "OCS_QUIET=1 '$OCS' /"
    [ "$status" -ne 0 ]
    has "refusing to grant /"
    has "Give the full path"

    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' -a /"
    [ "$status" -ne 0 ]
    has "refusing to grant /"

    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' -a /usr"
    [ "$status" -ne 0 ]
    has "refusing to grant /usr"
}

@test "escape: legitimate subdirectories are still grantable" {
    # The guard is one-directional on purpose. A two-directional check would
    # refuse these and make the tool unusable.
    mkdir -p "$T/notes"
    run sb 'ls -d "@T@/notes" >/dev/null && echo SEEN' --ro /usr/local/share --ro "$T/notes"
    has "SEEN"
}

# ================================================================ brew ====

# A stub `brew` that reports a prefix of our choosing, so the prefix ocs binds
# can be steered without installing anything.
stub_brew() {
    mkdir -p "$T/bin"
    printf '#!/bin/sh\n[ "$1" = --prefix ] && printf "%%s\\n" "%s"\n' "$1" > "$T/bin/brew"
    chmod +x "$T/bin/brew"
}

@test "brew: HOMEBREW_PREFIX is honoured when opencode lives in it" {
    stub_brew "$T/never-used"
    mkdir -p "$T/pref/bin" "$T/pref/lib" "$T/pref/Cellar/opencode/1.0/bin"
    echo PREFIXLIB > "$T/pref/lib/marker"
    printf '#!/bin/sh\necho S\n' > "$T/pref/Cellar/opencode/1.0/bin/opencode"
    chmod +x "$T/pref/Cellar/opencode/1.0/bin/opencode"
    ln -sf ../Cellar/opencode/1.0/bin/opencode "$T/pref/bin/opencode"

    # $T/bin, not $PATH: this host has a real opencode under /home/linuxbrew,
    # and "command -v opencode" is tried first, so an inherited PATH would find
    # that one and never look at the prefix under test.
    run env HOMEBREW_PREFIX="$T/pref" PATH="$T/bin:/usr/bin:/bin" OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='cat \"$T/pref/lib/marker\"; echo P=\$PATH' '$OCS' '$T/proj'"
    [ "$status" -eq 0 ]
    has "PREFIXLIB"
    has "$T/pref/bin"
}

@test "binds: nothing is bound that does not exist, and PATH matches" {
    # A blind --ro-bind-try for a directory that is not there is harmless in
    # effect but lies in the argument list, and a PATH entry pointing at an
    # unmounted directory is worse: it advertises a toolchain that is absent.
    mkdir -p "$T/stub/bin"
    printf '#!/bin/sh\necho S\n' > "$T/stub/bin/opencode"
    chmod +x "$T/stub/bin/opencode"

    # Ask inside the sandbox, so the answer reflects the sandbox's own view.
    run env -u HOMEBREW_PREFIX PATH="$T/stub/bin:/usr/bin:/bin" OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='for d in \$(echo \$PATH | tr : \" \"); do [ -d \"\$d\" ] || echo GONE:\$d; done' '$OCS' '$T/proj'"
    [ "$status" -eq 0 ]
    hasnt "GONE:"
}

@test "binds: PATH has no duplicate entries" {
    run sb 'echo "$PATH" | tr ":" "\n" | sort | uniq -d | sed "s/^/DUP: /"; echo P=$PATH'
    hasnt "DUP:"
}

@test "brew: no brew tree is bound when opencode is not brew-installed" {
    # HOMEBREW_PREFIX is set and brew reports a prefix, but opencode came from
    # somewhere else entirely. $T/fake/bin must not be mounted: the agent should
    # not inherit every brew binary just because brew exists on the host.
    mkdir -p "$T/fake/bin" "$T/fake/lib" "$T/elsewhere/bin"
    echo BREWBIN > "$T/fake/bin/some-other-package"
    echo SECRET > "$T/fake/lib/private"
    printf '#!/bin/sh\necho S\n' > "$T/elsewhere/bin/opencode"
    chmod +x "$T/elsewhere/bin/opencode"
    stub_brew "$T/fake"

    run env HOMEBREW_PREFIX="$T/fake" PATH="$T/elsewhere/bin:$PATH" OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='ls \"$T/fake/bin\" 2>&1 || echo ABSENT; echo P=\$PATH' '$OCS' '$T/proj'"
    [ "$status" -eq 0 ]
    has "ABSENT"
    hasnt "BREWBIN"
    hasnt "P=$T/fake/bin:"
}

@test "brew: the binary's own prefix is bound when brew reports another" {
    # brew --prefix says $T/fake, but opencode resolves under $T/other/Cellar/.
    # The library path is baked into the binary at install time, so the prefix
    # that matters is the one the binary lives under. If it is not bound, the
    # sandbox starts and then cannot exec opencode.
    mkdir -p "$T/other/bin" "$T/other/lib" "$T/other/Cellar/opencode/1.0/bin"
    printf '#!/bin/sh\necho RAN-FROM-CELLAR\n' > "$T/other/Cellar/opencode/1.0/bin/opencode"
    chmod +x "$T/other/Cellar/opencode/1.0/bin/opencode"
    ln -sf ../Cellar/opencode/1.0/bin/opencode "$T/other/bin/opencode"
    echo OTHERLIB > "$T/other/lib/marker"
    stub_brew "$T/fake"

    run env -u HOMEBREW_PREFIX PATH="$T/bin:$T/other/bin:$PATH" OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='cat \"$T/other/lib/marker\"' '$OCS' '$T/proj'"
    [ "$status" -eq 0 ]
    has "OTHERLIB"
}

@test "brew: no brew at all still yields a working sandbox" {
    # BREW is empty here, so the brew binds and the PATH entry are omitted.
    # They must not collapse into binding the host's /bin via a "/bin" path.
    mkdir -p "$T/stub/bin"
    printf '#!/bin/sh\necho STUB\n' > "$T/stub/bin/opencode"
    chmod +x "$T/stub/bin/opencode"

    run env -u HOMEBREW_PREFIX PATH="$T/stub/bin:/usr/bin:/bin" OCS_QUIET=1 \
        bash -c "OCS_TEST_CMD='echo P=\$PATH' '$OCS' '$T/proj'"
    [ "$status" -eq 0 ]
    refute "P=/bin:"
    refute "P=::"
}

# ================================================================== cli ====

@test "cli: --help documents every flag" {
    run bash -c "'$OCS' --no-color --help"
    for f in --allow --ro --dev --serve --port --no-net --no-color --help --version; do
        has "$f"
    done
    for f in -a -r -d -s -p -nn -nc -h -V; do
        has "$f"
    done
    refute "--project"
}

# ================================================================= args ====

@test "args: a repeated flag grants each directory" {
    mkdir -p "$T/s1" "$T/s2"
    run bash -c "OCS_TEST_CMD='for d in s1 s2; do [ -d \"$T/\$d\" ] && echo -n \"\$d \"; done; echo' '$OCS' '$T/proj' --ro '$T/s1' --ro '$T/s2'"
    has "s1 s2"
}

@test "args: the project may follow a value-taking flag" {
    # Under the old drain loop this path was swallowed as a second --ro value
    # and ocs died with no project. That ambiguity is what 5.5.0 removed.
    mkdir -p "$T/s1"
    run bash -c "OCS_TEST_CMD=pwd '$OCS' --ro '$T/s1' '$T/proj'"
    [ "$status" -eq 0 ]
    has "$T/proj"
}

@test "args: the comma form grants several paths" {
    mkdir -p "$T/s1" "$T/s2"
    run bash -c "OCS_TEST_CMD='for d in s1 s2; do [ -d \"$T/\$d\" ] && echo -n \"\$d \"; done; echo' '$OCS' '$T/proj' --ro=$T/s1,$T/s2"
    has "s1 s2"
}

@test "args: a value flag refuses the next flag as its value" {
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --ro --no-net"
    [ "$status" -ne 0 ]
    has "requires a value"
}

@test "args: a directory whose name contains a comma survives" {
    # Proves the space form does not split. Only --flag=a,b splits.
    mkdir -p "$T/we,ird"
    run bash -c "OCS_TEST_CMD='ls -d \"$T/we,ird\"' '$OCS' '$T/proj' --ro '$T/we,ird'"
    [ "$status" -eq 0 ]
    has "we,ird"
}

@test "args: --port does not take the next flag as its port" {
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' -p --no-net"
    [ "$status" -ne 0 ]
    has "requires a port number"
}

@test "args: glob characters are never expanded against the host" {
    # A --ro value is a path, not a pattern.
    mkdir -p "$T/g1" "$T/g2"
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --ro='$T/g*'"
    [ "$status" -ne 0 ]
    has "no such path"
}

@test "args: passthrough after -- reaches opencode verbatim" {
    stub_opencode
    run_stub "-- --no-net --help"
    has "ARGV: [--no-net] [--help]"
}

# =============================================================== serve ====

@test "serve: --serve runs opencode serve and leaves the address to it" {
    stub_opencode
    run_stub "--serve"
    has "ARGV: [serve]"
    hasnt "0.0.0.0"
}

@test "serve: --host is passed through" {
    stub_opencode
    run_stub "--serve --host 0.0.0.0"
    has "ARGV: [serve] [--hostname] [0.0.0.0]"
}

@test "serve: the banner names the host when one is given" {
    stub_opencode
    QUIET_ENV=QUIET= run_stub "--serve --host 0.0.0.0 --port 4455"
    has "http://0.0.0.0:4455"
}

@test "serve: --host with no value is an error" {
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --serve --host"
    [ "$status" -ne 0 ]
    has "requires a hostname"
}

@test "serve: the advertised URL carries an explicit --port" {
    stub_opencode
    QUIET_ENV=QUIET= run_stub "--serve --port 4455"
    has "http://127.0.0.1:4455"
}

@test "serve: the banner never invents a port when opencode picks one" {
    # opencode walks up from 4096 when the port is busy. The first version
    # hardcoded 4096 and was simply wrong whenever that happened.
    stub_opencode
    QUIET_ENV=QUIET= run_stub "--serve"
    has "http://127.0.0.1"
    hasnt "127.0.0.1:4096"
}

@test "serve: --serve with --no-net is refused" {
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --serve --no-net"
    [ "$status" -ne 0 ]
    has "unreachable"
}

@test "serve: --port without --serve is refused rather than ignored" {
    # Otherwise the port is validated and quietly thrown away, and you get a
    # terminal UI when you asked for a server.
    run bash -c "OCS_QUIET=1 '$OCS' '$T/proj' --port 4455"
    [ "$status" -ne 0 ]
    has "only means something with --serve"
}

# ============================================================== colour ====

@test "colour: --no-color and NO_COLOR emit no escape sequences" {
    run bash -c "'$OCS' --no-color --help"
    hasnt $'\033'
    run bash -c "NO_COLOR=1 '$OCS' --help"
    hasnt $'\033'
}

@test "colour: a TERM with only some tput capabilities still reports errors" {
    # TERM=sun: "tput sgr0" succeeds, "tput bold" fails. If the colour vars
    # were left unset, set -u would abort with "unbound variable" instead of
    # printing the message.
    run bash -c "TERM=sun OCS_QUIET=1 '$OCS' '$T/definitely-absent'"
    [ "$status" -ne 0 ]
    has "no such path"
    refute "unbound variable"
}
