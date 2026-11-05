CREATE TABLE "editor_jobs" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"kind" text NOT NULL,
	"state" text NOT NULL,
	"source" jsonb NOT NULL,
	"media_key" text,
	"options" jsonb NOT NULL,
	"models" jsonb NOT NULL,
	"estimate" double precision NOT NULL,
	"cost" double precision DEFAULT 0 NOT NULL,
	"hold_tokens" integer DEFAULT 0 NOT NULL,
	"progress" double precision DEFAULT 0 NOT NULL,
	"phase" text DEFAULT '' NOT NULL,
	"prediction_id" text,
	"result" jsonb,
	"error" text,
	"created_at" bigint NOT NULL,
	"finished_at" bigint
);
--> statement-breakpoint
CREATE INDEX "editor_jobs_studio_idx" ON "editor_jobs" USING btree ("studio_id","user_id","created_at");--> statement-breakpoint
CREATE INDEX "editor_jobs_media_idx" ON "editor_jobs" USING btree ("media_key","kind");