CREATE TABLE IF NOT EXISTS "claude_issues" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"dedupe_key" text NOT NULL,
	"source" text NOT NULL,
	"kind" text NOT NULL,
	"severity" text NOT NULL,
	"summary" text NOT NULL,
	"asked" text,
	"page" text,
	"tried" text,
	"error" text,
	"tool" text,
	"reporter_id" text NOT NULL,
	"reporter_role" text NOT NULL,
	"count" integer DEFAULT 1 NOT NULL,
	"first_seen" bigint NOT NULL,
	"last_seen" bigint NOT NULL,
	"status" text DEFAULT 'new' NOT NULL,
	"note" text,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "claude_issues_key_idx" ON "claude_issues" USING btree ("studio_id","dedupe_key");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "claude_issues_seen_idx" ON "claude_issues" USING btree ("studio_id","last_seen");