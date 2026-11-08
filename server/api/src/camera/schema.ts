// Camera sessions (Directed camera mode), their assets and transcript, and MCP personal access tokens
// (plans/api.md "MCP & camera sessions", plans/mcp-bridge.md). Migration 0008. Re-exported from db/schema.ts.
import { bigint, boolean, index, integer, jsonb, doublePrecision, pgTable, text, uniqueIndex } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

export type Vec3 = [number, number, number];
export type CamKey = { t: number; position: Vec3; target?: Vec3; focalMm?: number; rollDeg?: number; ease?: 'linear' | 'in' | 'out' | 'in_out' };
export type CharKey = { t: number; position: Vec3; facingDeg?: number; action?: string };
export type CameraPath = { keyframes: CamKey[]; cuts?: number[]; sensorMm?: number };
export type CharacterBlocking = { modelId: string; keyframes: CharKey[]; note?: string };
export type Blocking = { characters: CharacterBlocking[] };
export type CastMember = { modelId: string; role?: string; heightM?: number };
export type CameraPresets = { rig?: string; move?: string; angle?: string; intensity?: number };
export type CameraStatus = 'drafting' | 'blocking' | 'rendering' | 'ready' | 'generating' | 'done' | 'failed';
export type ShotDraftRow = {
  id: string; state: 'draft'; source: 'suite' | 'camera'; prompt: string; targetModel: string; durationSec: number; aspect: string;
  estimate: { usd: number; tokens: number }; camera: Record<string, unknown>; createdAt: number;
  /** The suite ShotRequest to send when the owner presses Generate (POST /v1/suite/shots). */
  request?: Record<string, unknown>; warnings?: string[];
  /** The render job the owner started from this draft (POST /v1/suite/shots), linked back by the app. */
  jobId?: string; linkedAt?: number;
};

export const cameraSessions = pgTable('camera_sessions', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  ownerId: text('owner_id').notNull(),
  title: text('title').notNull(),
  brief: text('brief').notNull().default(''),
  status: text('status').notNull().$type<CameraStatus>(),
  aspect: text('aspect').notNull(),
  fps: integer('fps').notNull(),
  durationSec: doublePrecision('duration_sec').notNull(),
  targetModel: text('target_model'),
  presets: jsonb('presets').$type<CameraPresets>().notNull(),
  characters: jsonb('characters').$type<CastMember[]>().notNull(),
  cameraPath: jsonb('camera_path').$type<CameraPath>(),
  blocking: jsonb('blocking').$type<Blocking>(),
  shotDraft: jsonb('shot_draft').$type<ShotDraftRow>(),
  /** The in-app chat's Claude conversation (append-only, full content blocks so thinking and caching survive). */
  directorHistory: jsonb('director_history').$type<unknown[]>().notNull().default([]),
  revision: integer('revision').notNull().default(1),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('camera_sessions_studio_idx').on(t.studioId, t.updatedAt)]);

export type CameraAssetKind = 'greybox' | 'depth' | 'pose' | 'tracks' | 'keyframe_start' | 'keyframe_mid' | 'keyframe_end' | 'still' | 'preview'
  | 'camera_json' | 'characters_json' | 'blend';

export const cameraAssets = pgTable('camera_assets', {
  id: text('id').primaryKey(),
  sessionId: text('session_id').notNull().references(() => cameraSessions.id, { onDelete: 'cascade' }),
  studioId: text('studio_id').notNull(),
  kind: text('kind').notNull().$type<CameraAssetKind>(),
  label: text('label'),
  storageKey: text('storage_key').notNull(),
  contentType: text('content_type').notNull(),
  bytes: bigint('bytes', { mode: 'number' }),
  state: text('state').notNull().$type<'pending' | 'ready'>(),
  source: text('source').notNull().$type<'app' | 'mcp' | 'relay' | 'chat'>(),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
}, t => [index('camera_assets_session_idx').on(t.sessionId, t.createdAt)]);

export const cameraMessages = pgTable('camera_messages', {
  id: text('id').primaryKey(),
  sessionId: text('session_id').notNull().references(() => cameraSessions.id, { onDelete: 'cascade' }),
  role: text('role').notNull().$type<'user' | 'assistant' | 'tool'>(),
  source: text('source').notNull().$type<'app' | 'chat' | 'mcp'>(),
  text: text('text').notNull(),
  tool: jsonb('tool').$type<{ name: string; ok: boolean; summary: string }>(),
  createdAt: ms('created_at').notNull(),
}, t => [index('camera_messages_session_idx').on(t.sessionId, t.createdAt)]);

/** Personal access tokens for the MUSE MCP server (owner only). Only a sha256 of the token is stored. */
export const mcpTokens = pgTable('mcp_tokens', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  name: text('name').notNull(),
  tokenHash: text('token_hash').notNull(),
  prefix: text('prefix').notNull(),
  createdAt: ms('created_at').notNull(),
  expiresAt: ms('expires_at'),
  lastUsedAt: ms('last_used_at'),
  revokedAt: ms('revoked_at'),
}, t => [uniqueIndex('mcp_tokens_hash_idx').on(t.tokenHash), index('mcp_tokens_user_idx').on(t.userId)]);

// ---------------------------------------------------------------- OAuth 2.1 for /mcp (migration 0011)
/** Dynamically registered clients (Client ID Metadata Document clients are fetched, not stored). */
export const oauthClients = pgTable('oauth_clients', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  redirectUris: jsonb('redirect_uris').$type<string[]>().notNull(),
  createdAt: ms('created_at').notNull(),
});

/** Authorization codes: single use, 10 minutes, bound to client, redirect, PKCE challenge, resource and scopes. */
export const oauthCodes = pgTable('oauth_codes', {
  codeHash: text('code_hash').primaryKey(),
  clientId: text('client_id').notNull(),
  clientName: text('client_name').notNull(),
  userId: text('user_id').notNull(),
  studioId: text('studio_id').notNull(),
  redirectUri: text('redirect_uri').notNull(),
  codeChallenge: text('code_challenge').notNull(),
  resource: text('resource').notNull(),
  scopes: jsonb('scopes').$type<string[]>().notNull(),
  expiresAt: ms('expires_at').notNull(),
  usedAt: ms('used_at'),
});

/** Access and refresh tokens (sha256 only). `grantId` groups one consent's rotating tokens. */
export const oauthTokens = pgTable('oauth_tokens', {
  id: text('id').primaryKey(),
  grantId: text('grant_id').notNull(),
  kind: text('kind').notNull().$type<'access' | 'refresh'>(),
  tokenHash: text('token_hash').notNull(),
  clientId: text('client_id').notNull(),
  clientName: text('client_name').notNull(),
  userId: text('user_id').notNull(),
  studioId: text('studio_id').notNull(),
  scopes: jsonb('scopes').$type<string[]>().notNull(),
  audience: text('audience').notNull(),
  createdAt: ms('created_at').notNull(),
  expiresAt: ms('expires_at').notNull(),
  usedAt: ms('used_at'),
  lastUsedAt: ms('last_used_at'),
  revokedAt: ms('revoked_at'),
}, t => [uniqueIndex('oauth_tokens_hash_idx').on(t.tokenHash), index('oauth_tokens_grant_idx').on(t.grantId), index('oauth_tokens_user_idx').on(t.userId)]);

// ---------------------------------------------------------------- Claude chat threads (Mac Claude Code + phone relay)
export const claudeThreads = pgTable('claude_threads', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  ownerId: text('owner_id').notNull(),
  contextKind: text('context_kind').notNull().$type<'camera' | 'edit' | 'recreate' /* workstream 1: a Recreate reference */ | 'suite' /* workstream 1: a Suite shot Claude sets up */>(),
  contextId: text('context_id').notNull(),
  claudeSessionId: text('claude_session_id'),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [uniqueIndex('claude_threads_context_idx').on(t.ownerId, t.contextKind, t.contextId)]);

export const claudeMessages = pgTable('claude_messages', {
  id: text('id').primaryKey(),
  threadId: text('thread_id').notNull().references(() => claudeThreads.id, { onDelete: 'cascade' }),
  role: text('role').notNull().$type<'user' | 'assistant' | 'tool'>(),
  source: text('source').notNull().$type<'mac' | 'phone' | 'api'>(),
  text: text('text').notNull().default(''),
  turnId: text('turn_id'),
  tool: jsonb('tool').$type<{ id: string; name: string; ok?: boolean; summary?: string }>(),
  imageKey: text('image_key'),
  /** workstream 1: reference images the owner attached (camera/claudeAttachments.ts). */
  attachments: jsonb('attachments').$type<import('./claudeAttachments.js').Attachment[]>(),
  createdAt: ms('created_at').notNull(),
}, t => [index('claude_messages_thread_idx').on(t.threadId, t.createdAt)]);

export const claudeTurns = pgTable('claude_turns', {
  id: text('id').primaryKey(),
  threadId: text('thread_id').notNull().references(() => claudeThreads.id, { onDelete: 'cascade' }),
  ownerId: text('owner_id').notNull(),
  text: text('text').notNull(),
  /** workstream 1: the message's attached images, for the Mac's Claude Code turn. */
  attachments: jsonb('attachments').$type<import('./claudeAttachments.js').Attachment[]>(),
  from: text('from').notNull().$type<'phone' | 'mac'>(),
  state: text('state').notNull().$type<'queued' | 'running' | 'done' | 'failed' | 'stopped'>(),
  error: text('error'),
  createdAt: ms('created_at').notNull(),
  claimedAt: ms('claimed_at'),
  lastEventAt: ms('last_event_at'),
  finishedAt: ms('finished_at'),
}, t => [index('claude_turns_thread_idx').on(t.threadId, t.createdAt)]);

export const claudeSettings = pgTable('claude_settings', {
  studioId: text('studio_id').primaryKey(),
  apiFallback: boolean('api_fallback').notNull().default(false),
  updatedAt: ms('updated_at').notNull(),
});
