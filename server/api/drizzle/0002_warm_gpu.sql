CREATE TABLE "warm_sessions" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"pod_id" text,
	"state" text NOT NULL,
	"started_at" bigint NOT NULL,
	"ready_at" bigint,
	"last_active_at" bigint,
	"settled_until" bigint NOT NULL,
	"cost_usd" double precision DEFAULT 0 NOT NULL,
	"rate_per_hr" double precision NOT NULL,
	"idle_minutes" integer NOT NULL,
	"max_minutes" integer NOT NULL,
	"extended" boolean DEFAULT false NOT NULL,
	"warned_for" text,
	"ended_at" bigint,
	"end_reason" text
);
--> statement-breakpoint
ALTER TABLE "jobs" ADD COLUMN "warm_session_id" text;--> statement-breakpoint
ALTER TABLE "pods" ADD COLUMN "warm_session_id" text;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD COLUMN "warm_gpu_allowed" text;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD COLUMN "warm_idle_minutes" integer;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD COLUMN "warm_max_minutes" integer;--> statement-breakpoint
CREATE INDEX "warm_sessions_user_idx" ON "warm_sessions" USING btree ("user_id","started_at");--> statement-breakpoint
CREATE INDEX "warm_sessions_state_idx" ON "warm_sessions" USING btree ("state");