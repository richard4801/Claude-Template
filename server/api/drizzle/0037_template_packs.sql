CREATE TABLE IF NOT EXISTS "edit_template_packs" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"name" text NOT NULL,
	"manifest" jsonb,
	"files" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"media" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"status" text DEFAULT 'received' NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "edit_template_packs_name_idx" ON "edit_template_packs" USING btree ("studio_id","name");