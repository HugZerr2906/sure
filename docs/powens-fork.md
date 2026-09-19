# Powens integration (personal fork)

This fork adds a Powens (Biapi) provider to Sure: accounts and transactions pulled
from a Powens user access token, with a manual token setup rather than a hosted
OAuth app. It mirrors the existing provider pattern (Up, SimpleFin): a
`*Item` holds the credentials, `*Account` rows hold the provider-side accounts,
`AccountProvider` links them to Sure accounts, and an importer plus processors
turn provider payloads into Sure entries.

Read this before merging upstream or changing anything Powens-related.

## File map

### Fork-only files (upstream never touches these)

| Path | Role |
| --- | --- |
| `app/models/provider/powens.rb` | API client (bearer auth, pagination, typed errors) |
| `app/models/provider/powens_adapter.rb` | Registered adapter (`provider_name` "powens") |
| `app/models/powens_item.rb` | Connection: domain, token, client id, connection state |
| `app/models/powens_item/{importer,provided,syncer,unlinking,sync_complete_event}.rb` | Sync machinery |
| `app/models/powens_account.rb` | Provider account + Powens type mapping |
| `app/models/powens_account/{processor.rb,transactions/processor.rb}` | Balance and transaction processing |
| `app/models/powens_entry/processor.rb` | Transaction → Sure entry (sign flip, pending flag) |
| `app/models/family/powens_connectable.rb` | `has_many :powens_items` |
| `app/controllers/powens_items_controller.rb` | Settings CRUD, setup, connect, renew, callback |
| `app/views/powens_items/*`, `app/views/settings/providers/_powens_panel.html.erb` | UI |
| `config/locales/views/powens_items/{en,fr}.yml` | Copy |
| `db/migrate/20260813000001_*`, `20260919000000_*`, `20260919000001_*`, `20260919000002_*` | Tables and columns |
| `test/{models,controllers}/**/powens*_test.rb` | Tests |

### Modified upstream files (conflict hotspots)

Each carries a small, additive change. After an upstream merge, re-check these
with `git diff upstream/main HEAD -- <file>`:

| File | What this fork adds |
| --- | --- |
| `app/models/family.rb` | `include PowensConnectable` |
| `app/models/transaction.rb` | `powens` in `PENDING_PROVIDERS` |
| `app/models/provider_merchant.rb` | `powens` in the `source` enum |
| `app/models/data_enrichment.rb` | `powens` in the `source` enum |
| `app/models/provider/metadata.rb` | Registry row (EU / Bank / beta / "PO") |
| `app/models/provider_connection_status.rb` | `PROVIDERS` row for PowensItem |
| `app/controllers/settings/providers_controller.rb` | `FAMILY_PANELS`, `PANEL_SYNCABLE_TYPES`, `load_provider_items`, `family_panel_items`, `prepare_show_context` |
| `app/controllers/accounts_controller.rb` | `@powens_items` in `index` and in `preload_latest_sync_metadata_for_index!` |
| `app/views/accounts/index.html.erb` | Powens items rendering + empty-state condition |
| `app/helpers/settings_helper.rb` | `provider_summary` case for "powens" |
| `config/routes.rb` | `powens_items_callback` route (before `resources`) + `resources :powens_items` |
| `config/locales/views/settings/{en,fr}.yml` | `powens_panel` steps and provider tagline |
| `db/schema.rb` | `powens_items` / `powens_accounts` tables and later columns |

## Updating from upstream

```bash
git fetch upstream
git merge upstream/main          # merge, do not rebase: the branch already merged upstream once
bin/rails test && bin/rubocop    # both must be green
```

Conflict guidance:

- The model, controller, helper and locale changes are additive one-liners; keep
  both sides.
- `db/schema.rb` is the noisy one. Upstream's file is authoritative for its own
  format and version. Keep upstream's version, then make sure the four Powens
  migrations' effects are present (`powens_items`, `powens_accounts`, and the
  `client_id`, `connection_state`, `connection_state_source`,
  `access_expires_at` columns). Regenerating the schema locally can rewrite
  thousands of unrelated lines when Rails or Postgres differ; prefer hand-editing
  the Powens blocks and bumping the version to the newest migration.
- `PowensItem` must keep taking `destroy_later` from `DestroyableLater`
  (`test/models/concerns/destroyable_later_test.rb` fails otherwise).

Post-merge checklist (each command should return a hit):

```bash
grep -n powens app/models/transaction.rb app/models/family.rb app/models/provider_merchant.rb
grep -n powens app/models/data_enrichment.rb app/models/provider/metadata.rb app/models/provider_connection_status.rb
grep -n powens app/views/accounts/index.html.erb app/helpers/settings_helper.rb config/routes.rb
grep -c powens_items app/controllers/accounts_controller.rb app/controllers/settings/providers_controller.rb
bin/rails zeitwerk:check
```

Then rebuild and redeploy (see below). A merging upstream can also rename
provider plumbing the adapter relies on (`Provider::Factory`, `AccountProvider`,
`Account::ProviderImportAdapter`); `test/models/provider/powens_test.rb` and
`test/models/powens_item/importer_test.rb` are the fastest signal when that
happens.

## Powens API behaviour verified against the sandbox

Sources: <https://docs.powens.com/api-reference> and live calls against the
account's own domain.

- Base URL `https://{domain}.biapi.pro/2.0`; auth is
  `Authorization: Bearer <user access token>`. `Provider::Powens` only accepts
  `*.biapi.pro` hosts so a pasted domain can never exfiltrate the token.
- `GET /users/me/accounts?all` lists accounts (their `disabled` field marks
  newly discovered ones; Sure enables them on link through
  `POST /users/me/accounts/{id} {disabled: false}`).
- `GET /users/me/accounts/{id}/transactions?limit=1000&min_date=…`, following
  `_links.next.href` until exhausted. History depth is the bank's, not ours:
  Powens guarantees three months, often exposes more (Bourso gave six years).
  The first import asks for everything (`min_date=1900-01-01`); later syncs use a
  seven-day window.
- Account `type` is a plain string in practice (`checking`, `savings`, `csl`,
  `pea`, …) even though the docs show an object; `PowensAccount` accepts both.
  There is no `lep` type: a LEP arrives as `savings`.
- Transactions carry a decimal `value` with banking signs (negative = money out),
  so `PowensEntry::Processor` flips it for Sure; `coming: true` marks pending.
- Transaction ids are stable per account but **not shared between connections**:
  re-adding a bank gives the same transactions new ids.
- A connection aggregates **sources** (`openapi` for PSD2, `directaccess` for the
  rest) that fail independently. `GET /users/me/connections/{id}/sources`
  reports each source's state and `access_expire` (consent, ~180 days).
- `PUT /users/me/connections/{id}` (forced sync) is refused with
  `409 Can't force synchronization` in both `psu_requested` modes: Powens syncs
  each connection once a day on its own schedule. Do not build UI around it.
- `POST /users/me/connections/{id} {"resume": true}` (with `background=true`) is
  the documented resuming signal once the user approved a `decoupled` SCA in
  their bank app. `{"refresh_auth": true}` renews the PSD2 consent.
- `GET /webauth-url?id_connection=…` answers
  `409 already up to date and have a valid token` for an existing connection, and
  the Connect webview **always creates a new connection** for a connector that
  already has one. That is why re-authorizing through the webview is not offered
  in the panel.

## Data-safety rules baked into the integration

- The importer ignores a discovered account whose IBAN (or bank account number)
  matches an already linked account of the same item, so a duplicate Powens
  connection can never surface the same bank account twice.
- Sure never deletes posted transactions; only pending entries that vanish from
  the latest fetch are pruned. History therefore accumulates even though Powens
  exposes a limited window.
- Switching a Sure account to a different Powens connection (needed when a
  connection is irrecoverably stuck) must remap `entries.external_id` from the
  old transaction ids to the new ones, matched on `(date, value)`, and clear the
  id on entries the new connection has not (yet) reported so a later backfill
  claims them instead of duplicating. Doing it without the remap duplicates every
  transaction, because `find_duplicate_transaction` only matches entries without
  an external id.

## Local deployment

The self-hosted instance lives in `/Users/hugomorel/docker-apps/sure` and runs
`sure-powens:latest` for both `web` and `worker` (`compose.yml.bak` is the
original ghcr-based file). Rebuild and redeploy from the repository root:

```bash
cd /Users/hugomorel/Documents/Finance/sure
set -o pipefail                    # a failing build must stop the chain
docker build -t sure-powens:latest .
docker compose -f /Users/hugomorel/docker-apps/sure/compose.yml up -d --force-recreate web worker
```

Notes that cost time to learn: build from the repository directory (a build run in
the compose directory has no Dockerfile), and `up -d` alone does not recreate
containers when the image tag is unchanged — it needs `--force-recreate`.
Migrations run at boot through `bin/docker-entrypoint` (`bin/rails db:prepare`).
