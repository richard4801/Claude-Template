CREATE TABLE IF NOT EXISTS "recreate_references" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"name" text DEFAULT '' NOT NULL,
	"upload_id" text,
	"storage_key" text,
	"duration_sec" double precision,
	"state" text NOT NULL,
	"progress" double precision DEFAULT 0 NOT NULL,
	"phase" text DEFAULT '' NOT NULL,
	"error" text,
	"recipe" jsonb,
	"contact_sheet_key" text,
	"keep" boolean DEFAULT false NOT NULL,
	"created_at" bigint NOT NULL,
	"expires_at" bigint NOT NULL,
	"deleted_at" bigint
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "recreate_refs_studio_idx" ON "recreate_references" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "recreate_refs_expiry_idx" ON "recreate_references" USING btree ("expires_at");