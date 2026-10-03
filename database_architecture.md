# AI Learning Platform Database Architecture

The executable baseline is [schema_and_sample_data.sql](schema_and_sample_data.sql). It targets PostgreSQL 15+ with `pgvector`, `pg_trgm`, `citext`, and `pgcrypto` installed. The script is a single transactional initial migration; production deployments should split it into versioned migrations after review and apply changes through a migration-only database role.

## 1. Architecture Overview

The schema uses UUID identifiers for independently addressable entities and `bigint` identity keys for append-only event streams. User identity is global; institution data is tenant-scoped by `organization_id` and users gain tenant access through `organization_memberships`. Most content is relational and normalized. JSONB is reserved for provider metadata, variable settings, search filters, model output details, and criteria whose shape is genuinely provider- or feature-specific.

The transaction model is ordinary PostgreSQL ACID. Submit an answer, create its grading result, update progress, and append history in one transaction. External AI, object storage, and code execution work must use an outbox/queue pattern in the service layer; never hold a database transaction open while calling a remote provider or sandbox.

Passwords are represented only by `password_hash` (nullable for federated-only users); use Argon2id or a vetted identity provider. API keys, access tokens, raw payment data, and sandbox credentials are not stored. Auth sessions contain only a hash of a random opaque token.

## 2. Entity Relationships

- `users` has a one-to-one optional `profiles` row; a user may have many external `auth_identities` and revocable `auth_sessions`.
- `organizations` has many `organization_memberships`. Membership and `user_roles` define a user's tenant roles. `roles` and `permissions` are many-to-many through `role_permissions`.
- A `course` has many `semesters` and `subjects`; a subject optionally belongs to a semester and has ordered `chapters`; chapters and topics allow a parent pointer for nested content. Course/subject enrollment are separate many-to-many relations between members and curriculum.
- A topic has many `learning_materials` and may classify many questions. Questions have one kind and difficulty, many options and solutions, and many tags through `question_tags`.
- Users have many question `submissions` and quiz attempts. One submission has at most one `grading_result`. A quiz has many ordered `quiz_questions`; quiz attempts have per-question `quiz_answer_records`.
- A learner has zero or one progress row for each subject/chapter/topic/question scope, many history events, bookmarks, notes, recommendations, weak topics, notifications, and achievement states.
- A document has many immutable `document_versions`; each version references an uploaded object, extracted text, processing jobs, and chunks. A chunk has at most one embedding. RAG retrievals and chunks relate many-to-many through ranked `rag_retrieval_chunks`; AI messages can cite chunks or external URLs.
- A coding question has one `coding_problem`, many test cases, and many user code submissions. A submission has at most one aggregate execution result and many per-test results.
- Audit, search, moderation, usage, and learning history are append-oriented operational/event records.

## 3. Table Catalog and Required Fields

`schema_and_sample_data.sql` contains exact SQL definitions, defaults, PKs, FKs, `NOT NULL`, unique and check constraints. Primary key columns are `id` unless noted. Columns without an explicit `NOT NULL` are optional. Timestamp columns are `timestamptz`; application timestamps must be UTC.

| Area | Tables | Purpose / key relationships |
|---|---|---|
| Tenancy and identity | `organizations`, `users`, `profiles`, `organization_memberships`, `auth_identities`, `auth_sessions` | Tenant root, global account, 1:1 profile, membership, federated identities and hashed sessions. |
| Authorization | `roles`, `permissions`, `role_permissions`, `user_roles` | Normalized RBAC; unique role/permission code; tenant role assignments require membership. |
| Curriculum | `courses`, `semesters`, `subjects`, `chapters`, `topics`, `course_enrollments`, `subject_enrollments`, `learning_materials` | Ordered hierarchy, optional parent pointers and explicit enrollment joins. |
| Assessment bank | `questions`, `question_options`, `question_solutions`, `tags`, `question_tags` | Prompt/type/points, ordered options, explanations and solutions, normalized tags. Correctness is not included in learner-facing answer records. |
| Attempts and grading | `question_attempts`, `submissions`, `grading_results`, `quizzes`, `quiz_questions`, `quiz_attempts`, `quiz_answer_records` | Answer/event records with attempt numbers; score bounds; quiz question snapshots by points/order. |
| Learning state | `learning_progress`, `learning_history`, `bookmarks`, `notes`, `study_streaks`, `achievement_definitions`, `user_achievements`, `recommendations`, `weak_topics` | Current aggregates and learner-owned study state. Progress has exactly one non-null scope FK. |
| File and RAG | `uploaded_files`, `documents`, `document_versions`, `processing_jobs`, `extracted_text`, `document_chunks`, `chunk_embeddings`, `rag_retrievals`, `rag_retrieval_chunks` | Private object-store references, immutable versions, processing lifecycle, searchable chunks and vector retrieval traces. |
| AI | `ai_prompts`, `ai_conversations`, `ai_messages`, `model_usage`, `ai_feedback`, `ai_citations` | Versioned templates, ordered messages, token/cost/latency ledger, feedback and source attribution. |
| Coding | `programming_languages`, `coding_problems`, `coding_test_cases`, `code_submissions`, `execution_results`, `execution_test_results` | Limits and test cases; source and results; secure external sandbox job reference/status. |
| Operations | `search_records`, `saved_searches`, `notifications`, `reports`, `moderation_records`, `audit_events` | Search analytics, stored filters, user inbox, generated artifacts, moderation workflow, audit trail. |

JSONB fields are constrained to objects where expected. They are not substitutes for users, permissions, tags, messages, citations, attempts, or other queryable entities. Every table definition states required/optional columns directly. `created_at`, `updated_at`, `deleted_at`, event times, and entity version fields are present where they have meaning; immutable event tables intentionally do not pretend to be mutable records.

## 4. PostgreSQL DDL

Run [schema_and_sample_data.sql](schema_and_sample_data.sql) for complete `CREATE TYPE`, `CREATE TABLE`, constraints, and seed SQL. It is ordered as extensions/schema/types, identity and RBAC, curriculum, question bank, attempts/quizzes, learner state, documents/RAG, AI, coding, operations, indexes/functions/triggers/views, seeds, then baseline RLS. No broad `ON DELETE CASCADE` is used for tenant roots, users, authored content, audit, or financial-like usage records. Cascades are limited to dependent join/child data and user-owned ephemeral state; historical submissions and documents restrict parent deletion where needed. Soft-delete is a nullable `deleted_at`; active unique rules use partial indexes. Prefer retention jobs and anonymization over physical deletion of audit or assessment history.

The migration deliberately keeps content hierarchy columns and FK relationships explicit. When a hierarchy node is deleted, dependent content rows cascade only where it is safe; learner history uses `SET NULL` so the event survives. Cross-tenant references must be validated by the service and, for high-risk paths, by composite FKs including `organization_id` (the initial migration already does this for core course/subject and membership relationships; extend that pattern to all references before multi-tenant launch).

## 5. Index and Search Design

The migration supplies indexes for tenant filtering, user timelines, lookup joins, active records, enrollment paths, queued jobs, unread notifications, audit entities, and the question browse order. Partial unique indexes enforce one active bookmark and one progress row per learner/scope while permitting soft-deleted history. Add indexes only after observing production query plans; avoid indexing low-selectivity status fields alone.

FTS vectors are maintained by triggers for course, subject, chapter, topic, question, material, and document-chunk content. GIN indexes serve `@@` queries. Example:

```sql
SELECT id, title, ts_rank(search_vector, websearch_to_tsquery('english', $1)) AS rank
FROM learning.questions
WHERE organization_id = $2
  AND status = 'published' AND deleted_at IS NULL
  AND search_vector @@ websearch_to_tsquery('english', $1)
ORDER BY rank DESC, id
LIMIT 30;
```

Use parameterized queries. `pg_trgm` is included for typo-tolerant prompt matching. Use a separate FTS configuration or language column if multilingual content becomes a requirement.

## 6. Vector Search

`chunk_embeddings.embedding` is `vector(1536)`, aligned with widely used embedding model output sizes. Confirm the chosen provider's exact output dimension before ingesting; dimension changes require a new vector column/table and re-embedding, not a silent cast. The HNSW index uses cosine distance (`vector_cosine_ops`); query ordering should use `<=>` (cosine distance) and an appropriate `LIMIT`. L2 uses `<->`; inner product uses `<#>` (negative inner product ordering). HNSW improves approximate recall/latency without training and has a higher memory/build cost; tune `m`, `ef_construction`, and per-query `hnsw.ef_search` from measured recall.

```sql
SELECT c.id, c.content, e.embedding <=> $1::vector AS cosine_distance
FROM learning.chunk_embeddings e
JOIN learning.document_chunks c ON c.id = e.chunk_id
JOIN learning.documents d ON d.id = (SELECT document_id FROM learning.document_versions WHERE id = c.document_version_id)
WHERE c.organization_id = $2 AND d.status = 'ready' AND d.deleted_at IS NULL
ORDER BY e.embedding <=> $1::vector
LIMIT 8;
```

The application must additionally enforce document visibility/ACLs before returning a chunk. For strict tenant isolation, include tenant identity on the embedding row and use a tenant-filtered ANN design, or partition/index per tenant when scale warrants it; ANN post-filtering can return fewer than `k` rows when filters are selective.

## 7. Functions and Triggers

- `set_updated_at()` maintains update timestamps on mutable entities.
- Search-vector functions and table triggers maintain weighted `tsvector` values.
- Deferred quiz-total constraint triggers require `quizzes.max_score` to equal the sum of `quiz_questions.points` at transaction commit. Build/edit quiz and items in one transaction.
- `apply_submission_progress()` updates the topic aggregate after a grading row is inserted. It is intentionally tied to insertion rather than arbitrary grading edits to avoid counting edits as new attempts; corrections/regrades need a dedicated compensating/rebuild procedure.
- `apply_achievement_progress()` updates the seeded `first_correct_answer` achievement when a correct grading row is added. Other achievement rules are best evaluated by an idempotent queue/worker as event criteria evolve.
- `refresh_document_status()` derives processing state from jobs, extracted text and chunks.
- `record_audit_event()` captures before/after JSON for selected high-value tables; add triggers to other privileged mutation tables per audit policy.
- `has_permission()` is a tenant-scoped RBAC check. `validate_app_tenant()` and owner checks enforce transaction-local context on selected write paths.
- Duplicate role grants, tags, question tags, quiz order, attempt numbers, bookmarks and progress scopes are blocked by PK/unique constraints.

Set context in the same transaction as every request, using values verified by trusted middleware:

```sql
BEGIN;
SELECT set_config('app.organization_id', $1, true);
SELECT set_config('app.user_id', $2, true);
SELECT set_config('app.request_id', $3, true);
-- Request work here.
COMMIT;
```

## 8. Views and Analytics

`question_performance` reports attempts, correctness and normalized mean score. `organization_ai_usage_daily` groups model usage by tenant/day/provider/model. `daily_learning_activity` is a materialized view and has a unique index for `REFRESH MATERIALIZED VIEW CONCURRENTLY`; schedule refreshes, or replace it with partitioned rollups once event volume justifies streaming aggregation.

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY learning.daily_learning_activity;

SELECT organization_id, provider, model, sum(input_tokens), sum(output_tokens), sum(cost_usd)
FROM learning.model_usage
WHERE recorded_at >= now() - interval '30 days'
GROUP BY organization_id, provider, model
ORDER BY sum(cost_usd) DESC NULLS LAST;

SELECT subject_id, count(*) AS learners, avg(mastery) AS average_mastery
FROM learning.learning_progress
WHERE subject_id IS NOT NULL
GROUP BY subject_id
ORDER BY average_mastery;
```

## 9. Common Transactions

Register with a password hash generated by a vetted library, then create the user and profile atomically. Provision organization, membership, and initial role in one transaction. Enroll with `INSERT ... ON CONFLICT` only when reactivation semantics are explicit. For quiz submission, lock the attempt row, verify ownership/status/time/max attempts, upsert each answer record, compute from server-side grading rules, write the final score, and transition status in one transaction. Never accept a client-supplied correctness flag or score.

```sql
INSERT INTO learning.bookmarks (organization_id, user_id, question_id)
VALUES ($1, $2, $3)
ON CONFLICT (organization_id, user_id, question_id) WHERE deleted_at IS NULL DO NOTHING;

SELECT q.id, q.prompt, q.difficulty, array_agg(t.name ORDER BY t.name) AS tags
FROM learning.questions q
LEFT JOIN learning.question_tags qt ON qt.question_id = q.id
LEFT JOIN learning.tags t ON t.id = qt.tag_id
WHERE q.organization_id = $1 AND q.status = 'published' AND q.deleted_at IS NULL
  AND ($2::uuid IS NULL OR q.topic_id = $2)
  AND ($3::learning.difficulty_level IS NULL OR q.difficulty = $3)
GROUP BY q.id
ORDER BY q.created_at DESC
LIMIT $4 OFFSET $5;

SELECT id, sequence_no, role, content, created_at
FROM learning.ai_messages
WHERE conversation_id = $1
ORDER BY sequence_no;
```

## 10. Migration Structure and Seed Strategy

Split the baseline into reviewed, immutable migration files as the service matures:

1. `0001_extensions_schema_types.sql`
2. `0002_identity_rbac_tenancy.sql`
3. `0003_curriculum_content.sql`
4. `0004_questions_assessments.sql`
5. `0005_learning_state.sql`
6. `0006_documents_rag.sql`
7. `0007_ai_usage.sql`
8. `0008_coding_sandbox.sql`
9. `0009_operations_audit.sql`
10. `0010_indexes_functions_triggers.sql`
11. `0011_views_rls_seed.sql`

Use a migration ledger, checksum each migration, deploy backward-compatible expand/contract changes, and never edit an already-applied migration. Seed only stable global role/permission/achievement/language definitions idempotently. Create institutions, users, and course catalogs through provisioning/import flows; avoid sample credentials and environment secrets in SQL.

## 11. Security and RLS

Use separate non-login migration/owner roles and a least-privilege application role that does not own tables and has no `BYPASSRLS`. Consider `FORCE ROW LEVEL SECURITY` after validating maintenance workflows. RLS context must be set via transaction-local settings on each pooled connection; never use session-persistent tenant context with connection pooling. The app must authenticate the user before setting `app.user_id` and validate tenant membership before setting `app.organization_id`. Add permission-aware policies for instructors/admins; the baseline only provides tenant and owner isolation, not a full authorization policy matrix. Ensure every tenant-bearing table gets RLS before production and test cross-tenant reads/writes explicitly.

`SECURITY DEFINER` functions must have fixed safe `search_path`, tightly scoped execute grants, and no unsafe dynamic SQL. Encrypt backups and object storage, restrict log access, redact AI prompts/code and PII from telemetry, rotate credentials outside the database, and set statement/lock/idle transaction timeouts. The platform admin role is not granted permissions by the sample seed; add a controlled break-glass process.

## 12. Retention, Backup, and Scale

Set explicit retention by data class: short-lived auth sessions/search telemetry, policy-defined AI prompts/messages and code source, longer-lived assessment records, and immutable audit events. Partition append-only `learning_history`, `model_usage`, `search_records`, `audit_events`, and execution events by month once volume requires it; keep indexes local and define archival/drop windows. Archive encrypted object blobs separately and retain checksums/metadata.

Use managed PostgreSQL or tested streaming replication, point-in-time recovery with continuous WAL archiving, encrypted periodic base backups, and regular restore drills. Treat backup success as unproven until a restore is checked. Run migrations under deployment orchestration with lock timeouts and health checks. Use `EXPLAIN (ANALYZE, BUFFERS)` on real query shapes, connection pooling, bounded concurrency, queue-backed AI/document/sandbox work, and read replicas for analytics only when replication lag is acceptable. Use partitioning and dedicated analytical storage before large dashboards compete with OLTP.

The baseline requires review before production: test the full migration against the exact PostgreSQL/pgvector versions, add comprehensive per-table RLS and role policies, add referential tenant checks to every cross-tenant edge, define privacy/retention policy, and exercise concurrent enrollment, quiz finalization, grading/regrade, and document retries.