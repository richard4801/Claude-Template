CREATE TABLE IF NOT EXISTS "camera_assets" (
	"id" text PRIMARY KEY NOT NULL,
	"session_id" text NOT NULL,
	"studio_id" text NOT NULL,
	"kind" text NOT NULL,
	"label" text,
	"storage_key" text NOT NULL,
	"content_type" text NOT NULL,
	"bytes" bigint,
	"state" text NOT NULL,
	"source" text NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "camera_messages" (
	"id" text PRIMARY KEY NOT NULL,
	"session_id" text NOT NULL,
	"role" text NOT NULL,
	"source" text NOT NULL,
	"text" text NOT NULL,
	"tool" jsonb,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "camera_sessions" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"owner_id" text NOT NULL,
	"title" text NOT NULL,
	"brief" text DEFAULT '' NOT NULL,
	"status" text NOT NULL,
	"aspect" text NOT NULL,
	"fps" integer NOT NULL,
	"duration_sec" double precision NOT NULL,
	"target_model" text,
	"presets" jsonb NOT NULL,
	"characters" jsonb NOT NULL,
	"camera_path" jsonb,
	"blocking" jsonb,
	"shot_draft" jsonb,
	"director_history" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"revision" integer DEFAULT 1 NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "mcp_tokens" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"token_hash" text NOT NULL,
	"prefix" text NOT NULL,
	"created_at" bigint NOT NULL,
	"expires_at" bigint,
	"last_used_at" bigint,
	"revoked_at" bigint
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "camera_assets" ADD CONSTRAINT "camera_assets_session_id_camera_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."camera_sessions"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION WHEN duplicate_object THEN null;
END $$;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "camera_messages" ADD CONSTRAINT "camera_messages_session_id_camera_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."camera_sessions"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION WHEN duplicate_object THEN null;
END $$;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "camera_assets_session_idx" ON "camera_assets" USING btree ("session_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "camera_messages_session_idx" ON "camera_messages" USING btree ("session_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "camera_sessions_studio_idx" ON "camera_sessions" USING btree ("studio_id","updated_at");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "mcp_tokens_hash_idx" ON "mcp_tokens" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "mcp_tokens_user_idx" ON "mcp_tokens" USING btree ("user_id");