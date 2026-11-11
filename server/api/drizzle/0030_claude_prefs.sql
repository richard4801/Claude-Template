CREATE TABLE IF NOT EXISTS "claude_prefs" (
	"user_id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"default_model" text,
	"updated_at" bigint NOT NULL
);
