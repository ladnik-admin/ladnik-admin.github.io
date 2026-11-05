# LADNIK Control Center Admin Web V1

Release Policy source `65157c7a9c1cfe089a9c1a096ca82d124f488a62` REPOSITORY RELEASED; migration `20261007134558 release_policy_v1` LIVE; admin-control v12 ACTIVE/JWT ON. ADMIN_WEB_HOSTING_UPDATE=PENDING: no canonical production deploy workflow available in this repository/session; existing hosted site unchanged. Owner Releases READ and hosted two-card acceptance PENDING. #81 stays OPEN. [Current release checkpoint](https://github.com/Vlad-Shpilevsky/LADNIK/blob/a37472af13382ddff1b99909ae54848ef0e8b914/docs/RELEASE.md#11-ux-repository-release--2026-10-07).

REPOSITORY INTEGRATED / HOSTED LIVE at `https://ladnik-admin.github.io`. Supplied production evidence: exact allowed browser origin configured, platform-owner login and AI Safety/control PASS. AI gate ENABLED through owner Control Center with immutable `ai.control.set` audit; beta limits unchanged. This corrective stage performs no hosting, deployment or configuration action. Independent Flutter Web package, fixed Control Center API consumer; no mobile repository, SQLite or sync dependency. [Canonical production status](https://github.com/Vlad-Shpilevsky/LADNIK/blob/a37472af13382ddff1b99909ae54848ef0e8b914/docs/RELEASE.md#ladnik-100--52-final-source-freeze).

## Public configuration

Pass public values at compilation with `--dart-define`:

- `SUPABASE_URL`: exact canonical project origin matching `LADNIK_CONTROL_PROJECT_URL` on Edge (no trailing slash/path).
- `SUPABASE_PUBLISHABLE_KEY`: publishable key or legacy anon JWT. Never a secret key, service-role/privileged JWT, database password or provider secret.
- `LADNIK_CONTROL_ENVIRONMENT`: `development`, `staging` or `production`, matching the server environment.

No defaults connect to a project. Missing/invalid configuration displays a closed configuration screen and initializes neither Auth nor Admin requests. Normal email/password Auth is the only login; no registration or admin invitation UI. Supabase persists only its normal Auth session; Admin projections are memory-only. The API independently decides owner access.

Maintenance M7 is SOURCE-only and defaults unqualified/OFF. Its fixed V2 routes
require current Owner authority and fresh server-verified authentication. Use the
existing sign-out/sign-in flow immediately before preparing a mode change, then
confirm the exact command separately. Only a pending command UUID, scoped by
project and actor, is persisted in browser localStorage before SEND. No nonce,
password, JWT or command payload is added to this journal. Denied storage refuses
SEND. Same-origin tabs serialize journal mutations with an exclusive Web Lock;
missing or denied Web Locks also refuses SEND. Refresh/reload and unknown ACK recover by receipt only; UNKNOWN is not
rollback and must not be retried as a new command. Hosting, real Auth/browser
acceptance and the qualified backend rollout remain separate gates.
An exact attempt/environment-bound server proof of SQL rejection can clear that
rejected attempt; refresh and fresh preparation are then required. A generic HTTP
error or unknown/mismatched response cannot clear it or permit a repeated SEND.

## Browser Edge boundary — exact production origin configured

`LADNIK_CONTROL_ALLOWED_ORIGIN` on the existing admin-control Edge must be one exact HTTPS Web origin in staging/production, without trailing slash, path, query or wildcard. Development may explicitly use `http://localhost:PORT` (or configured loopback). Only POST/OPTIONS and Authorization, Content-Type, apikey, X-Client-Info are allowed. Preflight occurs before Auth; POST always passes normal JWT/caller checks and fixed owner-checked RPCs. Foreign origins have no readable CORS. Missing configured origin fails closed; requests without an Origin header still require normal JWT/caller/owner authorization and receive no CORS headers. The normal Supabase Edge JWT verification must remain enabled. This patch configures or deploys nothing remotely.

## Local verification

From `admin_web/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter build web
```

The checkpoint build uses no project defines, intentionally exercising the fail-closed bootstrap, and makes no production calls. Later authorized builds must provide the three public defines above. Build outputs are ignored; do not distribute them as production acceptance.

From the repository root, run Control Center Edge contract/CORS tests and the directly affected static guard:

```sh
npx --yes deno test supabase/functions/admin-control/contract_test.ts supabase/functions/admin-control/cors_test.ts
npx --yes deno check supabase/functions/admin-control/index.ts
python supabase/tests/security_checks.py FoundationSecurity.test_control_center_private_projection_telemetry_and_edge_guardrails
git diff --check
```

Checkpoint results: 27 Admin Web tests passed; Flutter analysis reported no issues; Web build passed; 8 Edge contract/CORS tests passed; Edge type check and the affected static security guard passed. The Web build emitted a Cupertino font warning; this package uses Material icons.

Tests use fake Auth/API projections only; they do not connect to Supabase or execute PostgreSQL. Supplied hosted platform-owner login and AI Safety/control acceptance are PASS as recorded above; local checks alone do not establish that acceptance. No mobile suite, backend runtime harness, Codemagic or Android/iOS build belongs to this batch.

## Scope and lifecycle

Overview preserves exact/unavailable/lower-bound counters. Users use a bounded page and username-prefix search; detail contains only approved safe account metadata and observations. Health preserves healthy/degraded/incident/unknown. Releases is labelled self-reported heartbeat, without active-user or DAU claims. Audit remains read-only with paired cursor navigation and allowlisted boolean/state/status/expiry diffs. The independent Trust & Safety patch adds Moderation queue/detail and only fixed report_status/account_state actions with explicit confirmation, required reason, optional duration, correlation replay and refresh. It exposes safe account/report metadata and caller-provided explanation, never private Workspace content. Owner restriction/suspension is unavailable and rejected server-side. No cleanup, arbitrary query, billing or multi-admin controls. Historical independent Moderation checkpoint: COMMITTED / PUSHED / NOT DEPLOYED; migration NOT LIVE; cleanup NOT RUN; scheduler NOT CONFIGURED; production unchanged at that time. Canonical contracts: [Architecture](https://github.com/Vlad-Shpilevsky/LADNIK/blob/a37472af13382ddff1b99909ae54848ef0e8b914/docs/ARCHITECTURE.md#trust--safety--moderation-v1--repository-integrated--not-distributed--migration-not-live).

HISTORICAL repository-integration checkpoint: NOT DEPLOYED, migrations NOT LIVE and platform owner NOT BOOTSTRAPPED at that time. Current hosted/owner acceptance is recorded at the top; historical local build/test results alone do not establish production acceptance. [Architecture](https://github.com/Vlad-Shpilevsky/LADNIK/blob/a37472af13382ddff1b99909ae54848ef0e8b914/docs/ARCHITECTURE.md#control-center-admin-web-v1--current-patch--not-deployed) is the canonical contract.

## AI Safety — hosted production acceptance

Fixed owner actions ai.control.get/set show typed limits, UTC counters/windows and gate status. Disable/Enable/Update require confirmation and reason; retries reuse a correlation ID. Monetary cost is UNAVAILABLE. No privileged key/prompt/audio display. AI Safety/control is LIVE PASS; gate ENABLED and unchanged configured limits are recorded above. Initial migration NOT LIVE / Admin NOT DEPLOYED status is historical. See [security release gate](../docs/SECURITY_RELEASE_GATE.md).
