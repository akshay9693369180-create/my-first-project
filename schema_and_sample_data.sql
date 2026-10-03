-- NCC AI Learning Platform, initial schema migration.
-- Requires PostgreSQL 15+ and pgvector installed on the server.
-- Run this file as a migration owner in a single transaction. Do not run as the app role.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE SCHEMA IF NOT EXISTS learning;
SET LOCAL search_path = learning, public;

CREATE TYPE account_status AS ENUM ('pending', 'active', 'suspended', 'closed');
CREATE TYPE content_status AS ENUM ('draft', 'published', 'archived');
CREATE TYPE difficulty_level AS ENUM ('beginner', 'easy', 'intermediate', 'hard', 'expert');
CREATE TYPE question_kind AS ENUM ('single_choice', 'multiple_choice', 'true_false', 'short_text', 'essay', 'numeric', 'coding');
CREATE TYPE attempt_status AS ENUM ('in_progress', 'submitted', 'graded', 'expired', 'cancelled');
CREATE TYPE enrollment_status AS ENUM ('active', 'completed', 'withdrawn', 'suspended');
CREATE TYPE document_status AS ENUM ('uploaded', 'queued', 'processing', 'ready', 'failed', 'archived');
CREATE TYPE job_status AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');
CREATE TYPE execution_status AS ENUM ('queued', 'running', 'completed', 'failed', 'timed_out', 'rejected');
CREATE TYPE moderation_status AS ENUM ('open', 'in_review', 'actioned', 'dismissed');
CREATE TYPE notification_status AS ENUM ('unread', 'read', 'archived');

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

-- Global identity; tenant access is granted through organization_memberships.
CREATE TABLE organizations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    name text NOT NULL,
    status content_status NOT NULL DEFAULT 'published',
    settings jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email citext NOT NULL UNIQUE,
    password_hash text,
    status account_status NOT NULL DEFAULT 'pending',
    email_verified_at timestamptz,
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK (password_hash IS NULL OR length(password_hash) >= 20)
);

CREATE TABLE profiles (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_name text NOT NULL,
    given_name text,
    family_name text,
    avatar_url text,
    locale text NOT NULL DEFAULT 'en',
    timezone text NOT NULL DEFAULT 'UTC',
    birth_date date,
    preferences jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(preferences) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text,
    is_system boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    description text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE role_permissions (
    role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);
CREATE TABLE organization_memberships (
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status enrollment_status NOT NULL DEFAULT 'active',
    joined_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    PRIMARY KEY (organization_id, user_id)
);
CREATE TABLE user_roles (
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role_id uuid NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    granted_by uuid REFERENCES users(id) ON DELETE SET NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id, role_id),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE TABLE auth_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider text NOT NULL,
    provider_subject text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_subject)
);
CREATE TABLE auth_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (expires_at > created_at)
);

-- Curriculum hierarchy: organization -> course -> semester -> subject -> chapter -> topic.
CREATE TABLE courses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    code text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    status content_status NOT NULL DEFAULT 'draft',
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (organization_id, code), UNIQUE (organization_id, id)
);
CREATE TABLE semesters (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    course_id uuid NOT NULL,
    code text NOT NULL,
    title text NOT NULL,
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    starts_on date,
    ends_on date,
    status content_status NOT NULL DEFAULT 'draft',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),
    UNIQUE (course_id, code), UNIQUE (course_id, sequence_no), UNIQUE (course_id, id),
    FOREIGN KEY (organization_id, course_id) REFERENCES courses(organization_id, id) ON DELETE CASCADE
);
CREATE TABLE subjects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    course_id uuid NOT NULL,
    semester_id uuid,
    code text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    status content_status NOT NULL DEFAULT 'draft',
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (course_id, code), UNIQUE (organization_id, id),
    FOREIGN KEY (organization_id, course_id) REFERENCES courses(organization_id, id) ON DELETE CASCADE,
    FOREIGN KEY (course_id, semester_id) REFERENCES semesters(course_id, id) ON DELETE SET NULL (semester_id)
);
CREATE TABLE chapters (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    subject_id uuid NOT NULL,
    parent_chapter_id uuid,
    code text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    status content_status NOT NULL DEFAULT 'draft',
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (subject_id, code), UNIQUE (subject_id, id), UNIQUE (organization_id, id),
    FOREIGN KEY (organization_id, subject_id) REFERENCES subjects(organization_id, id) ON DELETE CASCADE,
    FOREIGN KEY (subject_id, parent_chapter_id) REFERENCES chapters(subject_id, id) ON DELETE SET NULL (parent_chapter_id)
);
CREATE TABLE topics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    chapter_id uuid NOT NULL,
    parent_topic_id uuid,
    code text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    difficulty difficulty_level NOT NULL DEFAULT 'beginner',
    status content_status NOT NULL DEFAULT 'draft',
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (chapter_id, code), UNIQUE (chapter_id, id), UNIQUE (organization_id, id),
    FOREIGN KEY (organization_id, chapter_id) REFERENCES chapters(organization_id, id) ON DELETE CASCADE,
    FOREIGN KEY (chapter_id, parent_topic_id) REFERENCES topics(chapter_id, id) ON DELETE SET NULL (parent_topic_id)
);
CREATE TABLE course_enrollments (
    organization_id uuid NOT NULL,
    course_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status enrollment_status NOT NULL DEFAULT 'active',
    enrolled_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    PRIMARY KEY (course_id, user_id),
    FOREIGN KEY (organization_id, course_id) REFERENCES courses(organization_id, id) ON DELETE CASCADE,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT
);
CREATE TABLE subject_enrollments (
    organization_id uuid NOT NULL,
    subject_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status enrollment_status NOT NULL DEFAULT 'active',
    enrolled_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    PRIMARY KEY (subject_id, user_id),
    FOREIGN KEY (organization_id, subject_id) REFERENCES subjects(organization_id, id) ON DELETE CASCADE,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT
);
CREATE TABLE learning_materials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    topic_id uuid REFERENCES topics(id) ON DELETE SET NULL,
    title text NOT NULL,
    material_type text NOT NULL CHECK (material_type IN ('article', 'video', 'link', 'document', 'interactive')),
    body text,
    external_url text,
    status content_status NOT NULL DEFAULT 'draft',
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK (body IS NOT NULL OR external_url IS NOT NULL)
);

-- Reusable question bank and normalized answer representation.
CREATE TABLE questions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    topic_id uuid REFERENCES topics(id) ON DELETE SET NULL,
    author_id uuid REFERENCES users(id) ON DELETE SET NULL,
    kind question_kind NOT NULL,
    difficulty difficulty_level NOT NULL DEFAULT 'beginner',
    prompt text NOT NULL,
    points numeric(8,2) NOT NULL DEFAULT 1 CHECK (points >= 0),
    status content_status NOT NULL DEFAULT 'draft',
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (organization_id, id)
);
CREATE TABLE question_options (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
    option_key text NOT NULL,
    body text NOT NULL,
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    is_correct boolean NOT NULL DEFAULT false,
    explanation text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (question_id, option_key), UNIQUE (question_id, sequence_no)
);
CREATE TABLE question_solutions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
    solution_type text NOT NULL CHECK (solution_type IN ('explanation', 'worked_solution', 'rubric', 'reference_code')),
    body text NOT NULL,
    visibility text NOT NULL DEFAULT 'after_attempt' CHECK (visibility IN ('always', 'after_attempt', 'instructor_only')),
    sequence_no integer NOT NULL DEFAULT 1 CHECK (sequence_no > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (question_id, solution_type, sequence_no)
);
CREATE TABLE tags (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name text NOT NULL,
    slug text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, slug)
);
CREATE TABLE question_tags (
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
    tag_id uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (question_id, tag_id)
);
CREATE TABLE question_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    question_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    status attempt_status NOT NULL DEFAULT 'in_progress',
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT,
    FOREIGN KEY (organization_id, question_id) REFERENCES questions(organization_id, id) ON DELETE RESTRICT,
    UNIQUE (question_id, user_id, attempt_no),
    UNIQUE (organization_id, user_id, id),
    UNIQUE (id, question_id)
);
CREATE TABLE submissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    question_id uuid NOT NULL,
    attempt_id uuid,
    response jsonb NOT NULL CHECK (jsonb_typeof(response) IN ('object', 'array', 'string', 'number', 'boolean', 'null')),
    status attempt_status NOT NULL DEFAULT 'submitted',
    submitted_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT,
    FOREIGN KEY (organization_id, question_id) REFERENCES questions(organization_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (organization_id, user_id, attempt_id) REFERENCES question_attempts(organization_id, user_id, id) ON DELETE SET NULL (attempt_id),
    FOREIGN KEY (attempt_id, question_id) REFERENCES question_attempts(id, question_id) ON DELETE SET NULL (attempt_id),
    UNIQUE (organization_id, user_id, id)
);
CREATE TABLE grading_results (
    submission_id uuid PRIMARY KEY REFERENCES submissions(id) ON DELETE CASCADE,
    grader_id uuid REFERENCES users(id) ON DELETE SET NULL,
    score numeric(8,2) NOT NULL CHECK (score >= 0),
    max_score numeric(8,2) NOT NULL CHECK (max_score >= 0 AND score <= max_score),
    is_correct boolean,
    feedback text,
    rubric_result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(rubric_result) = 'object'),
    graded_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Quizzes snapshot question order/points so published attempts remain reproducible.
CREATE TABLE quizzes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    subject_id uuid REFERENCES subjects(id) ON DELETE SET NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    status content_status NOT NULL DEFAULT 'draft',
    max_score numeric(10,2) NOT NULL DEFAULT 0 CHECK (max_score >= 0),
    time_limit_seconds integer CHECK (time_limit_seconds IS NULL OR time_limit_seconds > 0),
    max_attempts integer CHECK (max_attempts IS NULL OR max_attempts > 0),
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (organization_id, id)
);
CREATE TABLE quiz_questions (
    quiz_id uuid NOT NULL REFERENCES quizzes(id) ON DELETE CASCADE,
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE RESTRICT,
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    points numeric(8,2) NOT NULL CHECK (points >= 0),
    PRIMARY KEY (quiz_id, question_id),
    UNIQUE (quiz_id, sequence_no)
);
CREATE TABLE quiz_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    quiz_id uuid NOT NULL,
    user_id uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    status attempt_status NOT NULL DEFAULT 'in_progress',
    started_at timestamptz NOT NULL DEFAULT now(),
    submitted_at timestamptz,
    score numeric(10,2) CHECK (score IS NULL OR (score >= 0 AND score <= max_score)),
    max_score numeric(10,2) NOT NULL CHECK (max_score >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT,
    FOREIGN KEY (organization_id, quiz_id) REFERENCES quizzes(organization_id, id) ON DELETE RESTRICT,
    UNIQUE (quiz_id, user_id, attempt_no)
);
CREATE TABLE quiz_answer_records (
    quiz_attempt_id uuid NOT NULL REFERENCES quiz_attempts(id) ON DELETE CASCADE,
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE RESTRICT,
    response jsonb NOT NULL,
    awarded_points numeric(8,2) CHECK (awarded_points IS NULL OR awarded_points >= 0),
    is_correct boolean,
    answered_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (quiz_attempt_id, question_id)
);

CREATE FUNCTION validate_quiz_answer_record() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_quiz uuid; question_points numeric(8,2);
BEGIN
    SELECT quiz_id INTO target_quiz FROM quiz_attempts WHERE id = NEW.quiz_attempt_id;
    SELECT points INTO question_points FROM quiz_questions
    WHERE quiz_id = target_quiz AND question_id = NEW.question_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'question % is not part of quiz attempt %', NEW.question_id, NEW.quiz_attempt_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF NEW.awarded_points IS NOT NULL AND NEW.awarded_points > question_points THEN
        RAISE EXCEPTION 'awarded points exceed quiz question points' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER quiz_answer_membership_check BEFORE INSERT OR UPDATE ON quiz_answer_records
FOR EACH ROW EXECUTE FUNCTION validate_quiz_answer_record();

-- Learner state, personal study tools, recommendations and gamification.
CREATE TABLE learning_progress (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    subject_id uuid REFERENCES subjects(id) ON DELETE CASCADE,
    chapter_id uuid REFERENCES chapters(id) ON DELETE CASCADE,
    topic_id uuid REFERENCES topics(id) ON DELETE CASCADE,
    question_id uuid REFERENCES questions(id) ON DELETE CASCADE,
    completed_count integer NOT NULL DEFAULT 0 CHECK (completed_count >= 0),
    correct_count integer NOT NULL DEFAULT 0 CHECK (correct_count >= 0 AND correct_count <= completed_count),
    mastery numeric(5,4) NOT NULL DEFAULT 0 CHECK (mastery BETWEEN 0 AND 1),
    last_activity_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE,
    CHECK (num_nonnulls(subject_id, chapter_id, topic_id, question_id) = 1)
);
CREATE UNIQUE INDEX learning_progress_subject_uq ON learning_progress(organization_id, user_id, subject_id) WHERE subject_id IS NOT NULL;
CREATE UNIQUE INDEX learning_progress_chapter_uq ON learning_progress(organization_id, user_id, chapter_id) WHERE chapter_id IS NOT NULL;
CREATE UNIQUE INDEX learning_progress_topic_uq ON learning_progress(organization_id, user_id, topic_id) WHERE topic_id IS NOT NULL;
CREATE UNIQUE INDEX learning_progress_question_uq ON learning_progress(organization_id, user_id, question_id) WHERE question_id IS NOT NULL;
CREATE TABLE learning_history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    event_type text NOT NULL,
    subject_id uuid REFERENCES subjects(id) ON DELETE SET NULL,
    chapter_id uuid REFERENCES chapters(id) ON DELETE SET NULL,
    topic_id uuid REFERENCES topics(id) ON DELETE SET NULL,
    question_id uuid REFERENCES questions(id) ON DELETE SET NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT
);
CREATE TABLE bookmarks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
    label text,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX bookmarks_active_uq ON bookmarks(organization_id, user_id, question_id) WHERE deleted_at IS NULL;
CREATE TABLE notes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    topic_id uuid REFERENCES topics(id) ON DELETE SET NULL,
    question_id uuid REFERENCES questions(id) ON DELETE SET NULL,
    title text NOT NULL,
    body text NOT NULL,
    version integer NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE TABLE study_streaks (
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    current_days integer NOT NULL DEFAULT 0 CHECK (current_days >= 0),
    longest_days integer NOT NULL DEFAULT 0 CHECK (longest_days >= current_days),
    last_study_date date,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE TABLE achievement_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text NOT NULL,
    target_value numeric(12,2) NOT NULL CHECK (target_value > 0),
    criteria jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(criteria) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE user_achievements (
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    achievement_id uuid NOT NULL REFERENCES achievement_definitions(id) ON DELETE RESTRICT,
    progress numeric(12,2) NOT NULL DEFAULT 0 CHECK (progress >= 0),
    achieved_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id, achievement_id),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE TABLE recommendations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    topic_id uuid REFERENCES topics(id) ON DELETE CASCADE,
    question_id uuid REFERENCES questions(id) ON DELETE CASCADE,
    reason text NOT NULL,
    score numeric(8,6) NOT NULL CHECK (score BETWEEN 0 AND 1),
    model_version text,
    generated_at timestamptz NOT NULL DEFAULT now(),
    dismissed_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE,
    CHECK (num_nonnulls(topic_id, question_id) = 1)
);
CREATE INDEX recommendations_user_rank_idx ON recommendations(organization_id, user_id, score DESC, generated_at DESC) WHERE dismissed_at IS NULL;
CREATE TABLE weak_topics (
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    topic_id uuid NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
    confidence numeric(5,4) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    identified_at timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz,
    PRIMARY KEY (organization_id, user_id, topic_id),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);

-- Uploaded objects are stored in private object storage; only opaque keys are kept here.
CREATE TABLE uploaded_files (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    uploaded_by uuid REFERENCES users(id) ON DELETE SET NULL,
    storage_key text NOT NULL UNIQUE,
    original_name text NOT NULL,
    media_type text NOT NULL,
    byte_size bigint NOT NULL CHECK (byte_size >= 0),
    checksum_sha256 bytea,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK (checksum_sha256 IS NULL OR octet_length(checksum_sha256) = 32)
);
CREATE TABLE documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    owner_id uuid REFERENCES users(id) ON DELETE SET NULL,
    title text NOT NULL,
    status document_status NOT NULL DEFAULT 'uploaded',
    current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
    visibility text NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'organization', 'course')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (organization_id, id)
);
CREATE TABLE document_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    file_id uuid NOT NULL REFERENCES uploaded_files(id) ON DELETE RESTRICT,
    version_no integer NOT NULL CHECK (version_no > 0),
    content_sha256 bytea,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, version_no),
    CHECK (content_sha256 IS NULL OR octet_length(content_sha256) = 32)
);
CREATE TABLE processing_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    document_version_id uuid NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    job_type text NOT NULL CHECK (job_type IN ('extract', 'chunk', 'embed', 'reindex')),
    status job_status NOT NULL DEFAULT 'queued',
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    queued_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    error_code text,
    error_detail text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    CHECK (finished_at IS NULL OR started_at IS NOT NULL)
);
CREATE TABLE extracted_text (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_version_id uuid NOT NULL UNIQUE REFERENCES document_versions(id) ON DELETE CASCADE,
    text_content text NOT NULL,
    language_code text,
    extractor_version text NOT NULL,
    extracted_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE document_chunks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    document_version_id uuid NOT NULL REFERENCES document_versions(id) ON DELETE CASCADE,
    chunk_no integer NOT NULL CHECK (chunk_no >= 0),
    content text NOT NULL,
    token_count integer CHECK (token_count IS NULL OR token_count >= 0),
    page_no integer CHECK (page_no IS NULL OR page_no > 0),
    section_path text,
    search_vector tsvector NOT NULL DEFAULT ''::tsvector,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_version_id, chunk_no),
    UNIQUE (organization_id, id)
);
-- 1536 dimensions suit common embedding models; changing model dimensions requires a new column/table.
CREATE TABLE chunk_embeddings (
    chunk_id uuid PRIMARY KEY REFERENCES document_chunks(id) ON DELETE CASCADE,
    embedding_model text NOT NULL,
    embedding vector(1536) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE rag_retrievals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    query_text text NOT NULL,
    query_embedding vector(1536),
    retrieved_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object')
);
CREATE TABLE rag_retrieval_chunks (
    retrieval_id uuid NOT NULL REFERENCES rag_retrievals(id) ON DELETE CASCADE,
    chunk_id uuid NOT NULL REFERENCES document_chunks(id) ON DELETE RESTRICT,
    rank integer NOT NULL CHECK (rank > 0),
    similarity double precision NOT NULL CHECK (similarity BETWEEN 0 AND 1),
    PRIMARY KEY (retrieval_id, chunk_id), UNIQUE (retrieval_id, rank)
);

-- AI conversation ledger and per-call provider/token accounting.
CREATE TABLE ai_prompts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    name text NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    template text NOT NULL,
    variables jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(variables) = 'object'),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (organization_id, name, version)
);
CREATE TABLE ai_conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    title text,
    context_type text,
    context_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE,
    UNIQUE (organization_id, id)
);
CREATE TABLE ai_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
    sequence_no bigint NOT NULL CHECK (sequence_no > 0),
    role text NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
    content text NOT NULL,
    prompt_id uuid REFERENCES ai_prompts(id) ON DELETE SET NULL,
    provider text,
    model text,
    status text NOT NULL DEFAULT 'complete' CHECK (status IN ('streaming', 'complete', 'failed', 'redacted')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (conversation_id, sequence_no)
);
CREATE TABLE model_usage (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    conversation_id uuid REFERENCES ai_conversations(id) ON DELETE SET NULL,
    message_id uuid REFERENCES ai_messages(id) ON DELETE SET NULL,
    provider text NOT NULL,
    model text NOT NULL,
    input_tokens integer NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens integer NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    total_tokens integer GENERATED ALWAYS AS (input_tokens + output_tokens) STORED,
    cost_usd numeric(12,8) CHECK (cost_usd IS NULL OR cost_usd >= 0),
    latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
    recorded_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT
);
CREATE TABLE ai_feedback (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id uuid NOT NULL REFERENCES ai_messages(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    feedback_text text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (message_id, user_id)
);
CREATE TABLE ai_citations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id uuid NOT NULL REFERENCES ai_messages(id) ON DELETE CASCADE,
    chunk_id uuid REFERENCES document_chunks(id) ON DELETE SET NULL,
    source_url text,
    source_title text,
    quote_text text,
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (chunk_id IS NOT NULL OR source_url IS NOT NULL),
    UNIQUE (message_id, sequence_no)
);

-- Coding is orchestrated by an external isolated sandbox; never execute submitted code in PostgreSQL/app web workers.
CREATE TABLE programming_languages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    display_name text NOT NULL,
    runtime_image text NOT NULL,
    version text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE coding_problems (
    question_id uuid PRIMARY KEY REFERENCES questions(id) ON DELETE CASCADE,
    time_limit_ms integer NOT NULL CHECK (time_limit_ms BETWEEN 100 AND 300000),
    memory_limit_mb integer NOT NULL CHECK (memory_limit_mb BETWEEN 16 AND 1048576),
    template_by_language jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(template_by_language) = 'object'),
    checker_type text NOT NULL DEFAULT 'exact' CHECK (checker_type IN ('exact', 'whitespace', 'custom'))
);
CREATE TABLE coding_test_cases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    question_id uuid NOT NULL REFERENCES coding_problems(question_id) ON DELETE CASCADE,
    sequence_no integer NOT NULL CHECK (sequence_no > 0),
    input_data text NOT NULL,
    expected_output text NOT NULL,
    is_sample boolean NOT NULL DEFAULT false,
    points numeric(8,2) NOT NULL DEFAULT 0 CHECK (points >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (question_id, sequence_no)
);
CREATE TABLE code_submissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    question_id uuid NOT NULL REFERENCES coding_problems(question_id) ON DELETE RESTRICT,
    language_id uuid NOT NULL REFERENCES programming_languages(id) ON DELETE RESTRICT,
    source_code text NOT NULL,
    source_sha256 bytea,
    status execution_status NOT NULL DEFAULT 'queued',
    sandbox_job_id text UNIQUE,
    submitted_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE RESTRICT,
    CHECK (source_sha256 IS NULL OR octet_length(source_sha256) = 32)
);
CREATE TABLE execution_results (
    submission_id uuid PRIMARY KEY REFERENCES code_submissions(id) ON DELETE CASCADE,
    status execution_status NOT NULL,
    passed_count integer NOT NULL DEFAULT 0 CHECK (passed_count >= 0),
    total_count integer NOT NULL DEFAULT 0 CHECK (total_count >= passed_count),
    score numeric(8,2) NOT NULL DEFAULT 0 CHECK (score >= 0),
    runtime_ms integer CHECK (runtime_ms IS NULL OR runtime_ms >= 0),
    memory_kb integer CHECK (memory_kb IS NULL OR memory_kb >= 0),
    compile_output text,
    stderr text,
    sandbox_reference text,
    completed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE execution_test_results (
    submission_id uuid NOT NULL REFERENCES code_submissions(id) ON DELETE CASCADE,
    test_case_id uuid NOT NULL REFERENCES coding_test_cases(id) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN ('passed', 'wrong_answer', 'runtime_error', 'time_limit', 'memory_limit', 'skipped')),
    runtime_ms integer CHECK (runtime_ms IS NULL OR runtime_ms >= 0),
    memory_kb integer CHECK (memory_kb IS NULL OR memory_kb >= 0),
    output_hash bytea,
    PRIMARY KEY (submission_id, test_case_id)
);

-- Operational, search, moderation and auditable admin records.
CREATE TABLE search_records (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    query_text text NOT NULL,
    filters jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(filters) = 'object'),
    result_count integer NOT NULL DEFAULT 0 CHECK (result_count >= 0),
    searched_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE saved_searches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    query_text text NOT NULL,
    filters jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(filters) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE,
    UNIQUE (organization_id, user_id, name)
);
CREATE TABLE notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    notification_type text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    status notification_status NOT NULL DEFAULT 'unread',
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    expires_at timestamptz,
    FOREIGN KEY (organization_id, user_id) REFERENCES organization_memberships(organization_id, user_id) ON DELETE CASCADE
);
CREATE TABLE reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    requested_by uuid REFERENCES users(id) ON DELETE SET NULL,
    report_type text NOT NULL,
    status job_status NOT NULL DEFAULT 'queued',
    parameters jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(parameters) = 'object'),
    storage_key text,
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    expires_at timestamptz
);
CREATE TABLE moderation_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
    reporter_id uuid REFERENCES users(id) ON DELETE SET NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    reason text NOT NULL,
    status moderation_status NOT NULL DEFAULT 'open',
    assigned_to uuid REFERENCES users(id) ON DELETE SET NULL,
    resolution text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE TABLE audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
    actor_id uuid REFERENCES users(id) ON DELETE SET NULL,
    action text NOT NULL,
    entity_table text NOT NULL,
    entity_id text,
    before_data jsonb,
    after_data jsonb,
    request_id text,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

-- Useful filtering, join, temporal, FTS and vector indexes.
CREATE INDEX users_status_idx ON users(status) WHERE deleted_at IS NULL;
CREATE INDEX users_login_idx ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX memberships_user_idx ON organization_memberships(user_id, organization_id) WHERE deleted_at IS NULL;
CREATE INDEX user_roles_role_idx ON user_roles(role_id, organization_id, user_id);
CREATE INDEX courses_org_status_idx ON courses(organization_id, status, title) WHERE deleted_at IS NULL;
CREATE INDEX semesters_course_idx ON semesters(course_id, sequence_no) WHERE deleted_at IS NULL;
CREATE INDEX subjects_course_idx ON subjects(course_id, sequence_no) WHERE deleted_at IS NULL;
CREATE INDEX chapters_subject_idx ON chapters(subject_id, sequence_no) WHERE deleted_at IS NULL;
CREATE INDEX topics_chapter_idx ON topics(chapter_id, sequence_no) WHERE deleted_at IS NULL;
CREATE INDEX questions_browse_idx ON questions(organization_id, topic_id, difficulty, created_at DESC) WHERE status = 'published' AND deleted_at IS NULL;
CREATE INDEX questions_kind_idx ON questions(organization_id, kind, difficulty) WHERE status = 'published';
CREATE INDEX question_tags_tag_idx ON question_tags(tag_id, question_id);
CREATE INDEX question_attempts_user_time_idx ON question_attempts(organization_id, user_id, started_at DESC);
CREATE INDEX submissions_user_time_idx ON submissions(organization_id, user_id, submitted_at DESC);
CREATE INDEX quiz_attempts_user_time_idx ON quiz_attempts(organization_id, user_id, started_at DESC);
CREATE INDEX quiz_attempts_quiz_status_idx ON quiz_attempts(quiz_id, status, submitted_at DESC);
CREATE INDEX learning_history_user_time_idx ON learning_history(organization_id, user_id, occurred_at DESC);
CREATE INDEX progress_user_topic_idx ON learning_progress(organization_id, user_id, topic_id) WHERE topic_id IS NOT NULL;
CREATE INDEX notes_owner_updated_idx ON notes(organization_id, user_id, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX documents_org_status_idx ON documents(organization_id, status, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX processing_jobs_queue_idx ON processing_jobs(queued_at) WHERE status = 'queued';
CREATE INDEX document_chunks_fts_idx ON document_chunks USING gin(search_vector);
CREATE INDEX chunk_embeddings_hnsw_idx ON chunk_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 128);
CREATE INDEX ai_conversations_owner_idx ON ai_conversations(organization_id, user_id, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX ai_messages_conversation_idx ON ai_messages(conversation_id, sequence_no);
CREATE INDEX model_usage_org_time_idx ON model_usage(organization_id, recorded_at DESC);
CREATE INDEX model_usage_user_time_idx ON model_usage(user_id, recorded_at DESC) WHERE user_id IS NOT NULL;
CREATE INDEX code_submissions_user_time_idx ON code_submissions(organization_id, user_id, submitted_at DESC);
CREATE INDEX search_records_org_time_idx ON search_records(organization_id, searched_at DESC);
CREATE INDEX notifications_inbox_idx ON notifications(organization_id, user_id, created_at DESC) WHERE status = 'unread';
CREATE INDEX audit_org_time_idx ON audit_events(organization_id, occurred_at DESC);
CREATE INDEX audit_entity_idx ON audit_events(entity_table, entity_id, occurred_at DESC);
CREATE INDEX courses_search_idx ON courses USING gin(search_vector);
CREATE INDEX subjects_search_idx ON subjects USING gin(search_vector);
CREATE INDEX chapters_search_idx ON chapters USING gin(search_vector);
CREATE INDEX topics_search_idx ON topics USING gin(search_vector);
CREATE INDEX questions_search_idx ON questions USING gin(search_vector);
CREATE INDEX materials_search_idx ON learning_materials USING gin(search_vector);
CREATE INDEX question_prompt_trgm_idx ON questions USING gin(prompt gin_trgm_ops);

CREATE FUNCTION update_search_vector() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.search_vector :=
        setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B');
    RETURN NEW;
END;
$$;
CREATE FUNCTION update_question_search_vector() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.search_vector := setweight(to_tsvector('english', coalesce(NEW.prompt, '')), 'A');
    RETURN NEW;
END;
$$;
CREATE FUNCTION update_material_search_vector() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.search_vector := to_tsvector('english', coalesce(NEW.title, '') || ' ' || coalesce(NEW.body, ''));
    RETURN NEW;
END;
$$;
CREATE FUNCTION update_chunk_search_vector() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.search_vector := to_tsvector('english', coalesce(NEW.content, ''));
    RETURN NEW;
END;
$$;

CREATE FUNCTION validate_quiz_total() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_quiz uuid;
    declared_total numeric(10,2);
    calculated_total numeric(10,2);
BEGIN
    IF TG_TABLE_NAME = 'quizzes' THEN
        target_quiz := coalesce(NEW.id, OLD.id);
    ELSE
        target_quiz := coalesce(NEW.quiz_id, OLD.quiz_id);
    END IF;
    SELECT max_score INTO declared_total FROM quizzes WHERE id = target_quiz;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT coalesce(sum(points), 0)::numeric(10,2) INTO calculated_total FROM quiz_questions WHERE quiz_id = target_quiz;
    IF declared_total <> calculated_total THEN
        RAISE EXCEPTION 'quiz % max_score (%) must equal its question point total (%)', target_quiz, declared_total, calculated_total
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER quiz_question_total_check
AFTER INSERT OR UPDATE OR DELETE ON quiz_questions
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_quiz_total();
CREATE CONSTRAINT TRIGGER quiz_declared_total_check
AFTER INSERT OR UPDATE ON quizzes
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_quiz_total();

CREATE FUNCTION refresh_document_status() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_version uuid;
BEGIN
    target_version := coalesce(NEW.document_version_id, OLD.document_version_id);
    UPDATE documents d SET status = CASE
        WHEN EXISTS (SELECT 1 FROM processing_jobs j WHERE j.document_version_id = target_version AND j.status = 'failed') THEN 'failed'::document_status
        WHEN EXISTS (SELECT 1 FROM processing_jobs j WHERE j.document_version_id = target_version AND j.status IN ('queued', 'running')) THEN 'processing'::document_status
        WHEN EXISTS (SELECT 1 FROM extracted_text e WHERE e.document_version_id = target_version)
             AND EXISTS (SELECT 1 FROM document_chunks c WHERE c.document_version_id = target_version) THEN 'ready'::document_status
        ELSE 'queued'::document_status END,
        updated_at = now()
    FROM document_versions v WHERE v.id = target_version AND d.id = v.document_id;
    RETURN NULL;
END;
$$;
CREATE TRIGGER processing_job_document_status
AFTER INSERT OR UPDATE OF status OR DELETE ON processing_jobs
FOR EACH ROW EXECUTE FUNCTION refresh_document_status();
CREATE TRIGGER extracted_text_document_status
AFTER INSERT OR UPDATE OR DELETE ON extracted_text
FOR EACH ROW EXECUTE FUNCTION refresh_document_status();
CREATE TRIGGER document_chunk_document_status
AFTER INSERT OR DELETE ON document_chunks
FOR EACH ROW EXECUTE FUNCTION refresh_document_status();

CREATE FUNCTION record_audit_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_row jsonb; new_row jsonb; entity_key text;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_row := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN new_row := to_jsonb(NEW); END IF;
    entity_key := coalesce(new_row->>'id', old_row->>'id');
    INSERT INTO audit_events (organization_id, actor_id, action, entity_table, entity_id, before_data, after_data, request_id)
    VALUES (
        nullif(coalesce(new_row->>'organization_id', old_row->>'organization_id'), '')::uuid,
        nullif(current_setting('app.user_id', true), '')::uuid,
        lower(TG_OP), TG_TABLE_NAME, entity_key, old_row, new_row,
        nullif(current_setting('app.request_id', true), '')
    );
    RETURN coalesce(NEW, OLD);
END;
$$;
CREATE TRIGGER audit_question_changes AFTER INSERT OR UPDATE OR DELETE ON questions FOR EACH ROW EXECUTE FUNCTION record_audit_event();
CREATE TRIGGER audit_course_changes AFTER INSERT OR UPDATE OR DELETE ON courses FOR EACH ROW EXECUTE FUNCTION record_audit_event();
CREATE TRIGGER audit_role_changes AFTER INSERT OR UPDATE OR DELETE ON user_roles FOR EACH ROW EXECUTE FUNCTION record_audit_event();

CREATE FUNCTION apply_submission_progress() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE submission_row submissions%ROWTYPE; target_topic uuid;
BEGIN
    SELECT * INTO submission_row FROM submissions WHERE id = NEW.submission_id;
    SELECT topic_id INTO target_topic FROM questions WHERE id = submission_row.question_id;
    IF target_topic IS NOT NULL THEN
        INSERT INTO learning_progress (organization_id, user_id, topic_id, completed_count, correct_count, mastery, last_activity_at)
        VALUES (submission_row.organization_id, submission_row.user_id, target_topic, 1,
                CASE WHEN NEW.is_correct THEN 1 ELSE 0 END,
                CASE WHEN NEW.is_correct THEN 1 ELSE 0 END, NEW.graded_at)
        ON CONFLICT (organization_id, user_id, topic_id) WHERE topic_id IS NOT NULL
        DO UPDATE SET completed_count = learning_progress.completed_count + 1,
                      correct_count = learning_progress.correct_count + CASE WHEN NEW.is_correct THEN 1 ELSE 0 END,
                      mastery = (learning_progress.correct_count + CASE WHEN NEW.is_correct THEN 1 ELSE 0 END)::numeric /
                                (learning_progress.completed_count + 1),
                      last_activity_at = greatest(learning_progress.last_activity_at, NEW.graded_at),
                      updated_at = now();
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER grading_updates_progress AFTER INSERT ON grading_results
FOR EACH ROW EXECUTE FUNCTION apply_submission_progress();

CREATE FUNCTION apply_achievement_progress() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE target_org uuid; target_user uuid;
BEGIN
    SELECT organization_id, user_id INTO target_org, target_user FROM submissions WHERE id = NEW.submission_id;
    INSERT INTO user_achievements (organization_id, user_id, achievement_id, progress, achieved_at)
    SELECT target_org, target_user, a.id, 1, CASE WHEN a.target_value <= 1 THEN now() END
    FROM achievement_definitions a WHERE a.code = 'first_correct_answer'
    ON CONFLICT (organization_id, user_id, achievement_id)
    DO UPDATE SET progress = user_achievements.progress + 1,
                  achieved_at = coalesce(user_achievements.achieved_at,
                      CASE WHEN user_achievements.progress + 1 >= (SELECT target_value FROM achievement_definitions WHERE id = user_achievements.achievement_id) THEN now() END),
                  updated_at = now();
    RETURN NEW;
END;
$$;
CREATE TRIGGER correct_answer_updates_achievement AFTER INSERT ON grading_results
WHEN (NEW.is_correct IS TRUE) FOR EACH ROW EXECUTE FUNCTION apply_achievement_progress();

CREATE FUNCTION has_permission(p_organization uuid, p_user uuid, p_permission text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = learning, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM user_roles ur
        JOIN role_permissions rp ON rp.role_id = ur.role_id
        JOIN permissions p ON p.id = rp.permission_id
        JOIN organization_memberships om USING (organization_id, user_id)
        WHERE ur.organization_id = p_organization AND ur.user_id = p_user
          AND p.code = p_permission AND om.status = 'active' AND om.deleted_at IS NULL
    );
$$;
REVOKE ALL ON FUNCTION has_permission(uuid, uuid, text) FROM PUBLIC;

CREATE FUNCTION validate_app_tenant() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE session_org uuid;
BEGIN
    session_org := nullif(current_setting('app.organization_id', true), '')::uuid;
    IF session_org IS NOT NULL AND NEW.organization_id IS DISTINCT FROM session_org THEN
        RAISE EXCEPTION 'row organization does not match the active tenant' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER courses_tenant_check BEFORE INSERT OR UPDATE OF organization_id ON courses FOR EACH ROW EXECUTE FUNCTION validate_app_tenant();
CREATE TRIGGER questions_tenant_check BEFORE INSERT OR UPDATE OF organization_id ON questions FOR EACH ROW EXECUTE FUNCTION validate_app_tenant();
CREATE TRIGGER documents_tenant_check BEFORE INSERT OR UPDATE OF organization_id ON documents FOR EACH ROW EXECUTE FUNCTION validate_app_tenant();

-- updated_at is maintained on mutable entities; immutable event rows intentionally omit it.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['organizations','users','profiles','roles','organization_memberships','courses','semesters','subjects','chapters','topics','learning_materials','questions','question_solutions','quizzes','quiz_attempts','learning_progress','notes','documents','ai_conversations','saved_searches','moderation_records'] LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t || '_set_updated_at', t);
    END LOOP;
END;
$$;
CREATE TRIGGER courses_search_update BEFORE INSERT OR UPDATE OF title, description ON courses FOR EACH ROW EXECUTE FUNCTION update_search_vector();
CREATE TRIGGER subjects_search_update BEFORE INSERT OR UPDATE OF title, description ON subjects FOR EACH ROW EXECUTE FUNCTION update_search_vector();
CREATE TRIGGER chapters_search_update BEFORE INSERT OR UPDATE OF title, description ON chapters FOR EACH ROW EXECUTE FUNCTION update_search_vector();
CREATE TRIGGER topics_search_update BEFORE INSERT OR UPDATE OF title, description ON topics FOR EACH ROW EXECUTE FUNCTION update_search_vector();
CREATE TRIGGER questions_search_update BEFORE INSERT OR UPDATE OF prompt ON questions FOR EACH ROW EXECUTE FUNCTION update_question_search_vector();
CREATE TRIGGER materials_search_update BEFORE INSERT OR UPDATE OF title, body ON learning_materials FOR EACH ROW EXECUTE FUNCTION update_material_search_vector();
CREATE TRIGGER chunks_search_update BEFORE INSERT OR UPDATE OF content ON document_chunks FOR EACH ROW EXECUTE FUNCTION update_chunk_search_vector();

-- Example reporting views. Keep OLTP queries separate from heavyweight reporting workloads.
CREATE VIEW question_performance AS
SELECT q.id AS question_id, q.organization_id, q.topic_id,
       count(s.id) AS submission_count,
       count(*) FILTER (WHERE g.is_correct) AS correct_count,
       avg(g.score / nullif(g.max_score, 0)) AS mean_score_ratio
FROM questions q
LEFT JOIN submissions s ON s.question_id = q.id
LEFT JOIN grading_results g ON g.submission_id = s.id
GROUP BY q.id;

CREATE VIEW organization_ai_usage_daily AS
SELECT organization_id, date_trunc('day', recorded_at)::date AS usage_date,
       provider, model, sum(input_tokens) AS input_tokens,
       sum(output_tokens) AS output_tokens, sum(cost_usd) AS cost_usd
FROM model_usage GROUP BY organization_id, date_trunc('day', recorded_at)::date, provider, model;

CREATE MATERIALIZED VIEW daily_learning_activity AS
SELECT organization_id, user_id, occurred_at::date AS activity_date,
       count(*) AS event_count, count(DISTINCT question_id) AS questions_touched
FROM learning_history GROUP BY organization_id, user_id, occurred_at::date
WITH NO DATA;
CREATE UNIQUE INDEX daily_learning_activity_pk ON daily_learning_activity(organization_id, user_id, activity_date);

-- Seed only stable global RBAC and achievement definitions; tenant-specific data belongs to provisioning.
INSERT INTO roles (code, name, description, is_system) VALUES
    ('student', 'Student', 'Learner access', true),
    ('instructor', 'Instructor', 'Course authoring and grading access', true),
    ('tenant_admin', 'Organization administrator', 'Tenant administration access', true),
    ('platform_admin', 'Platform administrator', 'Platform-wide administration access', true)
ON CONFLICT (code) DO NOTHING;
INSERT INTO permissions (code, description) VALUES
    ('content.read', 'Read published learning content'),
    ('content.write', 'Create and edit learning content'),
    ('assessment.grade', 'Grade learner submissions'),
    ('tenant.manage', 'Manage organization members and settings'),
    ('audit.read', 'Read organization audit events')
ON CONFLICT (code) DO NOTHING;
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r CROSS JOIN permissions p
WHERE (r.code = 'student' AND p.code = 'content.read')
   OR (r.code = 'instructor' AND p.code IN ('content.read', 'content.write', 'assessment.grade'))
   OR (r.code = 'tenant_admin' AND p.code IN ('content.read', 'content.write', 'assessment.grade', 'tenant.manage', 'audit.read'))
ON CONFLICT DO NOTHING;
INSERT INTO achievement_definitions (code, name, description, target_value) VALUES
    ('first_correct_answer', 'First correct answer', 'Answer a question correctly for the first time', 1),
    ('hundred_questions', 'Century', 'Submit 100 question attempts', 100)
ON CONFLICT (code) DO NOTHING;
INSERT INTO programming_languages (code, display_name, runtime_image, version) VALUES
    ('python', 'Python', 'sandbox/python', '3.12'),
    ('javascript', 'JavaScript', 'sandbox/node', '22')
ON CONFLICT (code) DO NOTHING;

-- Basic RLS baseline. Set app.organization_id and app.user_id with SET LOCAL inside each transaction.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['courses','semesters','subjects','chapters','topics','learning_materials','questions','quizzes','documents','document_chunks','processing_jobs','model_usage','reports','moderation_records','search_records','code_submissions','quiz_attempts','question_attempts','submissions','learning_history'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (organization_id = nullif(current_setting(''app.organization_id'', true), '''')::uuid) WITH CHECK (organization_id = nullif(current_setting(''app.organization_id'', true), '''')::uuid)', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['learning_progress','notes','ai_conversations','bookmarks','recommendations','weak_topics','notifications','saved_searches','course_enrollments','subject_enrollments'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY owner_isolation ON %I USING (organization_id = nullif(current_setting(''app.organization_id'', true), '''')::uuid AND user_id = nullif(current_setting(''app.user_id'', true), '''')::uuid) WITH CHECK (organization_id = nullif(current_setting(''app.organization_id'', true), '''')::uuid AND user_id = nullif(current_setting(''app.user_id'', true), '''')::uuid)', t);
    END LOOP;
END;
$$;

COMMIT;