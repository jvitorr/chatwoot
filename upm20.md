# UPM-20: Help Center Article Generation — Phased Rollout

Splitting the production refactor into three shippable phases. Each phase ends in a state that's safe to merge to develop.

## Phase 1 — Foundation: model + helpers

**Goal:** Get the persistence layer and the two business-logic helpers in place without changing any user-visible behavior. Existing `Onboarding::HelpCenterArticleGenerationService` continues to work; nothing is wired to a job yet.

**Scope**
- Migration: `help_center_generations` (account_id, portal_id, status enum, plan jsonb, articles_total, articles_completed, articles_failed, skip_reason, started_at, finished_at, timestamps).
- `HelpCenterGeneration` model — single model, no callbacks yet. Counters live as columns; status enum (pending/curating/generating/completed/skipped).
- `has_many :help_center_generations` on `Account`.
- `Onboarding::HelpCenterCurator` — map + curate, returns `{plan:}` or `{skip_reason:}`.
- `Onboarding::HelpCenterArticleBuilder` — batch_scrape + rewrite + `portal.articles.create!` for one planned article.

**Acceptance**
- `bundle exec rails db:migrate` runs clean; rollback works.
- `HelpCenterGeneration.create!(account:, portal:)` persists with `status: :pending`.
- In a Rails console, `Onboarding::HelpCenterCurator.new(account:, portal:).perform` returns a curated plan for a seeded account; skip path returns `{skip_reason: "..."}`.
- `Onboarding::HelpCenterArticleBuilder` can build a single article given a urls/title/category_id tuple.
- `rubocop` and `pnpm eslint` clean on changed files.

---

## Phase 2 — Production wiring: jobs + trigger

**Goal:** Replace the inline service path with the async job pipeline. Portal creation triggers async help-center generation end-to-end.

**Scope**
- `Onboarding::HelpCenterArticleWriterJob` — single-article worker with `discard_on StandardError`, lock-protected counter increment + completion check on `HelpCenterGeneration`.
- `Onboarding::HelpCenterArticleGenerationJob` — runs curator, creates categories upfront, persists plan + `articles_total`, fans out N writer jobs (one per article).
- `after_create_commit :enqueue_parent_job` on `HelpCenterGeneration`.
- `Onboarding::HelpCenterCreationService` — after a *new* portal is created, `account.help_center_generations.create!(portal:)`.
- Delete `Onboarding::HelpCenterArticleGenerationService` (no callers remain).

**Acceptance**
- Calling `Onboarding::HelpCenterCreationService.new(account, user).perform` for a fresh portal enqueues one parent job and (after curation) N writer jobs visible in Sidekiq UI on the `:low` queue.
- `HelpCenterGeneration#status` transitions pending → curating → generating → completed (or skipped) as work progresses.
- Final `portal.articles.count == generation.articles_completed`; no double-creation when a job is replayed.
- Skip path (no website url / Firecrawl down / <3 articles curated) lands in `status: :skipped` with `skip_reason` filled and no writers enqueued.
- Reusing an existing portal does **not** re-trigger generation.

---

## Phase 3 — Realtime polish

**Goal:** Stream progress to the onboarding UI so the user sees articles arrive instead of waiting on a silent backend.

**Scope**
- ActionCable broadcasts via `ActionCableBroadcastJob.perform_later`, pubsub via `account.administrators.first&.pubsub_token`:
  - `help_center.article_generated` — per writer success (payload: `account_id`, `portal_id`, `article_id`, `title`, `articles_completed`, `articles_total`).
  - `help_center.generation_completed` — on terminal status transition (payload: status, skip_reason, totals).
- Frontend listener wiring (separate FE PR; can ship after BE merges).

**Acceptance**
- With a frontend client subscribed to the admin user's pubsub channel, `article_generated` events fire one per finished writer and `generation_completed` fires exactly once.
- No broadcasts when `account.administrators.first` is nil (guard works; no exception).
- Manual smoke test against a seeded account shows the events in browser devtools or via `bundle exec rails action_cable:diagnose`.

---

## Out of scope (defer)
- Specs (per project convention — add only when explicitly requested).
- Sweeper / timeout-based recovery for hard-crashed writers — accepted trade-off in the main plan.
- Admin tooling (Super Admin re-run button, per-article failure visibility) — open ticket if needed.
- Promotion to a richer schema with per-article child rows — current single-model design is sufficient for MVP; revisit if per-article state becomes load-bearing.
