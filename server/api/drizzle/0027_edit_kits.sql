CREATE TABLE IF NOT EXISTS "edit_kits" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"created_by" text NOT NULL,
	"name" text NOT NULL,
	"kit" jsonb NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "edit_kits_studio_idx" ON "edit_kits" USING btree ("studio_id","updated_at");