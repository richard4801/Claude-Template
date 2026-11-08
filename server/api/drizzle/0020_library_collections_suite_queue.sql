CREATE TABLE IF NOT EXISTS "library_collection_items" (
	"collection_id" text NOT NULL,
	"take_id" text NOT NULL,
	"added_by" text NOT NULL,
	"added_at" bigint NOT NULL,
	CONSTRAINT "library_collection_items_collection_id_take_id_pk" PRIMARY KEY("collection_id","take_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "library_collections" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "suite_queue" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"title" text NOT NULL,
	"body" jsonb NOT NULL,
	"estimate" double precision NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "library_collection_items_take_idx" ON "library_collection_items" USING btree ("take_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "library_collections_studio_idx" ON "library_collections" USING btree ("studio_id","updated_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "suite_queue_studio_idx" ON "suite_queue" USING btree ("studio_id","created_at");