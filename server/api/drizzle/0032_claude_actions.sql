CREATE TABLE IF NOT EXISTS "claude_actions" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"chat_id" text,
	"tool" text NOT NULL,
	"gate" text NOT NULL,
	"summary" text NOT NULL,
	"price_usd" double precision,
	"call" jsonb NOT NULL,
	"status" text NOT NULL,
	"result" jsonb,
	"error" text,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL,
	"expires_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "claude_actions_user_idx" ON "claude_actions" USING btree ("user_id","status","created_at");