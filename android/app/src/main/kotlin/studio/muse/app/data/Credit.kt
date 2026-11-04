package studio.muse.app.data

import studio.muse.core.Pricing
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * The app shows money as US dollars ("Credit", "Balance") everywhere. The API keeps integer wallet tokens
 * (1 token = `tokenUsd`, $0.01 on the server), so amounts the owner types are converted here and nothing else in the UI
 * mentions tokens.
 */
object Credit {
    /** The server's `TOKEN_USD`, used when a response doesn't carry its own rate. */
    const val DEFAULT_TOKEN_USD = 0.01

    /** "$12.50" */
    fun money(usd: Double): String = Pricing.money(usd)

    /** Tokens → dollars, at [tokenUsd]. Prefer the API's `usd` fields; this is for token-only fields (holds, deltas). */
    fun usdOf(tokens: Long, tokenUsd: Double = DEFAULT_TOKEN_USD): Double = tokens * tokenUsd

    /**
     * A dollar amount typed by the owner ("5", "5.50", "$5.5", "1,000") rounded to the nearest cent, or null when it isn't
     * a positive amount.
     */
    fun parseUsd(text: String): Double? {
        val s = text.trim().removePrefix("$").trim().replace(",", "")
        if (!Regex("""^\d{1,7}(\.\d*)?$|^\.\d+$""").matches(s)) return null
        val cents = BigDecimal(if (s.startsWith(".")) "0$s" else s.trimEnd('.')).setScale(2, RoundingMode.HALF_UP)
        return cents.toDouble().takeIf { it > 0 }
    }

    /** Dollars → whole tokens for the API (rounded to the nearest token, which is a cent at $0.01). */
    fun tokensFor(usd: Double, tokenUsd: Double = DEFAULT_TOKEN_USD): Long {
        val rate = if (tokenUsd > 0) tokenUsd else DEFAULT_TOKEN_USD
        val cents = BigDecimal(usd).setScale(2, RoundingMode.HALF_UP)
        return cents.divide(BigDecimal(rate.toString()), 0, RoundingMode.HALF_UP).toLong()
    }

    /** Keeps what an amount field may hold while typing: digits and one dot with at most 2 decimals. */
    fun filterInput(text: String): String {
        val out = StringBuilder()
        var dot = -1
        for (ch in text) {
            if (ch.isDigit()) { if (dot < 0 || out.length - dot <= 2) out.append(ch) }
            else if (ch == '.' && dot < 0) { dot = out.length; out.append(ch) }
        }
        return out.toString().take(10)
    }

    /**
     * Server or older messages that still count tokens ("They have 500 unused tokens (20 more are on hold…)") said in dollars.
     */
    fun dollarize(message: String, tokenUsd: Double = DEFAULT_TOKEN_USD): String {
        if (!message.contains("token", ignoreCase = true)) return message
        var m = Regex("""(\d[\d,]*) (unused )?tokens?\b""").replace(message) { r ->
            money(usdOf(r.groupValues[1].replace(",", "").toLong(), tokenUsd)) + if (r.groupValues[2].isNotEmpty()) " of unused credit" else ""
        }
        m = Regex("""(\d[\d,]*) more are on hold""").replace(m) { r -> money(usdOf(r.groupValues[1].replace(",", "").toLong(), tokenUsd)) + " more is on hold" }
        return m.replace(Regex("""\btokens?\b""", RegexOption.IGNORE_CASE), "credit")
    }
}
