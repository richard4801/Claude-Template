CREATE TABLE IF NOT EXISTS "suite_locations" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"name" text NOT NULL,
	"image" jsonb NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "suite_locations_studio_idx" ON "suite_locations" USING btree ("studio_id");
