# Gaps found in kama, from building @kama/postgres (and @kama/tls)

Found while planning the official PostgreSQL client and the TLS package it depends on (`../kama-tls`).
It is written **for the cstar project**: each entry is reduced to the smallest program or file that shows
it. Every entry with a repro was **run** on the version named. Nothing is inferred from reading the
spec. An entry that is an absence cites the cstar files that show it instead. This file is excluded from
the published package, as it is in `@kama/sodium`.

**Current compiler:** `kama 0.9.506+g1d11fb05`, the dev build at `../cstar/out/Darwin-arm64/kama`. Every entry from
KPG-11 to KPG-22 was re-run on it, with the repro as filed, before it moved to FIXED. Earlier rounds: `0.9.490`
(KPG-15 to KPG-22 filed), `0.9.486` (KPG-11 to KPG-14 filed), `0.9.477` (KPG-1 also on Linux aarch64 inside
`localhost/kama-dev`), and the first report against `0.9.470` and the public `0.9.440`.

**Reporter:** the `@kama/postgres` repo. Each open entry names the workaround this package uses, so the
workaround can be deleted when the gap closes. **We are not attached to any workaround.** If a fix
changes the right design here, say so and we will follow it.

**Open now:**
- KPG-23, found porting to 0.9.506.
- KPG-24, found adopting KPG-15's fix (SASLprep).
- KPG-25 and KPG-26, found probing phase 5's typed parameters and rows.

Every other gap is fixed, except KPG-8, which is closed as a non-goal (see below).

**Priorities:**
- **HIGH:** wrong or dangerous behaviour today: a crash, or a permanent bad publish.
- **MED:** a real capability missing, with a workaround that costs something.
- **LOW:** ergonomics or docs.

---

## OPEN

### KPG-25 · HIGH · A string tag's holes lose their type, so an `Optional` hole is sent as the text "None"

**Status:** open. Reproduces on 0.9.506, with std's own `sql` tag.

A tag receives every hole already rendered to a string through `Formattable` (`prelude/global.kama:688-699`;
`SPEC.md:264-268` lists typed holes as the future "Model B"). For a SQL tag that is a hazard:
- An `Optional` hole of a `Formattable` payload is sent as its derived text: `Some { value: 5 }`, or `None`.
  Into a text column it is stored as that text. Nothing fails.
- NULL cannot be expressed at all, and neither can bytes (a `DynamicArray<uint8>` hole does not compile).
- An `Optional<string>` hole is refused at compile time, because `string` reaches interpolation by a fast path,
  not through `Formattable`. The two `Optional`s behave differently.

```kama
import { core::println, std::fmt::sql, std::fmt::SqlQuery };
fn int32 main() {
    Optional<int32> score = Optional::None;
    SqlQuery q = sql"update t set score = ${score}";
    string p = copy q.param(at: 0);
    println(s: copy q.queryText());
    println(s: "param 0 is \"".concat(other: p).concat(other: "\""));
    return 0;
}
```

```
update t set score = ?
param 0 is "None"
```

**Why it matters here.** The `pg"…"` tag is how most code in this package's README will run a query. A hole is
always a parameter and never spliced, so it is safe against injection. But a NULL written as `${x}` with
`x` an `Optional` sends the word "None".

**Workaround here.** `postgres::pg` refuses a hole whose text is exactly `None` or starts with `Some { value: `.
The error names `Query.add`/`addOptional`, which take the value through `Serializable` and do send NULL. A
genuine string "None" is refused too, with the same advice. This workaround should go when holes keep their
type.

**Suggested fix.** Typed holes: a tag sees each hole's value through a contract (`Serializable` would suit a
SQL tag), so `Optional` can be NULL and bytes can be bytes. Short of that, refuse an `Optional` hole in a tagged
string, as an `Optional<string>` already is, so the hazard is a compile error.

### KPG-26 · MED · `@generate(Deserializable)` never reports a missing field

**Status:** open. Reproduces on 0.9.506, with std's JSON backend.

The derived `deserialize` zero-initializes the result and fills the fields whose keys arrive. A field whose key
never arrives keeps its zero (`src/kama.cemit.cpp`, `emitDeserializeDefinition`). `DeError::MissingField` exists,
but the derive never raises it.

```kama
import { core::println, std::memory::Owned, std::serialization::text::json::deserializeJsonBuffer };
@generate(Deserializable)
type value Point { @field public int32 x = 0; @field public int32 y = 0; }
fn int32 main() {
    // The JSON has no "y": the derive could report MissingField, and does not.
    Result<Point, Owned<Error>> p = deserializeJsonBuffer::<Point>(src: "{\"x\": 1}");
    string r = match (p) { case Ok(value: v): "Ok(x: ${v.x}, y: ${v.y})"; case Err(error: e): e.message(); };
    println(s: give r);
    return 0;
}
```

```
Ok(x: 1, y: 0)
```

**Why it matters here.** `rowAs::<T>` reads a row into a struct by column name. A query that does not select a
field's column should fail, not fill the field with 0 or "". That is what sqlx's and pgx's row mapping do.

**Workaround here.** The row reader counts the keys that were read rather than skipped, and fails at
`endObject` with `MissingField` if fewer were read than `beginObject`'s count (the derive checks `failed()`
after `endObject`). It works for a flat struct, which is all a row is. An `Optional` field counts as required:
its column must be selected, and may be NULL.

**Suggested fix.** The derive knows which slots it filled. After the loop, a field that is not `Optional` and has
no default, whose slot was never filled, raises `MissingField`. That makes this hold for every backend.

### KPG-23 · LOW · `IoError` gives the OS's words only inside its message, never alone

**Status:** open. An absence, checked on 0.9.506.

KPG-22's fix keeps the OS's code and quotes its text: `IoError.message()` is `"connection refused (os error 61:
Connection refused)"`. The text alone comes from a private `osText(code:)` (`lib/std/io/io.kama:114`). The module
exports `IoError, IoErrorKind, lastError` and nothing else (`:3`). `IoError` has `kind()`, `rawOsError()` and
`message()` (`:94-110`).

```kama
import { core::println, std::io::IoError, std::net::TcpStream };
fn int32 main() {
    // Port 1 on loopback: nothing listens, so the OS refuses the connect.
    Result<TcpStream, IoError> r = TcpStream.connect(host: "127.0.0.1", port: 1ui16);
    string m = match (r) { case Ok(value: s): "connected"; case Err(error: e): e.message(); };
    println(s: give m);
    return 0;
}
```

```
connection refused (os error 61: Connection refused)
```

**Why it matters here.** libpq prints `strerror` and nothing else. psql says `… port 1 failed: Connection
refused`, so this client cannot say exactly that. It can say the kind (`connection refused`) or the whole message.

**Workaround here.** None to delete later. The client prints `IoError.message()`, which carries more than libpq's
text but not libpq's text. The two integration checks that compare an I/O failure match its kind and the OS's
words separately (`session_test.kama`, `socket_test.kama`).

**Suggested fix.** A public `osMessage()` (or `description()`) on `IoError`, returning `Optional<string>`: the OS's
text for the code, `None` for an error kama raised itself.

### KPG-24 · MED · A `comptime InlineArray` imported from another file loses its type

**Status:** open. Reproduces on 0.9.506.

A `comptime InlineArray` works in the file that declares it. In a file that imports it, it is not the same value:
- `.view()` is "no method `view`", and a chained call is "cannot resolve the receiver".
- Indexing it passes as safe code nowhere: `kama check` says "raw pointer access requires an `unsafe fn`".
- In an `unsafe fn`, the index passes `kama check` and reaches clang as a subscript of the struct, which clang
  rejects.

Copying it into a local of the same type first works.

```kama
// src/tables.kama
export { RANGES };
comptime InlineArray<uint32>#(4) RANGES = [0x00A0ui32, 0x00A0ui32, 0x2000ui32, 0x200Bui32];
```

```kama
// src/main.kama (the same module)
import { core::println, std::collections::ConstView, RANGES };
unsafe fn uint32 last() { return RANGES[3]; }
fn isize count() { return RANGES.view().length(); }
fn int32 main() { uint32 l = last(); isize n = count(); println(s: "${l} ${n}"); return 0; }
```

```
src/main.kama:3:0: error: cannot resolve the receiver of `length` — its type is not known here
```

With `count` removed, `last` passes `kama check`, and `kama build` fails in clang:

```
src/main.kama:2:30: error: subscripted value is not an array, pointer, or vector
    2 |     kama_ret_0 = (p2__RANGES)[3];
```

The same module, or another module, gives the same result. Declared in `main.kama` itself, `RANGES.view()` and
`RANGES[3]` both work. So does `InlineArray<uint32>#(4) local = RANGES;` followed by `local[3]`.

**Why it matters here.** SASLprep's stringprep tables are generated into a file of their own, as every generated
table in this package is. The code that searches them lives elsewhere.

**Workaround here.** The generated file holds the search too (`src/stringprep/tables.kama`). Its predicates
(`isProhibitedOutput(code:)`, …) are what other files call, so no table crosses a file. That is the shape the module
would keep anyway, so there is nothing to delete.

**Suggested fix.** Give an imported `comptime` the type it was declared with: an `InlineArray`'s methods and its
indexing, as in the declaring file.

---

## FIXED — kept for the record

KPG-11 to KPG-22 were verified on 0.9.506, KPG-4 and KPG-6 on 0.9.486. The rest were re-run on 0.9.477 with the
same repro as the original report.

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
OS's words. KPG-23 is what remains: those words alone, for libpq's message.

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
functions `column::<T>(row:, index:)`, `columnByName::<T>(…)` and `columnOpt::<T>(…)` over a `PgDecode`
contract. That is the design, not a workaround, so there is nothing to remove later.

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
