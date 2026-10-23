# Gaps found in kama, from building @kama/postgres (and @kama/tls)

Found while planning the official PostgreSQL client and the TLS package it depends on (`../kama-tls`).
It is written **for the cstar project**: each entry is reduced to the smallest program or file that shows
it. Every entry with a repro was **run** on the version named. Nothing is inferred from reading the
spec. An entry that is an absence cites the cstar files that show it instead. This file is excluded from
the published package, as it is in `@kama/sodium`.

**Current compiler:** `kama 0.9.690`, the release (`v0.9.690`, from GitHub, checksum verified). KPG-41 was re-run on it
and on `v0.9.679`, the first release with its fix, with the repro as filed, before it moved to FIXED. Earlier rounds:
`0.9.673` (KPG-39 and KPG-40 verified, KPG-41 filed; still failing on `0.9.675`), `0.9.667` (KPG-33 to KPG-38
verified, KPG-39 and KPG-40 filed), `0.9.523` (KPG-31 and KPG-32
verified, KPG-33 to KPG-38 filed), `0.9.519` (KPG-23 to KPG-30 verified), `0.9.506` (KPG-11 to KPG-22 verified, KPG-23
to KPG-30 filed), `0.9.490` (KPG-15 to KPG-22 filed), `0.9.486` (KPG-11 to KPG-14 filed), `0.9.477` (KPG-1 also on
Linux aarch64 inside `localhost/kama-dev`), and the first report against `0.9.470` and the public `0.9.440`.

**Reporter:** the `@kama/postgres` repo. Each open entry names the workaround this package uses, so the
workaround can be deleted when the gap closes. **We are not attached to any workaround.** If a fix
changes the right design here, say so and we will follow it.

**Windows (phase 9):** entries from KPG-42 on were run on Windows 11 x86-64 with `kama 0.9.719`, both the release with
zig bundled (`kama-windows-x64-bundled-v0.9.719.tar.gz`, checksum verified) and `../kama` built at the `v0.9.719` tag
(`2808da06`) with msys2's UCRT64 clang.

**Open now:** KPG-42 (MED), KPG-43, KPG-44 and KPG-45 (LOW). Every other gap is fixed, except KPG-8, which is closed
as a non-goal (see below).

**Priorities:**
- **HIGH:** wrong or dangerous behaviour today: a crash, or a permanent bad publish.
- **MED:** a real capability missing, with a workaround that costs something.
- **LOW:** ergonomics or docs.

---

## OPEN

### KPG-42 · MED · std has no per-user application-data folder, where libpq keeps its files on Windows — OPEN

Found in phase 9 (Windows). On Windows, libpq's "home" is the roaming application-data folder plus `/postgresql`:
`pqGetHomeDirectory` (fe-connect.c, REL_18 `c45ba888`) calls `SHGetFolderPath(NULL, CSIDL_APPDATA, NULL, 0, tmppath)`.
`pgpass.conf`, `.pg_service.conf`, `postgresql.crt`, `postgresql.key`, `root.crt` and `root.crl` all live there. libpq
never reads the `APPDATA` variable. It asks Windows, which answers from the user's profile.

std offers the profile directory (`std::process::homeDirectory()`, `UserId.homeDirectory()`) and nothing for
application data. The only way to that folder is the environment variable, which any parent process can change. The repro,
one file:

```kama
import { core::println, core::envOr, std::io::IoError, std::process::currentUser, std::process::homeDirectory, std::process::UserId };

fn uint8 main() {
    Result<string, IoError> h = homeDirectory();
    match (h) {
        case Ok(value: v): println(s: "homeDirectory():               ${v}");
        case Err(error: e): println(s: "homeDirectory() failed");
    };
    Result<UserId, IoError> u = currentUser();
    match (u) {
        case Ok(value: id): {
            UserId me = id;
            Result<string, IoError> uh = me.homeDirectory();
            match (uh) {
                case Ok(value: v): println(s: "currentUser().homeDirectory(): ${v}");
                case Err(error: e): println(s: "currentUser().homeDirectory() failed");
            };
        }
        case Err(error: e): println(s: "currentUser() failed");
    };
    string appdata = envOr(name: "APPDATA", dflt: "(unset)");
    println(s: "the APPDATA variable:          ${appdata}");
    return 0;
}
```

On both 0.9.719 builds:

```
homeDirectory():               C:\Users\Matt
currentUser().homeDirectory(): C:\Users\Matt
the APPDATA variable:          C:\Users\Matt\AppData\Roaming
```

Run again with `APPDATA='C:\elsewhere'`, the last line follows the variable: `C:\elsewhere`. Windows' own answer does
not. With the variable changed the same way, `powershell -Command "[Environment]::GetFolderPath('ApplicationData')"`
still prints `C:\Users\Matt\AppData\Roaming`.

**What other languages give:**
- .NET: `Environment.GetFolderPath(SpecialFolder.ApplicationData)`, which asks the shell.
- Rust's `dirs` crate: `config_dir()`, which is `SHGetKnownFolderPath(FOLDERID_RoamingAppData)` on Windows.
- Go: `os.UserConfigDir()`, which reads `%AppData%`.

On macOS and Linux the same call names `~/Library/Application Support` and `$XDG_CONFIG_HOME` (else `~/.config`), so
it fits beside `homeDirectory()` as a cross-platform function. What this package needs is the Windows answer:
`FOLDERID_RoamingAppData`, which is `CSIDL_APPDATA`.

**The workaround:** `homeFrom`'s Windows twin in `src/config.kama` reads `APPDATA` from the captured `Environment`, as
Go does. It differs from libpq only when the variable is unset, empty or changed. Once std has the call,
`Environment.process()` captures the folder as it captures the account's home on Unix (`accountHomeDirectory`). A test
can then still set it, and `homeFrom` stops reading the variable.

**Why MED:** a real capability is missing, and the workaround costs fidelity, not function. A client launched with a
changed `APPDATA` (some service managers and sandboxes do this) looks for `pgpass.conf` and its certificates somewhere
psql would not.

### KPG-43 · LOW · `parse::<float64>("NaN")` gives a different NaN on Windows — OPEN

Found in phase 9's first unit run on Windows. The codec cases `float4 'NaN'` and `float8 'NaN'` failed: "text and
binary differ in bits". The binary vector is PostgreSQL's NaN, `7ff8000000000000`, and the text `NaN` read through
std's `parse` came back with other bits. These cases pass on Linux and macOS in CI.

std's float parse is `strtod`/`strtof` (`lib/std/fmt/parse.kama`, `kama_parse_f64_ck` in `include/kama_fmt.h`). The C
library chooses the NaN, and UCRT's is not glibc's. The repro, one file:

```kama
import { core::println, std::fmt::parse, std::fmt::ParseError };

fn uint8 main() {
    Result<float64, ParseError> d = parse::<float64>(s: "NaN");
    float64 x = match (d) { case Ok(value: v): v; case Err(error: e): 0.0; };
    uint64 bits = bitcast<uint64>(x);
    println(s: "parse::<float64>(\"NaN\") bits: ${bits:016x}");
    Result<float32, ParseError> f = parse::<float32>(s: "NaN");
    float32 y = match (f) { case Ok(value: v): v; case Err(error: e): 0.0; };
    uint32 fbits = bitcast<uint32>(y);
    println(s: "parse::<float32>(\"NaN\") bits: ${fbits:08x}");
    float64 z = cast<float64>(0) / cast<float64>(0);
    uint64 zbits = bitcast<uint64>(z);
    println(s: "0.0 / 0.0 at run time bits:  ${zbits:016x}");
    return 0;
}
```

On both 0.9.719 builds:

```
parse::<float64>("NaN") bits: 7fffffffffffffff
parse::<float32>("NaN") bits: 7fffffff
0.0 / 0.0 at run time bits:  fff8000000000000
```

With glibc, `strtod("NaN")` is `7ff8000000000000`, the canonical quiet NaN that Rust's `f64::NAN` is too. Rust
parses the spelling itself, so `"NaN".parse::<f64>()` gives those bits on every platform. The third line is the
processor's own default NaN, sign set, for comparison; nothing here depends on it. A server's own NaN follows its C
library the same way: a PostgreSQL 18.6 built with glibc sends `float8send('NaN')` as `7ff8000000000000`, and EDB's
Windows build sends `7fffffffffffffff`.

**The ask:** the spellings `kama__float_spelling` admits for NaN read as the canonical quiet NaN (`7ff8000000000000`,
`7fc00000`) on every target, so a parse means the same bits everywhere, as an integer parse does.

**The workaround:** `floatText` in `src/types/codec.kama` turns any NaN that `parse` returns into the canonical
`7ff8000000000000`. A NaN read as text then has the same bits wherever the client runs, which is what this package's
codec vectors (from a glibc server) assert. Delete it when `parse` does this itself.

**Why LOW:** a NaN is a NaN to every comparison, and PostgreSQL's too.

### KPG-44 · LOW · A Unix-socket connect to a path with no socket reports a Win32 code that Windows did not give — OPEN

Found in phase 9's Windows cases (`tests/integration/src/windows_test.kama`), against the psql of EDB's PostgreSQL 18.6
for Windows. On Windows, connecting to an AF_UNIX path with no socket file answers `WSAECONNREFUSED`. std looks at the
path (`kama__connect_fail` in `include/kama_os.h`) and reports a missing file as NotFound, which is right for the kind.
But it also replaces the code: `rawOsError()` becomes `ERROR_FILE_NOT_FOUND` (2), which no call returned. libpq prints
Winsock's answer, `Connection refused (0x0000274D/10061)`, and a client that words errors as libpq does needs the code
Windows gave.

The repro, one file, run with `KPG_DIR` set to an empty directory, then to one that is not there:

```kama
import { core::println, core::envOr, std::io::IoError, std::net::UnixStream };

fn uint8 main() {
    string dir = envOr(name: "KPG_DIR", dflt: "");
    string path = dir.concat(other: "/.s.PGSQL.5432");
    Result<UnixStream, IoError> r = UnixStream.connect(path: path);
    match (r) {
        case Ok(value: s): println(s: "connected?");
        case Err(error: e): {
            Optional<int32> raw = e.rawOsError();
            int32 code = match (raw) { case Some(value: c): c; case None: 0; };
            Optional<string> words = e.osMessage();
            string w = match (give words) { case Some(value: x): give x; case None: "(none)"; };
            string m = e.message();
            println(s: "message: ${m}");
            println(s: "rawOsError: ${code}");
            println(s: "osMessage: ${w}");
        }
    };
    return 0;
}
```

On 0.9.719 (`../kama` at the tag, msys2 clang), Windows 11 26200:

```
message: not found (os error 2: The system cannot find the file specified)
rawOsError: 2
osMessage: The system cannot find the file specified
--- a directory that is not there:
message: i/o error (os error 10050: A socket operation encountered a dead network)
rawOsError: 10050
osMessage: A socket operation encountered a dead network
```

The second run shows the other half: a directory that is not there answers `WSAENETDOWN`, which std passes through
with its code but as the kind Other, though on POSIX both cases are ENOENT.

**The ask:** keep the code the operating system gave in `rawOsError()` (10061 for the first, 10050 for the second),
whatever kind std classifies the failure as, as Rust's `io::Error` keeps `raw_os_error` apart from `kind`. The two
could then share the kind NotFound.

**The workaround:** none in the source. `windows_test.kama` checks the case's lead and hint, and not its words, naming
this entry. Delete that when this is fixed: the generated case then passes as it is.

**Why LOW:** the connect fails, and the next host is tried, as libpq tries it. Only the words differ.

### KPG-45 · LOW · `UnixAddr.fromAbstract` does not exist on Windows, so a client cannot let Winsock refuse the name — OPEN

Found beside KPG-44. libpq takes a host that starts with `@` as an abstract Unix-socket name on every platform, and
PostgreSQL's documentation lists Windows as supporting it. Asked on Windows 11 26200, EDB 18.6's psql tried to connect,
and Winsock refused the address: `connection to server on socket "@kpg_none/.s.PGSQL.5432" failed: Invalid argument
(0x00002726/10022)`. std offers `UnixAddr.fromAbstract` on Linux alone. So on Windows this client refuses the name
itself, with no OS code, and can only say "invalid input".

```kama
import { core::println, std::io::IoError, std::net::UnixAddr, std::net::UnixStream };

fn uint8 main() {
    Result<UnixAddr, IoError> a = UnixAddr.fromAbstract(name: "kpg_none/.s.PGSQL.5432");
    match (a) {
        case Ok(value: where): println(s: "an abstract address");
        case Err(error: e): println(s: "refused");
    };
    return 0;
}
```

`kama check abstract.kama --target LINUX` is OK. On Windows (0.9.719): `error: type UnixAddr has no constructor
fromAbstract`.

**The ask:** either `fromAbstract` on Windows too, leaving the refusal to Winsock (a later Windows that supports
abstract names would then just work); or a documented error from it there that carries `WSAEINVAL`, which is what
Windows answers today.

**The workaround:** none in the source. `transport.kama` refuses `@name` off Linux with `InvalidInput`, and
`windows_test.kama` checks the case's lead and hint, naming this entry.

**Why LOW:** no Windows server listens on an abstract name. The connect fails, and the next host is tried. The bits show only through `bitcast`, or when the
value goes back to a server in binary. But kama's promise is the same program behaving the same on every target, and
this is a case where it does not.

## FIXED — kept for the record

KPG-41 was verified on 0.9.679 and 0.9.690. KPG-39 and KPG-40 were verified on 0.9.673. KPG-33 to KPG-38 were verified on 0.9.667. KPG-31 and KPG-32 were verified on 0.9.523, the first release with their fixes. KPG-23 to KPG-30 were verified on 0.9.519, KPG-11 to KPG-22 on 0.9.506, KPG-4 and KPG-6 on 0.9.486. The rest were re-run on 0.9.477 with the
same repro as the original report.

### KPG-41 · HIGH · On macOS, a release build that uses `std::process::Command` beside `std::concurrent` fails in the C compiler — FIXED in 0.9.679

Fixed in cstar's 0.9.677 (`fce00971`), first released in v0.9.679: `kama_os.h`'s `read`, `write` and `close` carry
macOS's asm label, as `pread`/`pwrite` already did, so `<unistd.h>` may follow it. Verified with the repro below (checksums
checked):
- on v0.9.679, as filed: `kama build c3.kama --release` builds, and the program prints `made`;
- on v0.9.690, with `fn uint8 main()` (0.9.684 refuses `fn int32 main()`): the same, and so does the `Channel` variant
  (a channel made and its sender taken, beside the `Command`), in release and in debug.

The workaround is deleted: `restart_test.kama` is no longer `@compileFor(!RELEASE)`, `restart_release.kama` is gone,
and `tools/test-integration.sh` runs the restart leg in release. The pool (`postgres::pool`, on `std::concurrent`) and
`std::process` now build together for release on macOS.

The report as filed:

Found in phase 8 (S2c), when the integration test program began to restart its server through `std::process::Command`
(it already spawns isolates). The debug build is fine; the release build stops in clang:

```
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/unistd.h:449:6: error: cannot apply asm label to function after its first use
  449 | int      close(int) __DARWIN_ALIAS_C(close);
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/unistd.h:484:10: error: cannot apply asm label to function after its first use
  484 | ssize_t  read(int, void *_LIBC_SIZE(__nbyte), size_t __nbyte) __DARWIN_ALIAS_C(read);
2 errors generated.
kama: clang failed (exit 1)
```

Reduced, one file, `kama 0.9.673` (the release), macOS arm64. Nothing is spawned and the Command is never run; the
import of `Isolate` is enough:

```kama
import { core::println, std::process::Command, std::concurrent::Isolate };

fn int32 main() {
    Command c = Command.make(program: "true");
    println(s: "made");
    return 0;
}
```

- `kama build c3.kama` builds and runs. `kama build c3.kama --release` fails as above, on `v0.9.673` and on `v0.9.675`.
- The same file without the `Isolate` import builds in release. So does a program that spawns an isolate and makes no
  `Command`.
- A `Channel` in place of the `Isolate` fails the same way: `std::concurrent::Channel` and `Sender`, a channel made and
  its sender taken, beside the `Command`.
- With `--keep-c`, a failing release unit has `#include "kama_os.h"` in its prologue (line 8 of the unit for a program
  that also spawns), ahead of `#include "kama_isolate.h"`. Without the `Command`, `kama_os.h` comes after
  `kama_isolate.h`, as it does in this package's integration program at 47cf3d4, which builds.
- In C alone, `#include "kama_runtime.h"`, `#include "kama_os.h"`, `#include "kama_isolate.h"` in that order fails the
  same way. `kama_os.h` declares `read` and `close` itself, without macOS's asm label (its comment, at "NOT
  <unistd.h>", explains why), and its inline functions use them. `kama_isolate.h` then includes `<unistd.h>` for
  `sysconf`, whose declarations carry `__DARWIN_ALIAS_C`. The opposite order compiles.

So it looks as if something in `std::process` moves `kama_os.h` into the release unit's prologue, ahead of
`kama_isolate.h`. Two ways out suggest themselves: `kama_isolate.h` could declare `sysconf` itself instead of including
`<unistd.h>`, as `kama_os.h` does for the rest, or the prologue's headers could keep the order the chunks would give.

**Why HIGH:** a program that starts a process and uses a channel or an isolate cannot be built for release on macOS. A
server that runs a helper and keeps a pool of workers is that program. This package's next step is a connection pool,
built on `std::concurrent`'s `Channel` and a maintenance isolate, so once it lands, an application on macOS that uses the
pool and starts a process will not build for release, through no fault of its own.

**The workaround, deleted on 0.9.690:** `tests/integration/src/restart_test.kama` is
`file @compileFor(!RELEASE);`, and `main` runs it through a `@compileFor(!RELEASE)` function (its release twin says the
group needs a debug build). `tools/test-integration.sh` runs the restart leg with the debug build. Once fixed: drop the
gate and the twin, and run the leg in release like the TLS one.

### KPG-40 · LOW · Is a window inside a window, through a view's `ref` accessor, intended? — ANSWERED: yes; its defect FIXED in 0.9.673

**cstar's answer:** intended. `borrow tx.conn().transaction() as inner` stays, and there is no mint on the view
(`@viewable … for view`), which would be a second spelling of the same nesting.
- Opening a window through the enclosing window's alias is a reborrow, not a second name for the storage. The inner
  window freezes `tx` for its block, so only one of `tx` and `inner` is usable at a time, and the windows close inside
  out.
- What SPEC refuses (`xfail/borrow_nested_same_place`) is a second window from the same root, where both names stay
  live: `borrow c.transaction() as t2` inside `tx` is refused ("two mutable views of one buffer").

**The defect it turned up, fixed in the 0.9.673 release** (cstar's 0.9.672; no 0.9.672 was tagged).
- On 0.9.667 to 0.9.671 the inner window did not freeze `tx`, so `tx.conn().leave()` inside the savepoint was accepted,
  and the outer transaction could be committed from inside it. More widely, a window minted on a call that returns a
  place froze nothing: `borrow h.items().viewMut() as v { h.items().add(…); }` was a use-after-free in safe code.
- Verified on v0.9.673 (checksum checked):
  - The repro below, as filed, builds and prints `2 0`.
  - The same program with `tx.conn().leave();` inside `inner` is refused: "`tx` is frozen by the enclosing `borrow`
    (opened at line 20 as `inner`)". 0.9.667 checks it clean.
  - This package checks and passes its tests unchanged on it. Nothing here used `tx` inside an inner window.
- Here the hole could not corrupt a session. A COMMIT or ROLLBACK through `tx` inside `inner` ends the block, which the
  server reports, so both windows find their transaction over and send nothing. The package now needs 0.9.673, so the
  compiler refuses it outright.

The question as filed:

**A question, not a bug.** @kama/postgres 0.3.0's API relies on the answer being yes, so we ask before it ships. The
scoped transaction nests as a savepoint by opening a second window over the same connection, reached through the first
view: `borrow tx.conn().transaction() as inner { … }`. kama 0.9.667 accepts it and runs it, both destructors in order.
SPEC.md's borrow rules (around line 412) say "a window inside a window over the same storage" is refused
(`xfail/borrow_nested_same_place`). The checker cannot see through `conn()`'s `UnsafePtr`, so this may be accepted by
accident.

Reduced, with no package. On 0.9.667 this checks and prints `2 0`:

```kama
import { core::println };
@viewable type contract Transacts for resource { fn Tx transaction(); }
type view Tx {
    UnsafePtr<Conn> c;
    unsafe ctor over(UnsafePtr<Conn> c) { this.c = c; }
    public unsafe fn ref Conn conn() { return this.c[0]; }
    unsafe ~Tx() { this.c[0].leave(); }
}
type resource Conn implements Transacts {
    int32 open = 0;
    public ctor make() { this.open = 0; }
    public unsafe fn Tx transaction() { this.open = this.open + 1; return Tx.over(c: addr(of: this)); }
    public fn void leave() { this.open = this.open - 1; }
    public const fn int32 depth() { return this.open; }
}
fn int32 main() {
    Conn c = Conn.make();
    int32 inside = 0;
    borrow c.transaction() as tx {
        borrow tx.conn().transaction() as inner { inside = inner.conn().depth(); }   // a second window over `c`
    }
    int32 after = c.depth();
    println(s: "${inside} ${after}");
    return 0;
}
```

- **Why we think it is sound here:** the view owns no storage that could move. The inner window freezes the alias
  `tx` (a place-returning call's receiver), so the outer transaction cannot be committed from inside the savepoint.
  (Wrong before 0.9.673: see the defect above.)
- **If it should be refused,** the alternative we would follow is a mint on the view itself (a `@viewable` contract
  `for view`), so nesting reads `borrow tx.transaction() as inner`. Say which, and we will change before 0.3.0.
  (cstar: do not.)

### KPG-39 · HIGH · Importing std's JSON made `Optional<int64>` (and `uint64`, `float64`) not `Sendable` — FIXED in 0.9.673

Fixed in cstar's 0.9.669, first released in v0.9.673: "a generic instance named by an imported module … is judged
against every conformance". Verified on v0.9.673 (checksum checked):
- The repro below (the `Chunk` enum, with the `JsonNumber` import) builds. A `Sendable` resource holding
  `Optional<int64>`, `Optional<uint64>` and `Optional<float64>` builds too.
- On 0.9.667 the enum still fails, with the error quoted below.
- `tests/unit/src/typed_test.kama` imports std's `JsonValue` and reads a column and a whole row into it
  (`jsonValueTests`). On 0.9.667 that program fails to build, at `CopyChunk`; on 0.9.673 it passes. The README's known
  issue is gone.

**As filed,** porting to `kama 0.9.667`: a unit test that read a column into a `std::serialization::text::json::JsonValue`
made the whole test program fail, in a file the test does not touch:

```
src/copy.kama:29:0: error: `postgres::CopyChunk` declares `implements Sendable`, but its variant `Done` payload `rows`
(of type `Optional<int64>`) is not Sendable — `Optional<int64>` does not declare `implements Sendable`
```

Reduced, with no package. This checks:

```kama
type enum Chunk implements Sendable { Data(int32 n), Done(Optional<int64> rows) }
fn int32 main() { Chunk c = Chunk::Done(rows: Optional::Some(value: 3i64)); return 0; }
```

The same file with one import above it fails `kama check` (and `kama build`) with the error above:

```kama
import { std::serialization::text::json::JsonNumber };
```

- A field fails the same way: `type resource Holder implements Sendable { Optional<int64> rows; … }`.
- `Optional<uint64>` and `Optional<float64>` fail too.
- `Optional<int32>`, `Optional<bool>` and `Optional<string>` still check.

Those three are the types `JsonNumber`'s `asInt64`, `asUint64` and `asFloat64` return. So it looks as if their first
instance, made in json.kama, is kept without `Optional`'s conditional `Sendable`. KPG-30, fixed in 0.9.514, was a
conditional conformance that depended on imports.

**Why HIGH:** an application that uses std's JSON and `@kama/postgres` does not compile, because `CopyChunk` holds an
`Optional<int64>`. No code in the application is wrong.

### KPG-38 · HIGH · Two files that use the same `type adapter` failed every release build — FIXED in 0.9.543

Fixed by `7872c6b6` (KR-114): a helper two modules need (an intrinsic target's contract vtable and its thunks, an
isolate trampoline) is defined once in the one-unit release build. The repro (`Shown` passed an `int32` from `a.kama`
and `b.kama`) prints `14 16` built `--release` on 0.9.667, as it does `--debug`. The workaround's comments are gone,
and `tests/unit/src/cache_test.kama` passes an `int32` itself, so the suite's own release build would catch a return.

### KPG-37 · HIGH · A lock stopped installing when a newer version was published, with a path dependency — FIXED in 0.9.525

Fixed by `df6a7bc3` (KB-39): a locked version that a second range still admits is kept, not re-resolved forever. The
repro, run as filed against a `file://` registry on 0.9.667, installs after `@x/leaf` 0.1.1 is published, and the
lock still pins 0.1.0.

### KPG-33 · HIGH · A parent could use a place its `scope`'s spawned child borrows by `ref` — FIXED in 0.9.551

Fixed by `ce7fc913` (KR-112). The repro is refused on 0.9.667: "`c` is held by `ref` by the child `spawn`ed at line 18
until this `scope` joins it — using it here, read or write, races with the child."

### KPG-34 · HIGH · A `return` in a destructor body skipped the fields' destructors — FIXED in 0.9.544

Fixed by `09649780` (KR-113): a `return` in a destructor ends its body, and the fields are still dropped. The repro
prints `Inner dropped` for both `a` and `b` on 0.9.667.

### KPG-35 · MED · A borrow window could not run code when it ended (a scoped transaction) — FIXED in 0.9.658

Fixed by `941d40cb` (KR-124): a `type view` may declare `~dtor`, and the `borrow` that minted it runs it when the
window closes, on every path out of the block (its end, `return`, `break`, `continue`), after the block's locals. The
repro checks on 0.9.667, and kama's `tests/borrow_view_closes.kama` (a transaction that rolls back unless it committed)
exits 42 on it. Phase 8 adopts it: `borrow conn.transaction() as tx { … }`.

### KPG-36 · LOW · `docs/TYPE_MODEL.md` showed a `ref` field, which does not parse — FIXED in 0.9.557

Fixed by `a103caf9` (KR-119): the example's view holds `UnsafePtr<World> world`.

### KPG-32 · HIGH · `break` in a `match` arm did not leave the enclosing loop — FIXED in 0.9.521

Fixed by `c34f9082`: a `break` in a `match` arm leaves the loop, and kama judges where a jump may go. The repro prints
`left the loop after 3 turns` and exits 0 on 0.9.523 (it printed `break did not leave the loop: 11 turns`). The flag
in `tests/integration/src/tls_test.kama` (`fails`) is gone.

### KPG-31 · LOW · `std::fs::Metadata` had no owner, so libpq's private-key rule could not be ported whole — FIXED in 0.9.522

Fixed by `fc170153`: `Metadata.owner` and `group`, from the same stat as `permissions` (`UserId`/`GroupId`; `Optional`
on Windows). The repro, with `md.owner.raw()`, prints `owner 0` for `/etc/hosts`, as `stat` does. `src/secure/setup.kama`
now applies libpq's whole rule: at most 0600, or 0640 when root owns the key.

### KPG-29 · HIGH · Matching on a method's `const ref` result destroyed the referent — FIXED in 0.9.508

Fixed by `36c044b8`: a place-returning call subject is borrowed, never copied and dropped. The repro prints
`hello hello` and exits 0 (it was 133). The row reader keeps its one list of columns and elements, matched by
index, because that is simpler, not because of the gap.

### KPG-25 · HIGH · A string tag's holes lost their type — FIXED in 0.9.512

Fixed by `951e7f77`: typed holes. A tag takes `Template<C>`, and each hole is checked against the contract `C`
where the string is written. std's `sql` binds `SqlValue`s, and the repro's empty `Optional` is
`SqlValue::Null`. `postgres::pg` takes `Template<PgParam>`, a contract this package declares, with `type adapter`s
for the primitives, `DynamicArray`, `Optional`, std's `Uuid`, `Timestamp` and `Date`, and its own types. An empty
Optional hole is NULL, and bytes are bytea. The refusal of Optional-shaped text holes is gone. `Query.add` takes a
`PgParam` too, so `addOptional` and `addText` are gone.

### KPG-30 · MED · A conditional conformance depended on imports, and a generic site got no vtable — FIXED in 0.9.514

Fixed by `97beca1f`. Both repros build and run: `DynamicArray<int32>` handed to a `Serializable` parameter with no
serialization import, and `put::<DynamicArray<Uuid>>` from a generic function. `types_test` sends arrays and bytea
back through its one generic round trip again.

### KPG-24 · MED · A `comptime InlineArray` imported from another file lost its type — FIXED in 0.9.515

Fixed by `91c5ef56`. The repro (`RANGES[3]` and `RANGES.view()` in another file) prints `8203 4`. The generated
stringprep tables keep their search beside them, which is the module's shape anyway.

### KPG-26 · MED · `@generate(Deserializable)` never reported a missing field — FIXED in 0.9.516

Fixed by `43da10f4`: a field the data leaves out is `Err(MissingField)` unless it is `Optional` (then `None`),
`@deprecated`, or the new `@field(default)` (then its declared value). The repro prints `missing field`. The row
reader's own count of fields read is gone. It would have refused a row that leaves out an Optional or
`@field(default)` column, which serde allows. `rowAs` now reports the derive's verdict.

### KPG-27 · LOW · A float printed with 17 significant digits — FIXED in 0.9.517

Fixed by `905436d7`: the shortest round-trip decimal. The repro prints `0.1 0.30000000000000004 0.3`. Every binary
float codec vector now reads as exactly the server's text, `1e+100` and `5e-324` included, so the tests compare
floats exactly.

### KPG-28 · LOW · A `friend` grant to a generic free function was refused until instantiated — FIXED in 0.9.518

Fixed by `c98b33ac`. The repro checks clean. The typed readers keep their non-generic `valueReader`/`rowReader`,
which keeps each instantiation small.

### KPG-23 · LOW · `IoError` gave the OS's words only inside its message — FIXED in 0.9.519

Fixed by `28136440`: `IoError.osMessage()`. The repro prints `Connection refused`. A failed connect, a failed
socket option, a user lookup and a peer-credentials refusal now read exactly as libpq's do, with strerror's words,
and the integration tests compare them exactly again.

### KPG-11 · MED · A generic-inference error was reported against the wrong file — FIXED in 0.9.493

Fixed by `31c1a943`. The repro as filed now checks clean, because KPG-12's fix lets that call infer. An
inference failure that remains (`pick(a: t, b: n)` with a `float64` and an `int32`, in the same submodule file) is
reported as `src/sub/broken.kama:3:0: error: cannot unify type parameter 'T'` by `kama check`. `kama query kama.json
src/sub/broken.kama --diagnostics` reports it too, and the root file reports nothing.

### KPG-12 · LOW · A generic call could not take another generic call's result — FIXED in 0.9.497

Fixed by `3af6dc0e`. `abs(x: sin(x: t))` builds and runs, and `postgres::protocol`'s MD5 table is written that way again.

### KPG-13 · MED · `parse::<float64>` refused a subnormal — FIXED in 0.9.499

Fixed by `f4a84e46`: only an overflow is out of range. The repro prints `5e-324: ok; DBL_MIN: ok; 1e-310: ok`. The
`strtod` extern in `src/types/codec.kama` is gone, and the codec vectors (with `5e-324`) pass.

### KPG-14 · LOW · A `comptime int64` at int64's minimum was an out-of-range C literal — FIXED in 0.9.492

Fixed by `312c8c34`. The repro builds with no warning. `src/types/datetime.kama`'s `timestampBegin()` is the
`comptime` `TIMESTAMP_BEGIN` again.

### KPG-15 · MED · std had no Unicode normalization, so SASLprep could not be done right — FIXED in 0.9.506

Fixed by `da28a2a2`: `std::unicode::normalize`, NFC/NFD/NFKC/NFKD from UCD 18.0.0. `postgres::protocol::saslPrep`
is now PostgreSQL's `pg_saslprep`, step for step: mapping, NFKC, prohibited output and the bidi rule, with the
stringprep tables generated from the pinned `saslprep.c` (`tools/gen-saslprep.sh`). The differences between Unicode
versions cannot matter. Stringprep's tables are Unicode 3.2, and a code point assigned later is "unassigned", which
is prohibited, so the password is used as given on both sides.

It is tested against:
- the 128 outcomes of PostgreSQL's own `test_saslprep` module;
- 32 SCRAM verifiers a live server stored for passwords that exercise each step;
- an integration role, `kp_saslprep`, whose password SASLprep changes. It logs in on 14 to 19.

### KPG-16 · LOW · No home-directory lookup in std — FIXED in 0.9.504

Fixed by `67b7d03c`: `UserId.homeDirectory()`. With `HOME` unset or empty, `Environment` falls back to the passwd
entry's home, as libpq's `pqGetHomeDirectory` does. `process()` captures it, and a test can set it
(`setAccountHome`).

### KPG-17 · MED · An interrupted system call was `IoError::Other(4)` — FIXED in 0.9.502

Fixed by `176aca2f`: `IoErrorKind::Interrupted`, and `Poller.wait` waits out a signal with the time left. `Wire`
retries a read or write that reports `Interrupted`.

### KPG-18 · LOW · `Metadata` had no file type, and an open `File` no metadata — FIXED in 0.9.505

Fixed by `1d11fb05`: `FileKind` on `Metadata`, and `File.metadata()` through the descriptor. The password file is
checked as libpq checks it, on the file it opened: one that is not a regular file is "not a plain file", for
`/dev/null` and a FIFO too, and only then is it checked for group or world access.

### KPG-19 · MED · A field default naming an enum variant broke in a std generic — FIXED in 0.9.494

Fixed by `af43308e`, with `f7629f7c`. The repro builds and prints `ok`.

### KPG-20 · MED · `kama check` accepted `Optional<E> x = <an E>` — FIXED in 0.9.496

Fixed by `5f4ca87a`. The repro is refused by `kama check`: "a local is declared `Optional<Step>`, and a `Step` is
not one — wrap it: `Optional::Some(value: …)`".

### KPG-21 · LOW · `UnixStream` had no non-blocking connect — FIXED in 0.9.500

Fixed by `fb13db8f`. `UnixTransport.connect` is non-blocking, and connect_timeout bounds it. A full listen queue
fails that host at once, as it does in libpq (EAGAIN on Linux, ECONNREFUSED on macOS). The socket integration
tests pass on 14 to 19.

### KPG-22 · LOW · `IoError` carried no operating-system text — FIXED in 0.9.502

Fixed by `176aca2f` (and `a412ce0a` for wasm): `IoError` is a kind and the OS's code, and `message()` quotes the
OS's words. KPG-23 added those words alone.

### KPG-4 · MED · No Unix-domain sockets — FIXED in 0.9.483 (KR-104)

Fixed by `b8cbc5ff` (`std::net::UnixStream` / `UnixListener`, peer credentials, and
`std::process::currentUser`), extended by `7792cf26` (Unix datagrams, Linux abstract names) and
`d2e0e477` (an owned `Descriptor`, fd passing).

Run here on macOS arm64: a `UnixListener.bind` + `UnixStream.connect` + `accept` round trip carried 15
bytes, `peerCredentials()` returned `Ok`, and the socket file was removed when the listener dropped.
A path over `sun_path` (103 bytes on macOS) is `InvalidInput` before the OS is asked, as documented, so
the test harness keeps socket paths short. `std::process::currentUser().name()` returned the same name
as `id -un`, which is how this package fills libpq's default `user`.

The planned `csrc/kpg_net.c` shim is not written, and `@kama/postgres` now needs **no C at all**.

### KPG-6 · MED · Missing TCP socket options — FIXED in 0.9.482 (KR-105)

Fixed by `d166b854`: `TcpStream.setKeepAlive`, `setKeepAliveIdle`, `setKeepAliveInterval`,
`setKeepAliveCount`, `setUserTimeout`, `shutdown(how: Shutdown)`, and `localAddr()` / `peerAddr()`.

Run here on macOS arm64: all six option calls returned `Ok` on a connected stream, and a
`TcpListener.bind(port: 0)` reported its ephemeral port through `localAddr()`. libpq's `keepalives*` and
`tcp_user_timeout` settings map one-to-one.

### KPG-1 · HIGH · A write to a closed TCP peer killed the process with SIGPIPE — FIXED in 0.9.471

Fixed by `df68d3ae`: `MSG_NOSIGNAL` on every send, plus `SO_NOSIGPIPE` on every socket kama makes or
accepts on Apple. It is guarded by `tests/net_write_closed_peer.kama` and `tools/check-sigpipe.sh`.

The repro now prints `write 0: ok`, `write 1: Err(broken pipe)` and exits 0, on macOS arm64 and on
Linux aarch64. It used to die with exit 141. `PgSocket`'s planned no-SIGPIPE send is no longer needed.

### KPG-2 · HIGH · `kama publish` accepted a path dependency — FIXED in 0.9.472

Fixed by `0d4af41f`. The same library is now refused before anything is written:

```
kama publish: dependency 'depa' is a `path` dependency ("../dep") — a published package is fetched without
that directory, so no consumer could install it, and a published version is permanent. …
```

`tools/prepublish.sh` keeps its path-dependency check only as a belt-and-braces guard for older
compilers.

### KPG-3 · MED · `TcpStream` was not `Sendable` — FIXED in 0.9.474

Fixed by `8cedc838` ("std's I/O types are Sendable"). Both repros (`Channel<TcpStream>`, and a
`Sendable` type owning a `TcpStream`) now `kama check` clean. It was also run end to end: a connected
server-side `TcpStream` was sent over a `Channel<TcpStream>` to a `spawn`ed isolate, which wrote 26
bytes that the client read. With KPG-5, a **cross-isolate pool is now possible**, and this package will
build one instead of the per-isolate pool.

### KPG-5 · MED · `Receiver` had only a blocking `recv()` — FIXED in 0.9.475 (+ 0.9.477)

Fixed by `88a52233` (`tryRecv`, `recvTimeout` returning `RecvResult { Received, Empty, Closed }`), with
`4ac90040` making timed receive build on wasm.

Run on an empty channel: `tryRecv` gives `Empty`, and `recvTimeout(150 ms)` gives `Empty` after
154 ms on the monotonic clock. After a `send`, `recvTimeout` gives `Received(7)`. A pool's
`acquire(timeout:)` can now wait to a deadline instead of failing fast. Mutex/Condvar are still absent,
but the pool no longer needs them: the idle-connection queue is the channel.

### KPG-7 · MED · `cflags` went through a shell — FIXED in 0.9.473

Fixed by `6c748ee7` ("each manifest flag is one compiler argument, exactly as written, on every host").
The repro with the plain spelling `"-DCFQ_CONFIG_FILE=\"cfq_config.h\""` now builds and runs (exit 7).
`@kama/tls` can therefore select its configuration the upstream way, with `MBEDTLS_CONFIG_FILE` and
`TF_PSA_CRYPTO_CONFIG_FILE`, and keep `third_party/` byte-identical to the release.

### KPG-9 · LOW · HMAC and PBKDF2 were not in `std::digest` — FIXED in 0.9.476

Fixed by `36e827de`: `std::digest::{Hmac, pbkdf2, BlockDigest}`, `sha256::hmacSha256`, and SHA-512,
guarded by `tests/digest_scram_rfc7677.kama`.

Cross-checked against OpenSSL 3 here:
- `hmacSha256("Jefe", "what do ya want for nothing?")` gives `5bdcc146…64ec3843`.
- `pbkdf2(Sha256, "pencil", "kama-postgres-salt", 4096, 32 bytes)` gives `71ee0978…ddb80a25`.

Both are identical to `openssl dgst -mac HMAC` / `openssl kdf … PBKDF2`. `postgres::auth` uses std for
SCRAM and keeps only MD5, for the deprecated `md5` method, which does not belong in std.

### KPG-10 · LOW · `SPEC.md` said TLS was `@kama/sodium`'s job — FIXED

Fixed by `3a73000d`. `docs/SPEC.md:2367-2368` now reads "TLS is a package too, and a different one —
libsodium has no TLS: a C TLS stack behind a `ReliableStream` wrapper…", and
`WEB_FRAMEWORK_READINESS.md` matches.

---

## CLOSED — upstream decision

### KPG-8 · LOW · No generic methods, so `row.get::<T>(…)` cannot be written — NON-GOAL

**Status:** closed by cstar (`98338df7`): generic methods stay a non-goal. `column::<T>(row:, index:)` is
the idiom, because a method form beside it would be two ways to do one thing. It still parses as an
error on 0.9.477 (`unexpected <, expecting (`), as intended. This package's public API is the free
functions `column::<T>(rows:, row:, index:)`, `columnOpt::<T>(…)` and `rowAs::<T>(rows:, row:)`, bounded on
std's `Deserializable`. That is the design, not a workaround, so there is nothing to remove later.

---

## Checked and NOT a gap

Recorded so nobody re-opens them.

- **A path dependency beneath a fetched package is refused at install.** This is correct, and the
  message says exactly why ("a fetched package cannot reference a local path reproducibly"). Run on
  0.9.470 as part of KPG-2's repro. Publish now refuses it too.
- **The Linux dev binary `out/Linux-aarch64/kama` is mode 0600** (seen on every build checked: 0.9.470,
  0.9.477 and 0.9.486). This isn't a language gap, but `kama-sodium/tools/test-wasm.sh` uses that path by default,
  so it cannot run it as-is. We copy it and `chmod` it inside the container.
- **A package cannot add a contract to a type it does not own** (e.g. `type intrinsic <Uuid> implements
  PgDecode<This>` is a parse error). This is by design: `docs/SPEC.md:4582` records that retroactive
  `implements C for T` is gone from the language, and `type intrinsic` covers only primitives. It means
  `column::<std::uuid::Uuid>` cannot come from a package contract. This package reaches std types
  through the contract they already share, `Deserializable`, instead. Probed on 0.9.486.
