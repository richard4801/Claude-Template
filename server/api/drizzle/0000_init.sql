CREATE TABLE "accounts" (
	"studio_id" text NOT NULL,
	"model_id" text NOT NULL,
	"platform" text NOT NULL,
	"handle" text NOT NULL,
	"connected_at" bigint NOT NULL,
	"can_post_direct" boolean DEFAULT false NOT NULL,
	"token_enc" text,
	"connected_by" text,
	CONSTRAINT "accounts_model_id_platform_pk" PRIMARY KEY("model_id","platform")
);
--> statement-breakpoint
CREATE TABLE "clips" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"name" text NOT NULL,
	"duration_sec" double precision NOT NULL,
	"width" integer NOT NULL,
	"height" integer NOT NULL,
	"fps" double precision NOT NULL,
	"meta" jsonb NOT NULL,
	"checks" jsonb NOT NULL,
	"storage_key" text,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "generated_images" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text,
	"purpose" text NOT NULL,
	"ref_id" text,
	"provider" text NOT NULL,
	"model" text NOT NULL,
	"prompt" text NOT NULL,
	"negative" text,
	"seed" bigint,
	"cost_usd" double precision DEFAULT 0 NOT NULL,
	"image" jsonb NOT NULL,
	"storage_key" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "invites" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"code_hash" text NOT NULL,
	"email" text,
	"role" text NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL,
	"expires_at" bigint NOT NULL,
	"used_at" bigint,
	"used_by" text
);
--> statement-breakpoint
CREATE TABLE "jobs" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text,
	"kind" text NOT NULL,
	"title" text NOT NULL,
	"model_id" text NOT NULL,
	"model_name" text NOT NULL,
	"outfit_id" text DEFAULT '' NOT NULL,
	"request" jsonb NOT NULL,
	"state" text NOT NULL,
	"progress" double precision DEFAULT 0 NOT NULL,
	"take" integer DEFAULT 1 NOT NULL,
	"step" integer DEFAULT 0 NOT NULL,
	"total_steps" integer DEFAULT 0 NOT NULL,
	"phase" text DEFAULT '' NOT NULL,
	"seconds_left" double precision DEFAULT 0 NOT NULL,
	"total_seconds" double precision DEFAULT 0 NOT NULL,
	"cost" double precision NOT NULL,
	"refunded" double precision DEFAULT 0 NOT NULL,
	"hold_tokens" bigint DEFAULT 0 NOT NULL,
	"warmup_cost" double precision DEFAULT 0 NOT NULL,
	"error" text,
	"retryable" boolean,
	"prompt" text DEFAULT '' NOT NULL,
	"seed" integer NOT NULL,
	"thumb" jsonb,
	"created_at" bigint NOT NULL,
	"started_at" bigint,
	"finished_at" bigint,
	"hidden_at" bigint,
	"blocked" text,
	"queued_at" bigint,
	"gpu_state" text,
	"pod_id" text,
	"claimed_at" bigint,
	"last_progress_at" bigint,
	"gpu_seconds" double precision,
	"actual_cost" double precision,
	"outputs" jsonb,
	"stats" jsonb
);
--> statement-breakpoint
CREATE TABLE "ledger" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text,
	"actor_id" text,
	"job_id" text,
	"kind" text NOT NULL,
	"tokens" bigint DEFAULT 0 NOT NULL,
	"amount_usd" double precision DEFAULT 0 NOT NULL,
	"note" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "loras" (
	"model_id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"version" integer DEFAULT 0 NOT NULL,
	"state" text NOT NULL,
	"use" boolean DEFAULT true NOT NULL,
	"candidates" jsonb NOT NULL,
	"progress" double precision DEFAULT 0 NOT NULL,
	"photo" jsonb NOT NULL,
	"video" jsonb NOT NULL,
	"cost" double precision DEFAULT 0 NOT NULL,
	"trained_on" integer,
	"job_id" text,
	"weights" jsonb DEFAULT '[]'::jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "models" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"name" text NOT NULL,
	"age" integer NOT NULL,
	"niche" text NOT NULL,
	"look" text DEFAULT '' NOT NULL,
	"never_add" jsonb NOT NULL,
	"slots" jsonb NOT NULL,
	"outfit_ids" jsonb NOT NULL,
	"personality" text,
	"notes" text,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "outfits" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"model_id" text NOT NULL,
	"name" text NOT NULL,
	"mode" text NOT NULL,
	"description" text DEFAULT '' NOT NULL,
	"angles" jsonb NOT NULL,
	"state" text NOT NULL,
	"prompt" text DEFAULT '' NOT NULL,
	"seed" integer,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "pods" (
	"id" text PRIMARY KEY NOT NULL,
	"runpod_id" text,
	"simulated" boolean DEFAULT false NOT NULL,
	"studio_id" text NOT NULL,
	"worker_token_hash" text NOT NULL,
	"state" text NOT NULL,
	"gpu_type" text NOT NULL,
	"assigned_user_id" text,
	"started_for_job_id" text,
	"current_job_id" text,
	"capabilities" jsonb,
	"worker_state" text,
	"cost_per_hr" double precision DEFAULT 0 NOT NULL,
	"started_at" bigint NOT NULL,
	"ready_at" bigint,
	"last_heartbeat_at" bigint,
	"busy" boolean DEFAULT false NOT NULL,
	"idle_since" bigint,
	"warmup_charged" boolean DEFAULT false NOT NULL,
	"stopped_at" bigint,
	"error" text
);
--> statement-breakpoint
CREATE TABLE "posts" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text,
	"model_id" text NOT NULL,
	"take_id" text NOT NULL,
	"title" text NOT NULL,
	"thumb" jsonb,
	"platforms" jsonb NOT NULL,
	"caption" text DEFAULT '' NOT NULL,
	"ai_label" boolean DEFAULT false NOT NULL,
	"paid_partnership" boolean DEFAULT false NOT NULL,
	"when" text NOT NULL,
	"due_at" bigint NOT NULL,
	"state" text NOT NULL,
	"created_at" bigint NOT NULL,
	"handoff_at" bigint,
	"posted_at" bigint,
	"stats" jsonb
);
--> statement-breakpoint
CREATE TABLE "sessions" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"studio_id" text NOT NULL,
	"token_hash" text NOT NULL,
	"created_at" bigint NOT NULL,
	"expires_at" bigint NOT NULL,
	"last_used_at" bigint,
	"revoked_at" bigint
);
--> statement-breakpoint
CREATE TABLE "studio_settings" (
	"studio_id" text PRIMARY KEY NOT NULL,
	"image_engine" jsonb,
	"cap_per_job" double precision,
	"cap_per_day" double precision,
	"cap_per_user_day" double precision,
	"sim_balance" double precision DEFAULT 0 NOT NULL,
	"fail_next" boolean DEFAULT false NOT NULL,
	"max_gpus" integer,
	"overhead_payer" text,
	"low_balance_since" bigint
);
--> statement-breakpoint
CREATE TABLE "studios" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "takes" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text,
	"kind" text NOT NULL,
	"job_id" text,
	"model_id" text,
	"index" integer NOT NULL,
	"of" integer NOT NULL,
	"title" text NOT NULL,
	"label" text NOT NULL,
	"engine_label" text DEFAULT '' NOT NULL,
	"cost" double precision NOT NULL,
	"seed" integer NOT NULL,
	"status" text NOT NULL,
	"thumb" jsonb,
	"prompt" text DEFAULT '' NOT NULL,
	"media_key" text,
	"media" jsonb,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "uploads" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"kind" text NOT NULL,
	"storage_key" text NOT NULL,
	"content_type" text NOT NULL,
	"bytes" bigint,
	"sha256" text,
	"state" text NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"email" text NOT NULL,
	"password_hash" text NOT NULL,
	"role" text NOT NULL,
	"attest_adult_rights_original_at" bigint NOT NULL,
	"attest_label_ai_at" bigint NOT NULL,
	"invite_id" text,
	"created_at" bigint NOT NULL,
	"disabled_at" bigint,
	"last_active_at" bigint,
	"cap_per_job" double precision,
	"cap_per_day" double precision
);
--> statement-breakpoint
CREATE TABLE "wallets" (
	"user_id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"tokens" bigint DEFAULT 0 NOT NULL,
	"held" bigint DEFAULT 0 NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "invites" ADD CONSTRAINT "invites_studio_id_studios_id_fk" FOREIGN KEY ("studio_id") REFERENCES "public"."studios"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD CONSTRAINT "studio_settings_studio_id_studios_id_fk" FOREIGN KEY ("studio_id") REFERENCES "public"."studios"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_studio_id_studios_id_fk" FOREIGN KEY ("studio_id") REFERENCES "public"."studios"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "clips_studio_idx" ON "clips" USING btree ("studio_id");--> statement-breakpoint
CREATE UNIQUE INDEX "invites_code_idx" ON "invites" USING btree ("code_hash");--> statement-breakpoint
CREATE INDEX "jobs_studio_idx" ON "jobs" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE INDEX "jobs_gpu_idx" ON "jobs" USING btree ("gpu_state","created_at");--> statement-breakpoint
CREATE INDEX "ledger_studio_time_idx" ON "ledger" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE INDEX "ledger_user_time_idx" ON "ledger" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "models_studio_idx" ON "models" USING btree ("studio_id");--> statement-breakpoint
CREATE INDEX "outfits_studio_idx" ON "outfits" USING btree ("studio_id");--> statement-breakpoint
CREATE INDEX "pods_state_idx" ON "pods" USING btree ("state");--> statement-breakpoint
CREATE INDEX "posts_due_idx" ON "posts" USING btree ("state","due_at");--> statement-breakpoint
CREATE UNIQUE INDEX "sessions_token_idx" ON "sessions" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "takes_studio_idx" ON "takes" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "users_email_idx" ON "users" USING btree (lower("email"));