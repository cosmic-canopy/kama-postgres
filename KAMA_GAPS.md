# Gaps found in kama, from building @kama/postgres (and @kama/tls)

Found while planning the official PostgreSQL client and the TLS package it depends on (`../kama-tls`).
It is written **for the cstar project**: each entry is reduced to the smallest program or file that shows
it. Every entry with a repro was **run** on the version named. Nothing is inferred from reading the
spec. An entry that is an absence cites the cstar files that show it instead. This file is excluded from
the published package, as it is in `@kama/sodium`.

**Current compiler:** `kama 0.9.519+g28136440`, the dev build at `../cstar/out/Darwin-arm64/kama`. Every entry from
KPG-23 to KPG-30 was re-run on it, with the repro as filed, before it moved to FIXED. Earlier rounds: `0.9.506`
(KPG-11 to KPG-22 verified, KPG-23 to KPG-30 filed), `0.9.490` (KPG-15 to KPG-22 filed), `0.9.486` (KPG-11 to
KPG-14 filed), `0.9.477` (KPG-1 also on Linux aarch64 inside `localhost/kama-dev`), and the first report against
`0.9.470` and the public `0.9.440`.

**Reporter:** the `@kama/postgres` repo. Each open entry names the workaround this package uses, so the
workaround can be deleted when the gap closes. **We are not attached to any workaround.** If a fix
changes the right design here, say so and we will follow it.

**Open now:** KPG-31. Every earlier gap is fixed, except KPG-8, which is closed as a non-goal (see below).

**Priorities:**
- **HIGH:** wrong or dangerous behaviour today: a crash, or a permanent bad publish.
- **MED:** a real capability missing, with a workaround that costs something.
- **LOW:** ergonomics or docs.

---

## OPEN

### KPG-31 · LOW · `std::fs::Metadata` has no owner, so libpq's private-key rule cannot be ported whole

**Found** porting libpq's `initialize_SSL` (phase 6), on `kama 0.9.520+gca7e0d21`.

libpq refuses a client private key that others can read, with one exception for system-wide keys: a file root owns
may be mode 0640 (group-readable), any other file at most 0600. It tells them apart by `st_uid`
(src/interfaces/libpq/fe-secure-openssl.c, `buf.st_uid == 0 ? mode & (S_IWGRP | S_IXGRP | S_IRWXO) : mode &
(S_IRWXG | S_IRWXO)`). `std::fs::Metadata` has the kind, size, mtime and permission bits, but not the owner:

```kama
import { core::println, std::fs::stat, std::fs::Metadata, std::io::IoError };
fn int32 main() {
    string path = "/etc/hosts";
    Result<Metadata, IoError> m = stat(path: path);
    match (m) {
        case Ok(value: md): { uint32 owner = md.owner; println(s: "owner ${owner}"); }
        case Err(error: e): { println(s: "stat failed"); }
    };
    return 0;
}
```

`kama check owner.kama` says `` `std::fs::Metadata` has no field `owner` ``. Asked for: the owning user (and group) on
`Metadata`, from `st_uid`/`st_gid`, as a `UserId` or a raw id. `File.metadata()` should carry it too, since the key is
checked on the file it is read from.

**Workaround** (in `src/secure/setup.kama`, to delete when this is fixed): every key file gets the non-root rule,
mode 0600 or less. A root-owned key at 0640, which libpq accepts, is refused with libpq's own message. That is
stricter, never looser.

---

## FIXED — kept for the record

KPG-23 to KPG-30 were verified on 0.9.519, KPG-11 to KPG-22 on 0.9.506, KPG-4 and KPG-6 on 0.9.486. The rest were re-run on 0.9.477 with the
same repro as the original report.

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
