package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.Credit
import studio.muse.app.data.ErrorText
import studio.muse.app.data.InviteCreated

/** Dollars in the UI, integer tokens on the wire (TOKEN_USD = 0.01). */
class CreditTest {
    @Test fun dollarsTypedByTheOwnerBecomeWholeTokens() {
        assertEquals(5.0, Credit.parseUsd("5")!!, 1e-9)
        assertEquals(5.5, Credit.parseUsd("5.50")!!, 1e-9)
        assertEquals(5.5, Credit.parseUsd("$5.5")!!, 1e-9)
        assertEquals(1000.0, Credit.parseUsd("1,000")!!, 1e-9)
        assertEquals(0.5, Credit.parseUsd(".5")!!, 1e-9)
        assertEquals(5.56, Credit.parseUsd("5.555")!!, 1e-9) // nearest cent
        assertNull(Credit.parseUsd("0"))
        assertNull(Credit.parseUsd(""))
        assertNull(Credit.parseUsd("abc"))
        assertNull(Credit.parseUsd("-5"))
        assertEquals(500L, Credit.tokensFor(5.0, 0.01))
        assertEquals(550L, Credit.tokensFor(5.5, 0.01))
        assertEquals(1L, Credit.tokensFor(0.01, 0.01))
        assertEquals(29L, Credit.tokensFor(0.29, 0.01)) // no floating-point drift (0.29 / 0.01 = 28.999…)
        assertEquals(1_000_000L, Credit.tokensFor(10_000.0, 0.01))
        assertEquals(5L, Credit.tokensFor(5.0, 1.0))
        assertEquals("$12.50", Credit.money(Credit.usdOf(1_250, 0.01)))
    }

    @Test fun amountFieldKeepsTwoDecimals() {
        assertEquals("5.50", Credit.filterInput("5.50"))
        assertEquals("5.55", Credit.filterInput("5.555"))
        assertEquals("12.34", Credit.filterInput("$12.3.4"))
        assertEquals("100", Credit.filterInput("1a0b0"))
    }

    @Test fun errorsSayDollarsNotTokens() {
        assertEquals("Not enough credit. Ask the studio owner for more.", ErrorText.of(ApiException("insufficient_tokens", "Not enough tokens · ask the studio owner for more (you have 3)")))
        val over = ErrorText.of(ApiException("over_allocation", "You can send at most 500 tokens (\$5.00): the rest of the RunPod balance is already with members or on hold"))
        assertTrue(over, over.startsWith("You can send at most \$5.00."))
        assertFalse(over, over.contains("token"))
        val back = ErrorText.of(ApiException("bad_request", "They have 250 unused tokens (20 more are on hold for running jobs)"))
        assertEquals("They have \$2.50 of unused credit (\$0.20 more is on hold for running jobs)", back)
        assertFalse(ErrorText.of(ApiException("balance_unavailable", "")).contains("token"))
    }

    @Test fun shareTextComesFromTheServerOrIsBuiltTheSameWay() {
        val inv = InviteCreated("MUSE-AAAA-BBBB-CCCC", "inv1", "maya@studio.com")
        assertEquals(
            "You're invited to MUSE, the AI model studio. 1) Download: https://muse.example/get 2) Sign up with this invite code: MUSE-AAAA-BBBB-CCCC (email: maya@studio.com). The code works once and expires in 14 days.",
            inv.shareMessage("https://muse.example/"),
        )
        assertEquals("from server", inv.copy(shareText = "from server").shareMessage("https://muse.example/"))
        assertFalse(inv.copy(email = null).shareMessage("https://x").contains("email"))
    }
}
