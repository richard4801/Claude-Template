CREATE TABLE IF NOT EXISTS "pipeline_logs" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"edit_id" text NOT NULL,
	"entry" jsonb NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "pipeline_proposals" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"edit_id" text,
	"change" jsonb NOT NULL,
	"reason" text NOT NULL,
	"status" text NOT NULL,
	"base_version" integer NOT NULL,
	"applied_version" integer,
	"created_at" bigint NOT NULL,
	"decided_at" bigint
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "pipeline_reactions" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"edit_id" text NOT NULL,
	"reaction" text NOT NULL,
	"context" text DEFAULT '' NOT NULL,
	"sentiment" text NOT NULL,
	"folded_version" integer,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "pipeline_skill_versions" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"version" integer NOT NULL,
	"snapshot" jsonb NOT NULL,
	"changelog" jsonb NOT NULL,
	"by" text NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pipeline_logs_edit_idx" ON "pipeline_logs" USING btree ("studio_id","edit_id","id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pipeline_proposals_studio_idx" ON "pipeline_proposals" USING btree ("studio_id","status","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pipeline_reactions_edit_idx" ON "pipeline_reactions" USING btree ("studio_id","edit_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "pipeline_skill_versions_studio_version_idx" ON "pipeline_skill_versions" USING btree ("studio_id","version");