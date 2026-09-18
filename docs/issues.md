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

- **Per-stream flow control is 1 MB** (`MqttServer.java:359-363`); publishes above
  ~1 MB stall on flow-control refill. Verified to 256 KB only. Cap payloads or test
  the real maximum. Max MQTT packet is 8 MiB.
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

- [ ] **13. Bundled QUIC test certificates are expired**
  - `test/ssl/emqx/etc/certs/cert.pem`
  - `test/ssl/emqx/etc/certs/client-cert.pem`
  - Both certificates expired on 2026-02-12. `openssl verify` now rejects them,
    so positive certificate-authentication tests cannot validate QUIC.
  - Fix: replace or generate maintained test certificates and add an expiry
    check to CI.

- [ ] **14. QUIC read failures are classified without `SSL_get_error()`**
  - `src/SSLSocket.c:951-972, 1010-1033`
  - OpenSSL requires `SSL_get_error()` for every `SSL_read()` result `<= 0`.
    The new zero-result path instead checks only connection-close information,
    which cannot distinguish retry, stream EOF, and all fatal errors. A stream
    FIN or fatal error on an otherwise open QUIC connection can be retried
    indefinitely.
  - Fix: preserve the exact `SSL_read()` result, classify it with
    `SSL_get_error()`, and retry only `SSL_ERROR_WANT_READ`/`WANT_WRITE`.

### P1 — should fix before merge

- [ ] **15. Transport state leaks between `serverURIs` attempts**
  - `src/MQTTAsyncUtils.c:1320-1367`
  - `ssl`, `websocket`, and `unixsock` are set for a URI but not reset before
    parsing the next one. In particular, the documented `quic://` to `tcp://`
    fallback leaves `ssl == 2` and opens UDP again instead of TCP.
  - Fix: reset all per-URI transport flags before parsing each URI, then derive
    them exclusively from the current scheme.

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

- [ ] **17. MQTTAsync documents an undefined TLS 1.3 constant**
  - `src/MQTTAsync.h:1054-1058, 1113-1118`
  - The header documents `MQTT_SSL_VERSION_TLS_1_3`, but only
    `MQTTClient.h` defines it. A program including only `MQTTAsync.h` fails to
    compile when using the documented option.
  - Fix: define the TLS 1.3 constant consistently in both public headers.

- [ ] **18. QUIC setup failures are ignored or misclassified**
  - `src/SSLSocket.c:558-568, 795-804, 1129-1134`
  - Failure to create a QUIC context falls through to creation of a normal TLS
    context over UDP. Mandatory ALPN setup failure is logged but overwritten by
    later return values. The write path changes a zero `SSL_write()` result to
    `SOCKET_ERROR` before passing it to `SSL_get_error()`, violating OpenSSL's
    requirement to pass the exact operation result.
  - Fix: fail immediately on QUIC context or ALPN setup failure, and preserve
    operation return values until after `SSL_get_error()`.

- [ ] **19. Requested and effective QUIC support use different CMake guards**
  - `src/CMakeLists.txt:240-244`
  - `test/CMakeLists.txt:1261-1352`
  - `src/samples/CMakeLists.txt:58-94`
  - OpenSSL older than 3.2, LibreSSL, or missing SSL support can leave
    `PAHO_WITH_QUIC=ON` while `WITH_OPENSSL_QUIC` is absent. Tests and samples
    are gated by the requested option rather than actual library capability.
  - Fix: reject unsupported configurations or expose one effective capability
    variable and use it for libraries, tests, and samples.

- [ ] **20. QUIC tests contain false-positive paths**
  - `test/test5.c:1014-1020, 1115-1121, 2243-2252, 2420-2424`
  - `test/emqx.conf:36-68`
  - Negative certificate tests use port 18887, for which EMQX defines no
    listener, and do not fail when the expected callback never occurs. The
    big-message test asserts that mismatched bytes are unequal, so corruption
    passes, and overwrites the `MQTTAsync_connect()` return code with zero.
  - Fix: configure the intended listeners, assert callback completion and the
    expected TLS failure, compare payload bytes for equality, and preserve the
    real connect result.

- [ ] **21. QUIC sample reconnects omit required SSL options**
  - `src/samples/MQTTAsync_quic_publish.c:38-53`
  - `src/samples/MQTTAsync_quic_subscribe.c:42-60`
  - The connection-loss callbacks build fresh connect options without `ssl`,
    credentials, or callback context. QUIC reconnect therefore returns
    `MQTTASYNC_NULL_PARAMETER`.
  - Fix: preserve the original options or use `automaticReconnect`.

### P2 — cleanup

- [ ] **22. Changed lines fail `git diff --check`**
  - Trailing or mixed indentation remains in the Linux workflow,
    `src/SSLSocket.c`, and all three QUIC samples.
  - Fix: remove trailing whitespace and normalize indentation before merge.
