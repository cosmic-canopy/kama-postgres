# Gaps found in kama, from building @kama/postgres (and @kama/tls)

Found while planning the official PostgreSQL client and the TLS package it depends on (`../kama-tls`).
It is written **for the cstar project**: each entry is reduced to the smallest program or file that shows
it. Every entry with a repro was **run** on the version named. Nothing is inferred from reading the
spec. An entry that is an absence cites the cstar files that show it instead. This file is excluded from
the published package, as it is in `@kama/sodium`.

**Current compiler:** `kama 0.9.490+g9a69fc30`, the dev build at `../cstar/out/Darwin-arm64/kama`, built
from cstar HEAD (`9a69fc30`). KPG-11 to KPG-14 were re-run on it and all four still reproduce. Earlier rounds:
`0.9.486` (KPG-11 to KPG-14 first filed), `0.9.477` (KPG-1 also on Linux aarch64 inside
`localhost/kama-dev`), and the first report against `0.9.470` and the public `0.9.440`.

**Reporter:** the `@kama/postgres` repo. Each open entry names the workaround this package uses, so the
workaround can be deleted when the gap closes. **We are not attached to any workaround.** If a fix
changes the right design here, say so and we will follow it.

**Open now:**
- KPG-11 to KPG-14, found building the protocol and type layers.
- KPG-15 to KPG-17, found planning the first live connection (phase 4).

Every earlier gap is fixed, except KPG-8, which is closed as a non-goal (see below).

**Priorities:**
- **HIGH:** wrong or dangerous behaviour today: a crash, or a permanent bad publish.
- **MED:** a real capability missing, with a workaround that costs something.
- **LOW:** ergonomics or docs.

---

## OPEN

### KPG-15 · MED · std has no Unicode normalization, so SASLprep (and SCRAM with a non-ASCII password) cannot be done right

**Status:** open. An absence, checked on 0.9.490.

**What is missing.** Unicode normalization: NFKC at least, and NFC/NFD/NFKD with it. Nothing in `lib/std` or
`lib/core` normalizes:
- `grep -rli 'nfkc\|normaliz' lib/std lib/core` finds only vector `normalize` in `std::math`.
- `std::encoding::utf8` exports `decode, validate, Utf8Error` and nothing else (`lib/std/encoding/utf8/utf8.kama:2`).

**Why a PostgreSQL client needs it.** SCRAM-SHA-256 hashes the password after SASLprep (RFC 4013), and SASLprep is
stringprep with normalization form KC (RFC 4013 §2.2). Both sides must prepare the password identically:
- The server prepares it when it stores the verifier (`pg_saslprep` in `src/common/saslprep.c`).
- libpq prepares it before hashing.

If this client hashes the raw bytes, a password whose NFKC form differs cannot log in. Examples: full-width
letters, a ligature such as `ﬁ`, or a decomposed accent. Neither side reports anything but "password
authentication failed".

**The rest of SASLprep** is mapping (RFC 3454 B.1, C.1.2), prohibited output (C.1.2–C.9) and the bidi check
(D.1, D.2). This package will generate those tables by script from PostgreSQL's pinned `saslprep.c`. They are
specific to SASL and do not belong in std. Only normalization is general-purpose.

**Workaround here.** None. `postgres::protocol`'s `saslPrep` passes the password through unchanged, which is
correct for ASCII. Its comment documents the limit.

**Suggested fix.** `std::unicode` (or a method on `string`) with `normalize(form: NormalizationForm)` for NFC,
NFD, NFKC and NFKD, with tables generated from the UCD at a pinned Unicode version. Rust keeps this in a crate
(`unicode-normalization`) and Go in `x/text`, but kama has no package for it. A std module is the place where
one implementation can be tested against the UCD's `NormalizationTest.txt`.

### KPG-16 · LOW · No home-directory lookup in std

**Status:** open. An absence, checked on 0.9.490.

`std::process::identity` exports `UserId, GroupId, AccessToken, currentUser, currentGroup, currentProcessId`
(`lib/std/process/identity.kama:18`). A `UserId` gives `raw()` and `name()` (`:59-61`) but not its home
directory, and nothing in `lib/std` or `lib/core` reads `getpwuid_r`'s `pw_dir`.

**Why it matters here.** libpq finds `~/.pgpass` and `~/.pg_service.conf` through `$HOME`. When `HOME` is unset it
falls back to the passwd entry (`pqGetHomeDirectory` in `fe-connect.c`); this is common under a service manager
or in a container. On Windows it uses `%APPDATA%`, which an environment variable already gives.

**Workaround here.** None. When `HOME` is unset, this package uses no user file, and says so in its docs.

**Suggested fix.** `UserId.homeDirectory()` returning `Result<string, IoError>` from `getpwuid_r`. Optionally
also `std::process::homeDirectory()`, which reads `$HOME` first and then the passwd entry, as Rust's
`std::env::home_dir` does on Unix.

### KPG-17 · MED · An interrupted system call is `IoError::Other(4)`, indistinguishable from a real failure

**Status:** open. An absence, checked on 0.9.490.

`lastError()` (`lib/std/io/io.kama:68-86`) classifies errno into named variants, but EINTR is not one of them,
so it falls through to `IoError::Other(code: e)`. The runtime's poll returns -1 with errno EINTR to the kama
layer as it is:
- `kama_poller_wait` (`include/kama_os.h:1910-1913`) is `return poll(...)`.
- `recv` and `send` are the same (`:1742`).

`Poller.wait`'s own comment says "EINTR surfaces as Err(Other) — the caller may retry". But the caller cannot
tell EINTR from any other `Other` without comparing a raw, platform-specific errno. The runtime knows the value
(`kama_EINTR()`, `include/kama_os.h:1333`) and does not expose it.

**Why it matters here.** This package's connection is a non-blocking socket driven by `Poller.wait` with a
deadline, which is libpq's design. A signal handled anywhere in the application wakes `poll` with EINTR, whatever
`SA_RESTART` says. Examples: SIGCHLD from a child process, SIGWINCH, or a profiler's SIGPROF.
- The right response is to recompute the remaining time and wait again.
- As things stand, the connection must either fail, which is wrong, or test `code == 4`, which is a magic
  number.

**Workaround here.** None. EINTR is reported as an I/O error, and the connection closes. That is wrong, but
honest, until this is fixed.

**Suggested fix.** Either one would do. The first is the general fix, and Rust has both.
- Add `IoError::Interrupted` (Rust's `ErrorKind::Interrupted`), classified in `lastError()`.
- Have `Poller.wait` retry EINTR internally, with the remaining time recomputed against the monotonic clock.

### KPG-11 · MED · A generic-inference error is reported against the wrong file, and `kama query --diagnostics` misses it

**Status:** open. Reproduces on 0.9.486 and 0.9.490.

**Symptom.** One error, reported three different ways:
- `kama check` reports it, but names the package's **root** file (or, from a consumer, the **consumer's**
  entry file) with the **right line number from the real file**.
- `kama query <kama.json> <the real file> --diagnostics` reports nothing at all.
- The error message itself is accurate.

So the error points at a file where that line holds unrelated code, and the per-file diagnostics an agent or
an editor asks for say the file is clean.

**Repro.** A library with a submodule:

```kama
// src/slib.kama — the root module
export { one };
fn int32 one() { return 1; }
```

```kama
// src/sub/broken.kama  (kama.json lists "sub")
import { std::math::sin, std::math::abs };
export { Table };
fn float64 helper(float64 t) { return abs(x: sin(x: t)); }
type value Table { float64 v = 0.0; public ctor make() { this.v = helper(t: 1.0); } }
```

```
$ kama check kama.json
src/slib.kama:3:0: error: cannot infer generic type parameter 'T' — argument 'x' is not a literal or a locally-typed value
$ kama query kama.json src/sub/broken.kama --diagnostics
no diagnostics
```

Line 3 is `helper`'s line in `src/sub/broken.kama`; `src/slib.kama` has no line 3. A consumer of a library
with the same code gets the error against its own `src/main.kama`, at the library's line number. A plain type
error in the same submodule file is reported correctly, by `check` and by `query` both, so this is specific
to the generic-inference diagnostic.

**Impact.** In this package the error pointed at a unit-test file whose line 41 is unrelated. Finding the
real site meant recognising the parameter name (`x`, which the test file never uses) as `std::math`'s.

**Suggested fix.** Carry the call's own file through to the inference diagnostic, and have `query
--diagnostics` include the diagnostics `check` raises for that file.

### KPG-12 · LOW · A generic call cannot take another generic call's result as its argument

**Status:** open. Reproduces on 0.9.486 and 0.9.490. It may be a deliberate limit of local inference; recorded as a
consumer data point.

`abs(x: sin(x: t))` with `t` a `float64` local is refused ("argument 'x' is not a literal or a locally-typed
value"). The inner call's type is fully determined (`sin<float64>` returns `float64`), but the outer call
will not infer from it. The workaround is a typed local per step:

```kama
float64 sine = sin(x: t);
float64 magnitude = abs(x: sine);
```

**Impact.** Small: a few lines of ceremony wherever math nests. `postgres::protocol`'s MD5 table
(`floor(|sin(i + 1)| · 2^32)`) is written that way.

**Suggested fix.** Infer a generic argument from a call whose return type is already known.

### KPG-13 · MED · `parse::<float64>` refuses a subnormal it read exactly

**Status:** open. Reproduces on 0.9.486 and 0.9.490.

```kama
import { core::println, std::fmt::parse, std::fmt::ParseError };
fn int32 main() {
    string tiny = "5e-324";                       // the smallest positive float64
    string small = "2.2250738585072014e-308";     // DBL_MIN, normal
    string sub = "1e-310";                        // subnormal
    Result<float64, ParseError> a = parse::<float64>(s: tiny);
    Result<float64, ParseError> b = parse::<float64>(s: small);
    Result<float64, ParseError> c = parse::<float64>(s: sub);
    string ra = match (a) { case Ok(value: v): "ok"; case Err(error: e): e.message(); };
    string rb = match (b) { case Ok(value: v): "ok"; case Err(error: e): e.message(); };
    string rc = match (c) { case Ok(value: v): "ok"; case Err(error: e): e.message(); };
    println(s: "5e-324: ${ra}; DBL_MIN: ${rb}; 1e-310: ${rc}");
    return 0;
}
```

```
5e-324: number out of range for this type; DBL_MIN: ok; 1e-310: number out of range for this type
```

**Evidence.** `include/kama_fmt.h:35`: `if (errno == ERANGE) return 3;`. strtod sets ERANGE on underflow even
when it returns the correctly rounded subnormal, so every subnormal is refused although each is a valid
float64.

**Impact.** A `float8` column holding a subnormal fails to decode from text, and PostgreSQL's own output of
`5e-324` is one of this package's server vectors. JSON numbers would hit the same refusal.

**Workaround here.** `postgres::types` retries an out-of-range parse with libc `strtod` directly (an `extern`
in `src/types/codec.kama`), and accepts any finite answer.

**Suggested fix.** Report ERANGE as out of range only for an overflow (the result is ±HUGE_VAL). An underflow
returns a value that is exactly what was written, or the nearest representable one, and should be accepted.

### KPG-14 · LOW · A `comptime int64` at int64's minimum is emitted as an out-of-range C literal

**Status:** open. Reproduces on 0.9.486 and 0.9.490.

```kama
// The minimum int64, spelled the only way a literal can reach it.
comptime int64 LOWEST = -9223372036854775807i64 - 1i64;
fn int32 main() { int64 x = LOWEST; if (x < 0i64) { return 0; } return 1; }
```

```
int64min.kama:2:45: warning: integer literal is too large to be represented in a signed integer type,
interpreting as unsigned [-Wimplicitly-unsigned-literal]
```

The emitted C is `static const int64_t … = -9223372036854775808;`, the same text whether the constant is
written `-9223372036854775808i64` or folded from `-9223372036854775807i64 - 1i64`. The program still runs
correctly: the unsigned value converts back. The same literal inside an expression in a function body
(`int64 x = -9223372036854775808i64;`) builds without a warning, so only the `comptime` emission has it.

**Impact.** A warning in every build of every consumer: `timestamp`'s -infinity is int64's minimum.

**Workaround here.** `src/types/datetime.kama` returns it from a function instead of declaring a `comptime`.

**Suggested fix.** Emit `INT64_MIN`, or `(-9223372036854775807LL - 1)`, for that value.

---

## FIXED — kept for the record

KPG-4 and KPG-6 were verified on 0.9.486. The rest were re-run on 0.9.477 with the same repro as the
original report.

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
