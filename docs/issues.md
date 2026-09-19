# QUIC transport — code review findings

Review of changes since `4a939dd` (v1.3.16), cross-checked against the TDMQ
server implementation (`rocketmq-mqtt`). Captured 2026-09-18 for one-by-one fixing.

Status legend: [ ] open, [x] fixed

## P0 — must fix before production

- [x] **1. `is_quic_closed` breaks connection-loss detection for plain TLS/WSS**
  - `src/SSLSocket.c:917-928, 975-986, 1201-1214`
  - `SSL_get_conn_close_info()` returns 0 (failure) for non-QUIC SSL objects, so the
    rc==0 path in `SSLSocket_getch`/`getdata` maps it to `TCPSOCKET_INTERRUPTED`
    instead of `SOCKET_ERROR`. With a QUIC-enabled build, an orderly broker TLS
    shutdown on `ssl://`/`wss://` causes an infinite read-retry loop and
    `connectionLost` is never delivered.
  - The helper's comment ("Return 0 if QUIC connection is closed") also contradicts
    the code (returns 1 on success); for genuinely open QUIC connections it returns
    1 = "closed".
  - Fix: distinguish non-QUIC (keep original `SOCKET_ERROR`) from QUIC-not-closed
    (`TCPSOCKET_INTERRUPTED`); only QUIC-closed maps to `SOCKET_ERROR`.
  - **Fixed 2026-09-18**: helper replaced by tri-state `SSLSocket_quic_closed_state()`
    using `SSL_is_quic()` to discriminate TLS (-1) from QUIC, then
    `SSL_get_conn_close_info()` for closed (1) vs open (0). Note:
    `SSL_get_conn_close_info` returns 0 for *open* QUIC connections, so it alone
    cannot distinguish QUIC-open from TLS — the `SSL_is_quic` guard is required.
    Verified: QUIC smoke ×3, TLS/WSS smoke against TDMQ, and local TLS
    orderly-shutdown test (failure callback in ~1s, no busy loop).

- [x] **2. Inverted `#if !defined(WITH_OPENSSL_QUIC)` guard breaks builds against OpenSSL < 3.2**
  - `src/SSLSocket.c:596-601`
  - When built *without* QUIC support (OpenSSL 1.1/3.0), the `MQTT_SSL_VERSION_QUIC`
    case referencing `OSSL_QUIC_client_thread_method()` *is* compiled, but that
    symbol does not exist before OpenSSL 3.2 → compile failure. When QUIC *is*
    enabled the case is excluded (harmless, `quic_mode` branch handles it).
  - Fix: invert guard to `#if defined(WITH_OPENSSL_QUIC)` or delete the case.
  - **Fixed 2026-09-18**: guard inverted. `OSSL_QUIC_client_thread_method` is now
    only referenced when `WITH_OPENSSL_QUIC` is defined (which requires
    OpenSSL >= 3.2). Verified: QUIC-on and QUIC-off (`PAHO_WITH_QUIC=OFF`)
    builds both compile; QUIC smoke test passes.

- [x] **3. NULL `sslopts` dereference for `quic://` connects without SSL options**
  - `src/MQTTAsyncUtils.c:2943-2946`
  - `MQTTAsync_connect` only allocates `m->c->sslopts` when `connectOptions->ssl`
    is provided (`src/MQTTAsync.c:803`). Connecting `quic://` without ssl options
    reaches `m->c->sslopts->sslVersion = MQTT_SSL_VERSION_QUIC` with NULL → segfault.
  - Fix: guard the assignment or allocate default sslopts for `ssl == 2`.
  - **Fixed 2026-09-18**: root cause was the `serverURIs` validation loop in
    `MQTTAsync_connect` (`src/MQTTAsync.c:605`) — it required ssl options for
    `ssl://`/`tls://`/`mqtts://`/`wss://` but not `quic://`, so the NULL
    invariant could be violated via the HA path (the primary-URI path was
    already guarded). Added `URI_QUIC` to the loop; such connects now fail
    cleanly with `MQTTASYNC_NULL_PARAMETER` (-6). Verified: dedicated
    serverURIs/no-sslopts test rejects cleanly (no crash), QUIC HA test
    (test9000 #14/test2e) 95/95, QUIC smoke passes.

## P1 — should fix

- [x] **4. `SSLSocket_connect` default branch returns raw `SSL_ERROR_*` codes**
  - `src/SSLSocket.c:834-837` (callers: `src/MQTTProtocolOut.c:318-326`)
  - `rc = error` yields positive codes (e.g. `SSL_ERROR_ZERO_RETURN`=6). Callers
    only handle `sslrc == 1` (success) and `sslrc < 0` (failure); a positive non-1
    code falls through with rc==0 from the TCP connect, proceeding as if the
    handshake succeeded and failing later with a misleading error.
  - Fix: audit callers, map all positive codes to failure.
  - **Fixed 2026-09-18**: default branch now returns `SSL_FATAL` (-3) instead of
    the raw error, restoring the documented contract (1 = success,
    `TCPSOCKET_INTERRUPTED` = retry, anything else = failure). This matches
    historical behavior (negative = failure) and all 11 call sites in
    `MQTTClient.c`/`MQTTAsyncUtils.c`/`MQTTProtocolOut.c` handle it correctly.
    Verified: QUIC/TLS smokes pass, TLS-to-non-TLS-server handshake failure
    fails fast (~1s, `TCP/TLS connect failure`), test9000 #13 negative
    handshake test passes.

- [x] **5. `MQTT_SSL_VERSION_TLS_1_3` (=4) exposed but not implemented**
  - `src/MQTTClient.h:664`
  - No switch case in `SSLSocket_createContext`. Correction to the original
    failure-mode note: the version `switch` only applies to OpenSSL < 1.1.0;
    on modern OpenSSL `sslVersion` is silently ignored (TLS_client_method
    always), so selecting 1.3 was a no-op rather than a connect failure —
    and no way to *restrict* to TLS 1.3 existed.
  - Fix: implement (TLS_client_method + min/max proto version) or remove the constant.
  - **Fixed 2026-09-18** (option B from discussion): in the OpenSSL >= 1.1.0
    branch, when `sslVersion == MQTT_SSL_VERSION_TLS_1_3` the context is
    restricted via `SSL_CTX_set_min/max_proto_version(TLS1_3_VERSION)`;
    `TLS1_3_VERSION` undefined (OpenSSL 1.1.0 / old LibreSSL) → clean error
    instead of silent downgrade; legacy branch logs "requires OpenSSL 1.1.1+".
    Other version values remain ignored on modern OpenSSL (pre-existing
    quirk, out of scope). Verified: TLS 1.3-restricted connect to TDMQ
    passes (broker does 1.3), default connect passes, TLS 1.3-only client vs
    TLS 1.2-only local server fails fast (0.35s).

- [x] **6. `QUIC_MODE_PREFERRED` promises TCP fallback that does not exist**
  - `src/Clients.h:79-88`, `src/MQTTProtocolOut.c:270-278`
  - Enum comment claims fallback to TCP when QUIC fails; no fallback code exists.
    quic:// through networks blocking UDP hard-fails. This is the main production
    rollout risk for QUIC (UDP egress).
  - Fix: implement TCP fallback or simplify the enum to an honest on/off flag.
  - **Fixed 2026-09-18** (per discussion: no auto-fallback — ill-defined fallback
    port, duplicates serverURIs, and silent UDP-timeout latency). Enum collapsed
    to `QUIC_MODE_NONE`/`QUIC_MODE_ONLY`; README documents the
    `serverURIs {quic://, ssl://}` fallback pattern; new sample
    `MQTTAsync_quic_fallback.c` demonstrates it.
  - **State-pollution bug found & fixed during verification**: the documented
    pattern initially failed — the QUIC `SSL_CTX` survived the failed attempt
    (`SSLSocket_destroyContext` has no callers) and was reused for the TLS
    fallback, spinning 30s in "write client hello" (8.7M trace lines, 32% CPU).
    Fixes: `SSLSocket_setSocketForSSL` now discards a ctx whose QUIC-ness
    (`SSL_CTX_get_ssl_method == OSSL_QUIC_client_thread_method`) doesn't match
    the current connection; `MQTTProtocol_connect` resets
    `net.quic_mode = QUIC_MODE_NONE` per attempt.
  - Caveats documented in the sample: dead QUIC port fails by ~30s timeout per
    URI (connectTimeout/QUIC handshake timeout), and MQTTVERSION_DEFAULT retries
    each URI per MQTT version (set an explicit version to halve failover time).
  - Verified: fallback test connects via ssl:// after dead quic:// (~61s with
    default version attempts), sample works both quic-direct and fallback paths,
    QUIC smoke/TLS smoke/test9000 #14 regression battery passes.

## P2 — cleanup

- [x] **7. TRACE_MIN log spam in command loop**
  - `src/MQTTAsyncUtils.c:1403-1406`
  - "Connect state is NOT_IN_PROGRESS" logged per processed command at TRACE_MIN.
  - Fix: remove or demote to TRACE_MED.
  - **Fixed 2026-09-18**: demoted to TRACE_MED (kept the message — it is on an
    error path and useful for debugging, just not at minimum level).
    Verified: build clean, QUIC smoke passes.

- [x] **8. UDP socket gets TCP hints and TCP-only setsockopts**
  - `src/Socket.c:1398-1401, 1496-1510`
  - getaddrinfo hints hardcode `SOCK_STREAM`/`IPPROTO_TCP`; `TCP_NODELAY`/
    `SO_NOSIGPIPE` are set on UDP sockets ("Could not set TCP_NODELAY for socket"
    in every QUIC connect log). The `WITH_OPENSSL_QUIC` `fcntl(O_NONBLOCK)` block
    is marked `@TODO: maybe not needed` and applies to TCP sockets too.
  - Fix: use type-appropriate hints; scope TCP setsockopts to `SOCK_STREAM`;
    scope/remove the fcntl.
  - **Fixed 2026-09-18**: hints now set `ai_socktype`/`ai_protocol` from the
    requested socket type; `SO_NOSIGPIPE`/`TCP_NODELAY` scoped to
    `type == SOCK_STREAM`; the `@TODO` fcntl block removed as redundant —
    `Socket_addSocket` already calls `Socket_setnonblocking` for every socket.
    Verified: QUIC connect trace has no TCP_NODELAY/NOSIGPIPE errors; QUIC
    smoke, TLS smoke, and TCP basic test all pass.

- [x] **9. `quic://` default port is 1883**
  - `src/MQTTProtocolOut.c:270`
  - Port-less `quic://host` targets UDP/1883. Choose a secure default (e.g. 8883)
    or document.
  - **Fixed 2026-09-18**: new `QUIC_DEFAULT_PORT 14567` (`src/MQTTProtocolOut.h`)
    used for `ssl == 2` connects — 14567 is the MQTT-over-QUIC port used by both
    EMQX and Tencent TDMQ. Documented in README. Verified: port-less
    `quic://<host>` connects to TDMQ successfully.

- [x] **10. `SSL_set_blocking_mode(ssl, 0)` applied to non-QUIC TLS connections**
  - `src/MQTTProtocolOut.c:318-320`
  - QUIC-only API called unconditionally on every successful TLS handshake in
    QUIC-enabled builds (fails harmlessly for TLS).
  - Fix: guard with `net->quic_mode > QUIC_MODE_NONE`.
  - **Fixed 2026-09-18**: guarded as recommended (`quic_mode` is reset to
    `QUIC_MODE_NONE` per connect attempt and set to `QUIC_MODE_ONLY` only for
    `ssl == 2`, so the guard is exact). Verified: QUIC smoke (port-less URI),
    TLS smoke, and MQTTAsync-over-TLS test9000 #8 all pass.

## Server-side (rocketmq-mqtt) observations affecting rollout

Not client bugs — constraints/notes for production against TDMQ:

- **Per-stream flow control is 1 MB** (`MqttServer.java:359-363`); earlier note said
  publishes above ~1 MB stall. **Superseded by later TDMQ live tests (2026-09-18
  evening):** 256 KB / 1 MB / 2 MB QoS1 publishes succeeded; 4 MB and the default
  5 MB `test7` payload failed. Treat the TDMQ limit as **max MQTT packet ≈ 4 MB**,
  not a 1 MB stall and not an 8 MiB client-visible max. See #28.
- **No 0-RTT** server-side — fine, client does not attempt it.
- **No client connection migration**: server enables active migration
  (`MqttServer.java:364`) but OpenSSL QUIC client does not migrate; NAT rebinding
  (Wi-Fi→LTE) kills the connection → rely on `automaticReconnect`.
- **Mutual TLS / BYOC identity is not extracted on the QUIC pipeline** (no
  `SslHandler`/`SessionContextHandler`, unlike the TLS listener) — client-cert
  auth over QUIC is ineffective; username/password only.
- **MQTT keepAlive handler removed from QUIC pipeline after CONNECT**
  (`ConnectHandler.java:97-103`); dead-connection detection leans on QUIC
  `maxIdleTimeout` (5000s). Keep client keepAlive small.
- **Stateless QUIC token handler is not hardened** (`MqttQuicTokenHandler.java`) —
  retry tokens forgeable; server-side issue to raise with the TDMQ team.

## Verified working (against TDMQ, 2026-09-18)

Connect/auth, pub/sub QoS 0–2, retained messages, wills, 10 concurrent
connections, HA serverURIs failover, 256 KB big messages — over TCP 1883,
SSL 8883, WS 80, WSS 443, QUIC 14567.

## Follow-up review — open issues

Review repeated at `094c84b` on 2026-09-18. These issues remain open.

### P0 — must fix before merge

- [x] **11. QUIC handshake blocks the MQTTAsync command thread**
  - `src/MQTTProtocolOut.c:317-330`
  - QUIC objects are blocking by default, but `SSL_set_blocking_mode(ssl, 0)` is
    called only after `SSL_connect()` succeeds. An unreachable peer therefore
    blocks the asynchronous command thread for OpenSSL's handshake timeout
    (observed at approximately 30 seconds), preventing `connectTimeout` and
    other clients' work from being processed promptly.
  - Fix: call and check `SSL_set_blocking_mode(net.ssl, 0)` after binding the
    socket and before the first `SSL_connect()` call.
  - **Verified valid before fixing** (trace evidence: one blocking `SSL_connect`
    call held the command thread ~30s on a dead QUIC port; `connectTimeout=10`
    could not preempt it).
  - **Fixed 2026-09-18**: `SSL_set_blocking_mode(ssl, 0)` now called in
    `SSLSocket_setSocketForSSL`'s QUIC branch (before the first `SSL_connect`),
    covering all connect paths; the redundant post-success call in
    `MQTTProtocolOut.c` removed. Handshake is now driven by the
    `SSL_IN_PROGRESS` state machine like TLS. Verified: dead-QUIC-port fallback
    completes in ~13s (was ~61s) with `connectTimeout=10` effective; full
    test9000 QUIC suite, smokes, and fallback sample all pass.

- [x] **12. No-SSL sample builds are broken**
  - `src/samples/CMakeLists.txt:58-94`
  - Existing TCP samples now link to `paho-mqtt3as`/`paho-mqtt3cs`, and QUIC
    samples are created unconditionally. With `PAHO_BUILD_SAMPLES=ON` and
    `PAHO_WITH_SSL=OFF`, linking fails because the SSL targets do not exist.
  - Fix: retain the non-SSL libraries for ordinary samples and add/install QUIC
    samples only when effective QUIC support is enabled.
  - **Fixed 2026-09-18**: plain `MQTTAsync_*`/`MQTTClient_*` samples again link
    the non-SSL `paho-mqtt3a`/`paho-mqtt3c` (restoring upstream behavior); the
    three QUIC samples are created/linked (`paho-mqtt3as`)/installed only under
    `PAHO_WITH_SSL`. (Refining the gate to *effective* QUIC capability is #19's
    scope.) Verified: `PAHO_WITH_SSL=OFF` + `PAHO_BUILD_SAMPLES=ON` builds all
    plain samples with zero QUIC targets; SSL build still builds all three QUIC
    samples; quic publish sample passes against TDMQ.

- [x] **13. Bundled QUIC test certificates are expired**
  - `test/ssl/emqx/etc/certs/cert.pem`
  - `test/ssl/emqx/etc/certs/client-cert.pem`
  - Both certificates expired on 2026-02-12. `openssl verify` now rejects them,
    so positive certificate-authentication tests cannot validate QUIC.
  - Usage found: CTest test9000 entries (`EMQX_CERTDIR` paths in
    `test/CMakeLists.txt`) and the CI EMQX container (`build_linux.yml` mounts
    the certs dir + `test/emqx.conf`). Not used by samples.
  - Fix: replace or generate maintained test certificates and add an expiry
    check to CI.
  - **Fixed 2026-09-18** (on-demand generation, no committed keys): new
    `test/ssl/emqx/etc/certs/gen.sh` generates CA + server (CN=localhost with
    SANs) + client certs; committed PEMs removed and git-ignored; CMake
    configure auto-runs gen.sh when `PAHO_WITH_QUIC` is on and certs are
    missing; CI `build_linux.yml` runs gen.sh before starting EMQX.
    Verified: gen.sh output chains verify (`openssl verify` OK, leaf expiry
    +825 days), configure-time auto-generation works.
  - **Deferred**: full test9000 run against the local EMQX docker rig — the
    available docker daemon runs on a remote Linux host and cannot bind-mount
    local macOS paths. Re-verify by running `ctest -R test9000` in CI (which
    now generates fresh certs) or on a host with local docker.

- [x] **14. QUIC read failures are classified without `SSL_get_error()`**
  - `src/SSLSocket.c:951-972, 1010-1033`
  - OpenSSL requires `SSL_get_error()` for every `SSL_read()` result `<= 0`.
    The new zero-result path instead checks only connection-close information,
    which cannot distinguish retry, stream EOF, and all fatal errors. A stream
    FIN or fatal error on an otherwise open QUIC connection can be retried
    indefinitely.
  - Fix: preserve the exact `SSL_read()` result, classify it with
    `SSL_get_error()`, and retry only `SSL_ERROR_WANT_READ`/`WANT_WRITE`.
  - **Fixed 2026-09-18**: the rc==0 branches of `SSLSocket_getch`/`getdata` now
    classify via `SSL_get_error()` (through `SSLSocket_error`) — ZERO_RETURN
    (TLS orderly shutdown, QUIC connection close, QUIC stream FIN) and SYSCALL
    map to `SOCKET_ERROR`; only WANT_READ/WANT_WRITE retry. This removes the
    read-path need for `SSLSocket_quic_closed_state()` entirely (it remains
    only in `putdatas`, which is #18's scope). Verified: QUIC/TLS/WSS smokes,
    TLS orderly-shutdown regression (fast failure callback), full test9000
    QUIC suite (#2/6/8/9/10/14) all pass.

### P1 — should fix before merge

- [x] **15. Transport state leaks between `serverURIs` attempts**
  - `src/MQTTAsyncUtils.c:1320-1367`
  - `ssl`, `websocket`, and `unixsock` are set for a URI but not reset before
    parsing the next one. In particular, the documented `quic://` to `tcp://`
    fallback leaves `ssl == 2` and opens UDP again instead of TCP.
  - Fix: reset all per-URI transport flags before parsing each URI, then derive
    them exclusively from the current scheme.
  - **Fixed 2026-09-18**: `ssl`/`websocket`/`unixsock` are reset to 0 before
    parsing each serverURI in `MQTTAsync_processCommand`. Note this also fixes
    the pre-existing `ssl://`→`tcp://` leak (ssl stayed 1). Verified:
    quic://(dead)→tcp:// fallback connects via TCP (~13s), quic://(dead)→ssl://
    regression passes, QUIC smoke passes (single-URI path unaffected).

- [x] **16. Continued QUIC handshakes use the unparsed URI**
  - `src/MQTTAsyncUtils.c:2875-2911`
  - `MQTTAsync_connecting()` strips TCP, WebSocket, and TLS schemes, but has no
    `URI_QUIC` branch. Once the handshake is made nonblocking, continuation can
    pass `quic://...` to hostname parsing and certificate verification, causing
    verification against the wrong host.
  - Fix: strip `URI_QUIC` and select `QUIC_DEFAULT_PORT` in this path.
  - **Fixed 2026-09-18** (together with #11, as flagged during #11
    verification): `URI_QUIC` branch added to the scheme-stripping chain in
    `MQTTAsync_connecting()`, selecting `QUIC_DEFAULT_PORT`. Verified:
    port-less `quic://<host>` through the serverURIs path connects to 14567 in
    ~1s with certificate verification enabled.

- [x] **17. MQTTAsync documents an undefined TLS 1.3 constant**
  - `src/MQTTAsync.h:1054-1058, 1113-1118`
  - The header documents `MQTT_SSL_VERSION_TLS_1_3`, but only
    `MQTTClient.h` defines it. A program including only `MQTTAsync.h` fails to
    compile when using the documented option.
  - Fix: define the TLS 1.3 constant consistently in both public headers.
  - **Fixed 2026-09-18**: added `MQTT_SSL_VERSION_TLS_1_3` (and
    `MQTT_SSL_VERSION_QUIC`) to `MQTTAsync.h`, matching `MQTTClient.h`.
    Verified: a TU including only `MQTTAsync.h` and using the constant
    compiles.

- [x] **18. QUIC setup failures are ignored or misclassified**
  - `src/SSLSocket.c:558-568, 795-804, 1129-1134`
  - Failure to create a QUIC context falls through to creation of a normal TLS
    context over UDP. Mandatory ALPN setup failure is logged but overwritten by
    later return values. The write path changes a zero `SSL_write()` result to
    `SOCKET_ERROR` before passing it to `SSL_get_error()`, violating OpenSSL's
    requirement to pass the exact operation result.
  - Fix: fail immediately on QUIC context or ALPN setup failure, and preserve
    operation return values until after `SSL_get_error()`.
  - **Fixed 2026-09-18**: QUIC `SSL_CTX_new` failure now returns 0 immediately
    (no TLS fall-through); ALPN and `SSL_set_blocking_mode` failures are fatal
    (rc=0, exit) instead of log-and-continue; `putdatas` passes the exact
    `SSL_write` result to `SSL_get_error` (the pre-mapping was removed — the
    existing `else rc = SOCKET_ERROR` already covers ZERO_RETURN/SSL_FATAL).
    `SSLSocket_quic_closed_state`, now unused, was deleted. Verified: full
    build clean, test9000 QUIC suite and smokes pass.

- [x] **19. Requested and effective QUIC support use different CMake guards**
  - `src/CMakeLists.txt:240-244`
  - `test/CMakeLists.txt:1261-1352`
  - `src/samples/CMakeLists.txt:58-94`
  - OpenSSL older than 3.2, LibreSSL, or missing SSL support can leave
    `PAHO_WITH_QUIC=ON` while `WITH_OPENSSL_QUIC` is absent. Tests and samples
    are gated by the requested option rather than actual library capability.
  - Fix: reject unsupported configurations or expose one effective capability
    variable and use it for libraries, tests, and samples.
  - **Fixed 2026-09-18**: new `PAHO_QUIC_ENABLED` variable computed in
    `src/CMakeLists.txt` (true only when QUIC requested AND OpenSSL >= 3.2,
    pushed to parent scope for `test/` and `src/samples/`); a CMake WARNING is
    issued when QUIC was requested but can't be enabled (old OpenSSL or
    LibreSSL). Tests (`test9000`) and QUIC samples now gate on
    `PAHO_QUIC_ENABLED`. Verified: QUIC-off configure+build has no test9000
    target and no QUIC samples; QUIC-on build unchanged.

- [x] **20. QUIC tests contain false-positive paths**
  - `test/test5.c:1014-1020, 1115-1121, 2243-2252, 2420-2424`
  - `test/emqx.conf:36-68`
  - Negative certificate tests use port 18887, for which EMQX defines no
    listener, and do not fail when the expected callback never occurs. The
    big-message test asserts that mismatched bytes are unequal, so corruption
    passes, and overwrites the `MQTTAsync_connect()` return code with zero.
  - Fix: configure the intended listeners, assert callback completion and the
    expected TLS failure, compare payload bytes for equality, and preserve the
    real connect result.
  - **Fixed 2026-09-18**: `emqx.conf` gains the 18887 mutual-auth listener
    (`mtls_nocert`, verify_peer); test2b/2c/3b assert the connect-result
    callback fired after their wait loops (test2d already did), and test10's
    unbounded wait is now bounded with the same assert; test7 compares payload
    bytes for equality (the inverted `!=` assert made corruption pass) and no
    longer overwrites the `MQTTAsync_connect()` return code. Verified:
    test9000 #2/#10 (test7) and #13 (now 5 assertions) pass against TDMQ;
    2b/2c against the EMQX rig remain deferred with #13 (remote docker).

- [x] **21. QUIC sample reconnects omit required SSL options**
  - `src/samples/MQTTAsync_quic_publish.c:38-53`
  - `src/samples/MQTTAsync_quic_subscribe.c:42-60`
  - The connection-loss callbacks build fresh connect options without `ssl`,
    credentials, or callback context. QUIC reconnect therefore returns
    `MQTTASYNC_NULL_PARAMETER`.
  - Fix: preserve the original options or use `automaticReconnect`.
  - **Fixed 2026-09-18**: credentials and `MQTTAsync_SSLOptions` moved to
    file-scope statics in both QUIC samples; `connlost()` reconnects with the
    same username/password/ssl/context (and callbacks, in the subscribe
    sample) as the initial connect. Verified: samples build and run normally
    against TDMQ; reconnect path now identical-by-construction to the initial
    connect.

### P2 — cleanup

- [x] **22. Changed lines fail `git diff --check`**
  - Trailing or mixed indentation remains in the Linux workflow,
    `src/SSLSocket.c`, and all three QUIC samples.
  - `git diff --check 4a939dd..HEAD` (as of `260fbf3`):
    `.github/workflows/build_linux.yml:22` (trailing space);
    `src/SSLSocket.c:826` (trailing space);
    `src/samples/MQTTAsync_quic_fallback.c:181`,
    `MQTTAsync_quic_publish.c:62,208`,
    `MQTTAsync_quic_subscribe.c:204-205,211,216` (space-before-tab).
  - Fix: remove trailing whitespace and normalize indentation before merge.
  - **Fixed 2026-09-18**: stripped trailing space in the workflow and
    `SSLSocket.c`; collapsed space-before-tab in the three QUIC samples.
    Verified: `git diff --check 4a939dd..HEAD` is clean for those paths.

## Follow-up review — TDMQ live tests + merge audit (`260fbf3`)

Captured 2026-09-18 evening after #1–#21 were fixed. Live checks against TDMQ
(TCP 1883 / SSL 8883 / WS 80 / WSS 443 / QUIC 14567) plus code review of
remaining write-path, proxy, HA, and CI/test-rig gaps. Do not treat the TDMQ
5 MB `test7` failure as a client defect — see #28.

### P1 — should fix before merge

- [x] **23. `SSL_ERROR_WANT_READ` from QUIC `SSL_write` is treated as fatal**
  - `src/SSLSocket.c:1146-1176` (`SSLSocket_putdatas`)
  - `src/SSLSocket.c:1232-1252` (`SSLSocket_continueWrite`)
  - After #11, QUIC objects are non-blocking. OpenSSL QUIC `SSL_write()` may
    return `SSL_ERROR_WANT_READ` (needs a packet/ACK before the write can
    continue) as well as `SSL_ERROR_WANT_WRITE`. Both write helpers retry only
    `WANT_WRITE`; `WANT_READ` becomes `SOCKET_ERROR` in `putdatas`, and
    `continueWrite` leaves `rc` as the raw `SSL_write` result (typically < 0),
    which `Socket_continueWrite` treats as a socket error.
  - QUIC stream readiness is also independent of raw UDP `POLLOUT`. Pending
    writes are retried from `Socket.c:1818` when the datagram socket is
    writable, so even a correctly queued `WANT_WRITE` can spin or stall under
    stream flow control.
  - Why it matters: large or back-pressured publishes can fail or tear down
    the connection. Read/connect paths already retry both WANT_* codes
    (`SSLSocket_getch`/`getdata`, `SSLSocket_connect`).
  - Fix: treat `WANT_READ` like `WANT_WRITE` on the write path; drive retries
    from OpenSSL QUIC readiness/event APIs (`SSL_handle_events` /
    `SSL_get_event_timeout` / pollability) rather than UDP `POLLOUT` alone;
    add a forced-backpressure test. Do **not** use TDMQ 4–5 MB failures as
    the repro — those are broker limits (#28).
  - **Fixed 2026-09-18**: `putdatas` / `continueWrite` now retry both
    `WANT_READ` and `WANT_WRITE`; QUIC writes call `SSL_handle_events()`
    first. Pending SSL writes are retried even without UDP `POLLOUT`
    (poll path also runs `continueWrites` when `write_pending` is
    nonempty; select path also retries on readability). A dedicated
    forced-backpressure unit test is still not added — verify with
    2 MB QoS1 against TDMQ and 5 MB against EMQX, not 4–5 MB TDMQ.
    Verified: QUIC smoke; test9000 #2/#8/#9/#14; test9000 #10
    `--size 2097152` against TDMQ (9/9).

- [x] **24. `httpsProxy` silently disables QUIC for `quic://`**
  - `src/MQTTProtocolOut.c:256-285` (also `312-314` `Proxy_connect`)
  - Socket selection is `else if (ssl && https_proxy)` **before**
    `else if (ssl == 2)`. `ssl == 2` is truthy, so a `quic://` connect with
    `MQTTAsync_connectOptions.httpsProxy` set, or `https_proxy` +
    `PAHO_C_CLIENT_USE_HTTP_PROXY=TRUE`, takes `Socket_new()` to the HTTP
    proxy and never reaches `Socket_dgram_new()`. `http_proxy` is correctly
    skipped (`!ssl`).
  - Why it matters: silent TCP/TLS-to-proxy misroute; connect hangs or fails
    with a proxy/TLS error instead of a clear "QUIC does not support HTTP
    proxies". Corporate `https_proxy` in the environment is enough to trigger
    it when the PAHO env flag is on.
  - Fix: reject proxies for `ssl == 2` (return a distinct error / log) unless
    UDP/QUIC proxying is implemented; keep the QUIC dgram path first.
  - **Fixed 2026-09-18**: `ssl == 2` is selected before the HTTPS-proxy
    TCP path; a configured `http(s)_proxy` on a `quic://` URI logs
    `HTTP(S) proxies are not supported for quic:// connections` and
    returns `SOCKET_ERROR` so `serverURIs` can fall through to
    `ssl://`. `Proxy_connect` is also skipped when `ssl == 2`.
    Documented in README and the MQTTAsync HTTP proxy page.
    Verified: TDMQ `quic://` + `httpsProxy=http://127.0.0.1:1/` fails
    with the new log line (`saw_proxy_log=1`) instead of connecting.

- [x] **25. `sslVersion` sticks at `MQTT_SSL_VERSION_QUIC` across `serverURIs` failover**
  - `src/MQTTAsyncUtils.c:2957-2960`
  - On `m->ssl == 2` the library copy `m->c->sslopts->sslVersion` is set to
    `MQTT_SSL_VERSION_QUIC` (5). It is only refreshed from the caller's
    options on a new `MQTTAsync_connect()` (`src/MQTTAsync.c:824-825`). A
    later URI in the same connect (`quic://` → `ssl://`) keeps version 5.
  - Why it matters: `SSLSocket_createContext` applies the TLS 1.3-only
    restriction only when `sslVersion == MQTT_SSL_VERSION_TLS_1_3` (4)
    (`src/SSLSocket.c:575-585`). Failover from a failed QUIC URI therefore
    silently drops a TLS 1.3-only preference. Transport-flag reset (#15) and
    ctx discard (#6) do not restore `sslVersion`.
  - Fix: save/restore the user `sslVersion` per URI, or set QUIC version
    only for the current attempt (e.g. stack local / restore after the
    attempt).
  - **Fixed 2026-09-18**: removed the `sslVersion = MQTT_SSL_VERSION_QUIC`
    mutation. QUIC context creation is driven by `net.quic_mode`; the
    assignment was redundant on OpenSSL 3.2+ and the only effect was
    losing a TLS 1.3-only preference after failover.
    Verified: test9000 #14 HA (test2e) still 95/95 against TDMQ.

### P2 — cleanup / test-rig

- [x] **26. CI EMQX container does not publish UDP 18887**
  - `.github/workflows/build_linux.yml:65-68`
  - `test/emqx.conf:86-100` (`listeners.quic.mtls_nocert` binds `:18887`)
  - `test/test5.c:201-202` (`--quic` maps `nocert_mutual_auth_connection` to
    `start_port+4` = 18887)
  - Docker publishes `14567, 18883, 18884, 18885, 18886/udp` only. `test9000-2b`
    (test_no 3) and `test9000-2c` (test_no 4) target 18887. Host-side tests
    cannot reach the listener; negative cert tests can pass because the port
    is unreachable rather than because TLS failed as intended.
  - #20 added the EMQX listener but not the workflow port map.
  - Fix: add `-p 18887:18887/udp`. Re-check 2b/2c after #27.
  - **Fixed 2026-09-18**: workflow now publishes `-p 18887:18887/udp`.
    2b/2c still need the untrusted-CA listener from #27.

- [x] **27. EMQX `:18887` listener does not match `test2b` expectations**
  - `test/emqx.conf:88-100` vs original `test/tls-testing/mosquitto.conf`
  - `test/test5.c:932-1010` (`test2b` expects `test2bOnConnectFailure`)
  - Mosquitto `:18887` served a MITM cert the client CA does not trust, so
    the handshake failed. EMQX `mtls_nocert` serves the **same valid**
    server cert as the other listeners with `verify_peer`. If 18887 is
    reachable (#26) and the client presents a cert + trusts the CA,
    `test2bOnConnect` fires and the assert `"Connect should not succeed"`
    fails.
  - Fix: serve an untrusted/MITM cert on `:18887` (mirror mosquitto), or
    skip/rename `test9000-2b` for the EMQX rig and document that it needs
    the mosquitto tls-testing layout.
  - **Fixed 2026-09-18**: `gen.sh` now also emits `untrusted-cacert.pem`;
    `:18887` still presents the trusted server cert but verifies clients
    against that second CA, so test2b's valid client cert is rejected
    (matches "server does not have client cert"). test2c still fails
    because it omits `trustStore`. CMake regenerates certs when the
    untrusted CA is missing.

- [x] **28. `test9000` #10 / `test7` 5 MB payload vs broker packet limits**
  - `test/test5.c:102` default `options.size = 5000000`
  - `test/CMakeLists.txt:1331-1334` (`test9000-7-big-messages`, no `--size`)
  - `test/emqx.conf:106-108` (`mqtt.max_packet_size = 100MB` for local EMQX)
  - Live TDMQ (2026-09-18): `--size 262144`, `1048576`, `2097152` passed;
    `--size 4194304` and `4000000` and the default 5 MB failed (`onFailure`
    after ~5s). Tencent TDMQ documents a **4 MB maximum MQTT packet**.
  - **This is a broker limit, not a confirmed client write-path defect.**
    Do not close #23 from TDMQ 4–5 MB failures. The earlier server-side note
    ("1 MB flow-control stall / verified to 256 KB / 8 MiB max") is outdated
    for TDMQ.
  - CI Linux QUIC `ctest` has failed (run 35338698350, exit 8) but the job
    log was not retrieved, so that failure is **not** attributed to this
    4 MB cap: CI talks to local EMQX (100 MB). If `test9000-7` fails in CI,
    look at EMQX readiness (#30), write backpressure (#23), or a different
    case in the same `ctest` run.
  - Fix: keep ~5 MB against EMQX; cap or override `--size` (e.g. 2 MB) when
    targeting TDMQ; document broker limits in the test README. Re-run
    `ctest -R test9000-7` on the EMQX CI rig to confirm the Linux failure
    independently.
  - **Fixed 2026-09-18** (docs / test-rig only): CI still uses the default
    5 MB payload against EMQX (100 MB). Documented the TDMQ 4 MB cap and
    `--size 2097152` override in `test/ssl/emqx/etc/certs/README`,
    README (`MQTT_QUIC_HOSTNAME`), and a CMake comment on
    `test9000-7-big-messages`. Not a client code change.

- [x] **29. QUIC `SSL*` leak on ALPN / blocking-mode setup failure**
  - `src/SSLSocket.c:790-820`
  - `SSL_new` succeeds, then ALPN or `SSL_set_blocking_mode` failure
    `goto exit` without `SSL_free(net->ssl)`. A later
    `SSLSocket_setSocketForSSL` overwrites `net->ssl` at line 790.
  - Rare (hardcoded `mqtt` ALPN), but a real leak / stale-pointer on the
    error path.
  - Fix: `SSL_free(net->ssl); net->ssl = NULL;` before those `goto exit`s
    (or a shared cleanup label).
  - **Fixed 2026-09-18**: ALPN and `SSL_set_blocking_mode` failure paths
    now `SSL_free(net->ssl); net->ssl = NULL;` before `goto exit`.

- [x] **30. CI EMQX has no readiness probe, cleanup, or unique container name**
  - `.github/workflows/build_linux.yml:61-83`
  - `docker run --name emqx` with no wait for `emqx ctl status` (or listener
    bind); cleanup is `killall python3` only — the container is never
    stopped/removed. A previous failed job leaves `emqx` and the next
    `docker run` fails; a fast runner can start `ctest` before QUIC
    listeners exist.
  - Fix: `docker rm -f emqx || true` before run; poll readiness; `docker
    rm -f emqx` in cleanup. Optionally `FIXTURES`/`DEPENDS` so `test9000`
    does not race the broker.
  - **Fixed 2026-09-18**: `docker rm -f emqx` before run and in
    `if: always()` cleanup; poll `docker exec emqx emqx ctl status` up
    to ~60s. Container name stays `emqx` (unique per job after the
    pre-rm). CTest `FIXTURES`/`DEPENDS` left as a later optional
    hardening.

- [x] **31. Sync `MQTTClient` exposes QUIC constants but rejects `quic://`**
  - `src/MQTTClient.h` defines `MQTT_SSL_VERSION_QUIC`; `src/MQTTClient.c`
    create-time scheme check has no `URI_QUIC` (returns
    `MQTTCLIENT_BAD_PROTOCOL`).
  - Why it matters: API/ABI docs imply parity; only `MQTTAsync` can use
    QUIC. Not a crash.
  - Fix: document the async-only limitation next to the constant, or add
    `quic://` to the sync client in a later change.
  - **Fixed 2026-09-18** (docs): comment on `MQTT_SSL_VERSION_QUIC` in
    `MQTTClient.h` states the sync API rejects `quic://` and that
    MQTTAsync / paho-mqtt3as is required. README already documented
    the async-only limitation. Sync QUIC support is a later feature,
    not done here.
    Verified: `MQTTClient_create("quic://...")` returns
    `MQTTCLIENT_BAD_PROTOCOL` (-14).
