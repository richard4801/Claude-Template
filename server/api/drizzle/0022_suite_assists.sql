CREATE TABLE IF NOT EXISTS "suite_assists" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"draft" jsonb NOT NULL,
	"revision" bigint DEFAULT 0 NOT NULL,
	"pending" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "suite_assists_user_idx" ON "suite_assists" USING btree ("studio_id","user_id","updated_at");