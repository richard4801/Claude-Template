package studio.muse.app.data

/**
 * Plain, friendly wording for every API error code (plans/api.md). Codes whose server message carries the useful detail
 * (validation, over-allocation) keep the server's message.
 */
object ErrorText {
    const val NOT_ENOUGH_TOKENS = "Not enough tokens. Ask the studio owner for more."
    const val PAUSED_LOW_BALANCE = "Paused: the studio's GPU credit is low"

    /** Codes that end the session: the app goes back to sign-in. */
    val SIGN_OUT_CODES = setOf("unauthorized", "account_disabled")

    fun of(e: ApiException): String = of(e.code, e.message)

    fun of(code: String, serverMessage: String?): String {
        val server = serverMessage?.trim().orEmpty()
        return when (code) {
            "invite_required" -> "MUSE is invite-only. Enter the invite code your studio owner sent you."
            "invite_invalid" -> if (server.contains("different email", ignoreCase = true)) "That invite is for a different email address. Use the email it was sent to."
                else "That invite code isn't valid or has expired. Check it, or ask the studio owner for a new one."
            "email_taken" -> "That email already has an account. Sign in instead."
            "bad_credentials" -> "Wrong email or password."
            "account_disabled" -> "This account is switched off. Ask the studio owner to turn it back on."
            "rate_limited" -> "Too many tries. Wait a minute, then try again."
            "unauthorized" -> "Your session has ended. Please sign in again."
            "attestation_required" -> "Tick both boxes to continue."
            "owner_only" -> "Only the studio owner can do that."
            "insufficient_tokens" -> NOT_ENOUGH_TOKENS
            "insufficient_balance" -> "Not enough GPU credit for this."
            "over_job_limit" -> "This render costs more than the per-job limit. Try fewer steps or takes."
            "over_user_day_limit" -> "You've reached your daily spending cap. Try again tomorrow, or ask the studio owner to raise it."
            "over_day_limit" -> "The studio's daily spending cap is reached. Try again tomorrow."
            "over_allocation" -> server.ifBlank { "That's more than the studio's RunPod balance can back." }
            "balance_unavailable" -> "MUSE can't read the RunPod balance right now, so tokens can't be sent. Try again shortly."
            "topup_unavailable" -> "Top up your RunPod account. MUSE reads the balance from RunPod."
            "engine_unavailable" -> "The GPU can't run this option yet. Try Standard without lip sync."
            "image_engine_failed" -> "The image engine failed. You weren't charged."
            "clip_failed_checks" -> "Fix the clip checks first."
            "not_found" -> "That's no longer there. Pull to refresh."
            "busy" -> "That's already in progress. Wait for it to finish."
            "upload_missing" -> "The file didn't finish uploading. Try again."
            "upload_failed" -> "The upload didn't go through. Check your connection and try again."
            "too_large" -> "That file is too large to upload."
            "offline" -> "Can't reach the MUSE server. Check your connection."
            "bad_response" -> "The server sent something this app version can't read. Update MUSE."
            "server_error" -> "Something went wrong on the server. Try again."
            "bad_signature" -> "The upload link expired. Try again."
            else -> server.ifBlank { "Something went wrong." }
        }
    }
}
