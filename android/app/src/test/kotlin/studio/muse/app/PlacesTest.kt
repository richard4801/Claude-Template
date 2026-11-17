package studio.muse.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PlaceCreate
import studio.muse.app.data.PlacePatch
import studio.muse.app.data.PlacePhotoRequest
import studio.muse.app.data.Places
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteLocation

/** Her world, phase 1 (plans/model-world.md): places, their tags, the @ order and priced place photos (demo). */
class PlacesTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }

    @Test fun tagsAsTheServerMakesThem() {
        assertEquals("cafe-by-the-gym", Places.tagFrom("Café by the gym"))
        assertEquals("place", Places.tagFrom("  !!! "))
    }

    @Test fun decodesAPlaceAndAnOlderLocation() {
        val p = json.decodeFromString(SuiteLocation.serializer(),
            """{"id":"loc_1","name":"Café by the gym","tag":"cafe","modelId":"m1","cover":1,"image":{"asset":"b"},"images":[{"asset":"a","source":"upload"},{"url":"https://x/b.jpg","source":"description"}]}""")
        assertEquals("cafe", p.atTag)
        assertFalse(p.isStudio)
        assertEquals(ImageRef(url = "https://x/b.jpg"), p.coverImage)
        assertEquals("Generated from a description", p.photos[1].caption)
        val old = json.decodeFromString(SuiteLocation.serializer(), """{"id":"l2","name":"Rooftop bar","image":{"asset":"r"},"createdAt":5}""")
        assertTrue(old.isStudio)
        assertEquals("rooftop-bar", old.atTag)
        assertEquals(ImageRef.asset("r"), old.coverImage)
        // An empty patch sends nothing (the server refuses nulls).
        assertEquals("{}", json.encodeToString(PlacePatch.serializer(), PlacePatch()))
    }

    @Test fun herPlacesComeFirstAndOthersAreLeftOut() {
        val all = listOf(SuiteLocation("1", "Rooftop", createdAt = 3), SuiteLocation("2", "Café", createdAt = 1, modelId = "m1"),
            SuiteLocation("3", "Gym", createdAt = 5, modelId = "m2"), SuiteLocation("4", "Apartment", createdAt = 4, modelId = "m1"))
        val (hers, studio) = Places.forModel("m1", all)
        assertEquals(listOf("Apartment", "Café"), hers.map { it.name })
        assertEquals(listOf("Rooftop"), studio.map { it.name })
        assertTrue(Places.forModel(null, all).first.isEmpty())
    }

    @Test fun demoPlacesRoundTrip() = runBlocking {
        val fake = FakeMuseApi(CoroutineScope(Dispatchers.Default), null, speed = 0.0, genDelayMs = 0)
        val her = SampleData.DEMO
        assertTrue(fake.suiteLocations().any { it.modelId == her && it.atTag == "cafe" })
        var p = fake.createPlace(PlaceCreate("Corner bench", modelId = her, tag = "@Bench"))
        assertEquals("bench", p.atTag)
        assertTrue(p.photos.isEmpty())
        try { fake.createPlace(PlaceCreate("Other", modelId = her, tag = "bench")); fail() } catch (e: ApiException) { assertEquals("tag_taken", e.code) }
        try { fake.placePhotoEstimate(p.id, PlacePhotoRequest("random")); fail() } catch (e: ApiException) { assertEquals("needs_a_photo", e.code) }
        val e = fake.placePhotoEstimate(p.id, PlacePhotoRequest("description"))
        assertEquals("Generate · $0.03", e.buttonLabel)
        try { fake.makePlacePhoto(p.id, PlacePhotoRequest("description", description = "Green bench", maxUsd = 0.01)); fail() } catch (x: ApiException) { assertEquals("price_changed", x.code) }
        val made = fake.makePlacePhoto(p.id, PlacePhotoRequest("description", description = "Green bench", maxUsd = e.estimate))
        assertEquals(listOf("description"), made.place.photos.map { it.source })
        assertTrue(made.chargedUsd <= e.estimate)
        p = fake.addPlaceImage(p.id, ImageRef.asset("g_front"))
        p = fake.updatePlace(p.id, PlacePatch(cover = 1))
        assertEquals(ImageRef.asset("g_front"), p.coverImage)
        p = fake.removePlaceImage(p.id, 0)
        assertEquals(0, p.cover)
        assertNull(fake.suiteLocations().firstOrNull { it.id == p.id && it.photos.size != 1 })
    }
}
