import XCTest
@testable import MuseCore

/// Model tools (plans/api.md "Model tools"): decoding the contract's shapes, any-model pricing, and the demo flows
/// (image models, Enhance, Dress up, review and apply, sheet versions, archive).
final class ModelToolsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func json<T: Encodable>(_ v: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as? [String: Any])
    }

    // MARK: Decoding

    func testDecodesImageModels() throws {
        let r = try decode(ImageModelsResponse.self, #"""
        {"steps":[
          {"step":"shot","label":"New shots","model":"black-forest-labs/flux-2-pro","defaultModel":"black-forest-labs/flux-2-pro","isDefault":true,
           "name":"flux-2-pro","official":true,
           "price":{"kind":"per-unit","units":[{"metric":"run_count","usd":0.015,"label":"per run"},{"metric":"image_input_megapixel_count","usd":0.015,"label":"per input MP"},
                    {"metric":"image_output_megapixel_count","usd":0.015,"label":"per output MP"}],"source":"config"},
           "priceLine":"$0.015 per run + $0.015 per input MP + $0.015 per output MP","compatible":true,"reasons":[],"warnings":[],
           "mapping":{"prompt":"prompt","image":{"field":"input_images","array":true,"max":8},"aspectRatio":"aspect_ratio","resolution":"resolution","seed":"seed",
                      "outputFormat":"output_format","outputQuality":"output_quality"},
           "extra":{"safety_tolerance":2,"go_fast":true,"style":"raw"}},
          {"step":"upscale","label":"Enhance · upscale","model":"philz1337x/clarity-upscaler","defaultModel":"philz1337x/clarity-upscaler","isDefault":true,
           "name":"clarity-upscaler","official":false,
           "price":{"kind":"per-second","usdPerSecond":0.00115,"hardware":"A100 (40GB)","typicalUsd":0.018,"source":"model page"},
           "priceLine":"by time · about $0.018 a run ($0.00115/s on A100 (40GB))","compatible":true,"reasons":[],"warnings":["no strength control"],
           "mapping":{"image":{"field":"image","array":false,"max":null},"scale":{"field":"scale_factor","kind":"number"}},"extra":{}},
          {"step":"dressB","model":"someone/new-model","price":{"kind":"unknown"},"compatible":true,"mapping":{}}
        ]}
        """#)
        XCTAssertEqual(r.steps.count, 3)
        let shot = r.steps[0]
        XCTAssertEqual(shot.imageStep, .shot)
        XCTAssertTrue(shot.isDefault)
        XCTAssertEqual(shot.price.units.map(\.metric), ["run_count", "image_input_megapixel_count", "image_output_megapixel_count"])
        XCTAssertEqual(shot.mapping.image?.max, 8)
        XCTAssertEqual(shot.extra["safety_tolerance"], .number(2))
        XCTAssertEqual(shot.extra["go_fast"], .bool(true))
        XCTAssertEqual(shot.extra["style"], .string("raw"))
        XCTAssertEqual(shot.mapping.summary, "prompt → prompt · images → input_images (up to 8) · size → aspect_ratio · resolution → resolution · seed → seed")
        let up = r.steps[1]
        XCTAssertTrue(up.price.isPerSecond)
        XCTAssertEqual(up.price.typicalUsd, 0.018)
        XCTAssertEqual(up.price.hardware, "A100 (40GB)")
        XCTAssertEqual(up.warnings, ["no strength control"])
        // Missing fields fall back to the step's defaults and the client's price line.
        let b = r.steps[2]
        XCTAssertEqual(b.label, "Dress up · Option B")
        XCTAssertEqual(b.defaultModel, "black-forest-labs/flux-2-pro")
        XCTAssertFalse(b.isDefault)
        XCTAssertEqual(b.name, "new-model")
        XCTAssertTrue(b.price.isUnknown)
        XCTAssertEqual(b.priceLine, "price unknown")
    }

    func testDecodesCatalogAndModelDetail() throws {
        let c = try decode(CatalogResponse.self, #"""
        {"step":"edit","collections":[{"slug":"image-editing","name":"Edit images"}],"cachedAt":1762300000000,
         "models":[
          {"id":"qwen/qwen-image-edit-2511","owner":"qwen","name":"qwen-image-edit-2511","description":"Edits","runCount":1830000,"official":true,"coverUrl":null,
           "price":{"kind":"per-unit","units":[{"metric":"image_output_count","usd":0.03,"label":"per output image"}]},"priceLine":"$0.03 per output image",
           "compatible":true,"reasons":[],"warnings":[]},
          {"id":"black-forest-labs/flux-1.1-pro","description":"Text to image","runCount":38000000,"official":true,"price":null,"priceLine":"price unknown",
           "compatible":false,"reasons":["needs an input image"],"warnings":[]},
          {"id":"someone/fresh","runCount":312,"official":false,"price":null,"compatible":null}
         ]}
        """#)
        XCTAssertEqual(c.collections.first?.slug, "image-editing")
        XCTAssertEqual(c.cachedAt, 1_762_300_000_000)
        XCTAssertEqual(c.models.map(\.runsLabel), ["1.8M runs", "38M runs", "312 runs"])
        XCTAssertEqual(c.models[0].compatibilityLabel, "Compatible")
        XCTAssertEqual(c.models[1].compatibilityLabel, "Not compatible · needs an input image")
        XCTAssertEqual(c.models[1].owner, "black-forest-labs", "owner and name come from the id when left out")
        XCTAssertEqual(c.models[1].name, "flux-1.1-pro")
        XCTAssertNil(c.models[2].compatible)
        XCTAssertEqual(c.models[2].compatibilityLabel, "Not checked yet")
        XCTAssertEqual(c.models[2].priceLine, "price unknown")

        let d = try decode(ModelDetail.self, #"""
        {"id":"black-forest-labs/flux-krea-dev","owner":"black-forest-labs","name":"flux-krea-dev","description":"Realism","runCount":2960000,"official":true,
         "price":{"kind":"per-unit","units":[{"metric":"image_output_count","usd":0.025,"label":"per output image"}]},"priceLine":"$0.025 per output image",
         "compatible":true,"reasons":[],"warnings":[],"version":"abc123",
         "mapping":{"prompt":"prompt","image":{"field":"image","array":false},"strength":{"field":"prompt_strength","min":0,"max":1}},
         "inputs":[
           {"name":"prompt","type":"string","required":true,"mappedAs":"prompt"},
           {"name":"guidance","type":"number","required":false,"default":4.5,"minimum":0,"maximum":10,"description":"Guidance"},
           {"name":"aspect_ratio","type":"enum","required":false,"default":"1:1","enum":["1:1","16:9","9:16"],"mappedAs":"aspectRatio"},
           {"name":"disable_safety_checker","type":"boolean","default":false}
         ]}
        """#)
        XCTAssertEqual(d.model.id, "black-forest-labs/flux-krea-dev")
        XCTAssertEqual(d.version, "abc123")
        XCTAssertEqual(d.mapping.strength?.field, "prompt_strength")
        XCTAssertEqual(d.inputs[1].defaultValue, .number(4.5))
        XCTAssertEqual(d.inputs[2].options, [.string("1:1"), .string("16:9"), .string("9:16")])
        XCTAssertEqual(d.editableInputs.map(\.name), ["guidance"], "mapped inputs and the safety switch aren't editable")
    }

    func testDecodesToolRunsVersionsAndFeatures() throws {
        let run = try decode(ToolRun.self, #"""
        {"id":"tr_1","kind":"dressup","modelId":"m_1","state":"review","options":{"engine":"both","name":"Denim","outfitImage":{"url":"/u/o.jpg"}},
         "engines":["a","b"],"estimate":0.86,"cost":0.84,"progress":100,"phase":"Ready to review","createdAt":1762300000000,"finishedAt":1762300060000,
         "models":{"dressA":"qwen/qwen-image-edit-2511","dressB":"black-forest-labs/flux-2-pro"},
         "items":[
           {"slot":"front","label":"Body · front","before":{"url":"/a.jpg"},"results":{"a":{"url":"/ra.jpg"},"b":{"url":"/rb.jpg"}},"state":"done","decision":"pending","pick":null,"cost":0.09},
           {"slot":"faceTq","before":{"url":"/f.jpg"},"results":{"a":{"url":"/fa.jpg"},"b":null},"state":"done","decision":"keep","pick":"a","cost":0.09},
           {"slot":"face","before":null,"results":{},"state":"failed","decision":"pending","cost":0,"error":"Something went wrong · you weren't charged"}
         ]}
        """#)
        XCTAssertTrue(run.isDressUp && run.isReview && run.showsBoth)
        XCTAssertEqual(run.options.outfitImage?.url, "/u/o.jpg")
        XCTAssertEqual(run.items[1].label, "Face · ¾", "the label falls back to the slot's")
        XCTAssertEqual(run.items[0].after?.url, "/ra.jpg")
        XCTAssertEqual(run.items[1].after?.url, "/fa.jpg")
        XCTAssertEqual(run.keptCount, 1)
        XCTAssertTrue(run.canApply)
        XCTAssertEqual(run.orderedItems.map(\.slot), ["face", "faceTq", "front"], "face close-ups first, then the body")
        XCTAssertEqual(run.models?["dressB"], "black-forest-labs/flux-2-pro")

        let e = try decode(ApiEvent.self, #"{"type":"tool","tool":{"id":"tr_2","kind":"enhance","modelId":"m_1","state":"running","phase":"Enhancing · 3 of 7","progress":28.5}}"#)
        XCTAssertEqual(e.tool?.phase, "Enhancing · 3 of 7")
        XCTAssertEqual(e.tool?.engines, ["a"])

        let v = try decode([SheetVersion].self, #"[{"id":"sv_1","createdAt":1762300000000,"reason":"enhance","slots":[{"key":"face","image":{"url":"/f.jpg"}},{"key":"faceTq","image":null}]}]"#)
        XCTAssertEqual(v[0].reasonLabel, "Before Enhance")
        XCTAssertEqual(v[0].filled, 1)

        let m = try decode(MuseModel.self, #"{"id":"m_1","name":"Ava","archived":true,"archivedAt":1762300000000,"slots":[{"key":"face"},{"key":"faceTq"}]}"#)
        XCTAssertTrue(m.archived)
        XCTAssertEqual(m.archivedAt, 1_762_300_000_000)
        XCTAssertFalse(try decode(MuseModel.self, #"{"id":"m_2","name":"B"}"#).archived, "false when absent")

        let o = try decode(Outfit.self, #"{"id":"o_1","modelId":"m_1","name":"Denim","mode":"dressup","angles":[{"url":"/a"},null,null,null],"faces":[{"url":"/f"},null,{"url":"/p"}]}"#)
        XCTAssertTrue(o.isDressUp)
        XCTAssertEqual(o.faces?.count, 3)
        XCTAssertNil(o.faces?[1] ?? nil)

        let f = try decode(StudioFeatures.self, #"""
        {"tools":{"enhance":{"available":true,"realism":[{"id":"off","label":"Off"},{"id":"subtle","label":"Subtle"},{"id":"balanced","label":"Balanced"},{"id":"strong","label":"Strong"}],
                             "upscale":[{"id":"off","label":"Off"},{"id":"2x","label":"2×"},{"id":"4x","label":"4×"}],
                             "models":{"realism":{"model":"black-forest-labs/flux-krea-dev","name":"FLUX Krea"}}},
                  "dressUp":{"available":true,"options":[{"id":"a","label":"Option A","detail":"Keeps each photo closest"},{"id":"b","label":"Option B","detail":"Richer detail"},
                             {"id":"both","label":"Both","detail":"Makes both · pick per photo"}]}}}
        """#)
        XCTAssertEqual(f.tools?.enhance.realism.map(\.id), ["off", "subtle", "balanced", "strong"])
        XCTAssertEqual(f.tools?.enhance.models?["realism"]?.name, "FLUX Krea")
        XCTAssertNil(f.tools?.dressUp.models, "members get no model names")
        XCTAssertEqual(f.tools?.dressUp.options.map(\.label), ["Option A", "Option B", "Both"])
        XCTAssertNil(try decode(StudioFeatures.self, "{}").tools, "older servers have no model tools")
    }

    // MARK: Requests

    func testRequestsLeaveOutWhatIsntSet() throws {
        let e = try json(EnhanceRequest(realism: "subtle", upscale: "off", models: [:]))
        XCTAssertEqual(e["realism"] as? String, "subtle")
        XCTAssertEqual(e["upscale"] as? String, "off")
        XCTAssertNil(e["models"], "an empty override isn't sent")
        XCTAssertNil(e["slots"])
        XCTAssertFalse(EnhanceRequest(realism: "off", upscale: "off").isValid)
        XCTAssertTrue(EnhanceRequest(realism: "off", upscale: "4x").isValid)

        let d = try json(DressUpRequest(outfitImage: ImageRef(url: "/u/o.jpg"), name: "  ", engine: "both", models: ["dressA": "google/nano-banana"]))
        XCTAssertNil(d["name"])
        XCTAssertEqual(d["engine"] as? String, "both")
        XCTAssertEqual((d["models"] as? [String: String])?["dressA"], "google/nano-banana")

        var shoot = ShootRequest(modelId: "m", outfitId: "o", scene: "s", prompt: "p")
        XCTAssertNil(try json(shoot)["models"], "members never send models")
        shoot.models = ["shot": "bytedance/seedream-4"]
        XCTAssertEqual((try json(shoot)["models"] as? [String: String])?["shot"], "bytedance/seedream-4")

        let set = try JSONEncoder().encode(SetImageModelRequest(model: "a/b", extra: ["steps": .number(28), "guidance": .number(3.5), "style": .string("raw")]))
        let text = String(decoding: set, as: UTF8.self)
        XCTAssertTrue(text.contains("\"steps\":28"), "whole numbers stay integers: \(text)")
        XCTAssertTrue(text.contains("\"guidance\":3.5"))
        let items: [URLQueryItem] = CatalogQuery(step: .realism, q: "  krea ").queryItems
        let pairs: [String] = items.map { (i: URLQueryItem) -> String in i.name + "=" + (i.value ?? "") }
        XCTAssertEqual(pairs, ["step=realism", "q=krea"])
        XCTAssertEqual(CatalogQuery(step: .upscale, collection: "super-resolution").queryItems.count, 2)
    }

    func testModelIdsAndAdvancedInputs() {
        XCTAssertEqual(parseModelId("black-forest-labs/flux-2-pro")?.name, "flux-2-pro")
        XCTAssertEqual(parseModelId(" https://replicate.com/qwen/qwen-image-edit-2511?tab=api ")?.owner, "qwen")
        XCTAssertEqual(parseModelId("nightmareai/real-esrgan/versions/abc")?.name, "real-esrgan")
        XCTAssertNil(parseModelId("flux-2-pro"))
        XCTAssertNil(parseModelId("a/b/c"))
        XCTAssertNil(parseModelId("a b/c"))

        XCTAssertEqual(JSONValue.parse("28", type: "integer"), .number(28))
        XCTAssertNil(JSONValue.parse("2.5", type: "integer"))
        XCTAssertEqual(JSONValue.parse("off", type: "boolean"), .bool(false))
        XCTAssertEqual(JSONValue.parse("[1, \"a\"]", type: "array"), .array([.number(1), .string("a")]))
        XCTAssertNil(JSONValue.parse("nope", type: "array"))
        XCTAssertEqual(JSONValue.parse("9:16", type: "enum"), .string("9:16"))
        XCTAssertNil(JSONValue.parse("  ", type: "string"), "empty leaves the key out")
        XCTAssertEqual(JSONValue.number(4.5).description, "4.5")
        XCTAssertEqual(JSONValue.number(28).description, "28")

        let inputs = [InputField(name: "guidance", type: "number"), InputField(name: "disable_safety_checker", type: "boolean")]
        XCTAssertNil(SetImageModelRequest.validate(extra: ["guidance": .number(3)], inputs: inputs))
        XCTAssertEqual(SetImageModelRequest.validate(extra: ["disable_safety_checker": .bool(true)], inputs: inputs), "disable_safety_checker can't be changed")
        XCTAssertEqual(SetImageModelRequest.validate(extra: ["steps": .number(3)], inputs: inputs), "steps isn't an input of this model")
        XCTAssertNotNil(SetImageModelRequest.validate(extra: ["guidance": .string(String(repeating: "x", count: 5000))], inputs: nil))
    }

    // MARK: Pricing

    func testPriceLinesAndEstimates() {
        let flux = FakeMuseAPI.fluxProPrice
        let qwen = PriceInfo.perUnit([PriceUnit(metric: "image_output_count", usd: 0.03, label: "per output image")])
        let krea = PriceInfo.perUnit([PriceUnit(metric: "image_output_count", usd: 0.025, label: "")])
        let clarity = PriceInfo.perSecond(0.00115, hardware: "A100 (40GB)", typical: 0.018)
        XCTAssertEqual(ToolPricing.priceLine(flux), "$0.015 per run + $0.015 per input MP + $0.015 per output MP")
        XCTAssertEqual(ToolPricing.priceLine(krea), "$0.025 per output image", "the unit label comes from the metric when missing")
        XCTAssertEqual(ToolPricing.priceLine(clarity), "by time · about $0.018 a run ($0.00115/s on A100 (40GB))")
        XCTAssertEqual(ToolPricing.priceLine(.perSecond(0.000225, hardware: nil, typical: nil)), "by time · $0.000225/s")
        XCTAssertEqual(ToolPricing.priceLine(nil), "price unknown")

        // One prediction.
        XCTAssertEqual(ToolPricing.prediction(qwen, inputImages: 3), 0.03, accuracy: 1e-12)
        let twoRefs: Double = 0.015 + 0.015 * 0.79 * 2 + 0.015
        XCTAssertEqual(ToolPricing.prediction(flux, inputImages: 2), twoRefs, accuracy: 1e-12)
        XCTAssertEqual(ToolPricing.prediction(flux, inputImages: 0, outputMp: 2), 0.045, accuracy: 1e-12)
        XCTAssertEqual(ToolPricing.prediction(clarity, scale: 2), 0.018, accuracy: 1e-12)
        XCTAssertEqual(ToolPricing.prediction(clarity, scale: 4), 0.072, accuracy: 1e-12, "4× ≈ 4 × the 2× typical")
        XCTAssertEqual(ToolPricing.prediction(.perSecond(0.001, hardware: nil, typical: nil)), 0.02, accuracy: 1e-12, "20 s × the price per second")
        XCTAssertEqual(ToolPricing.prediction(.unknown), 0.05)
        XCTAssertEqual(ToolPricing.prediction(nil), 0.05)
        XCTAssertEqual(ToolPricing.prediction(.perUnit([PriceUnit(metric: "something_else", usd: 0.01)])), 0.01, "any other metric counts 1")

        // Enhance: the contract's example (7 images · about $0.30, 0.043 an image).
        let e = ToolPricing.enhance(images: 7, realism: "balanced", upscale: "2x", realismPrice: krea, upscalePrice: clarity)
        XCTAssertEqual(e.perImage ?? 0, 0.043, accuracy: 1e-12)
        XCTAssertEqual(e.estimate, 0.301, accuracy: 1e-9)
        XCTAssertEqual(e.label, "7 images · about $0.30")
        XCTAssertEqual(ToolPricing.enhance(images: 7, realism: "off", upscale: "4x", realismPrice: krea, upscalePrice: clarity).estimate, 0.504, accuracy: 1e-9)
        XCTAssertEqual(ToolPricing.enhance(images: 3, realism: "strong", upscale: "off", realismPrice: krea, upscalePrice: clarity).label, "3 images · about $0.08")

        // Dress up: Option A (the edit model) is $0.03 an image; Both adds Option B.
        let a = ToolPricing.dressUp(images: 7, engine: "a", priceA: qwen, priceB: flux)
        XCTAssertEqual(a.estimate, 0.21, accuracy: 1e-9)
        XCTAssertEqual(a.label, "7 images · about $0.21")
        let b = ToolPricing.dressUpOption(images: 7, price: flux)
        let front: Double = 0.015 + 0.015 * 0.79 * 2 + 0.015
        let other: Double = 0.015 + 0.015 * 0.79 * 3 + 0.015
        XCTAssertEqual(b, front + 6 * other, accuracy: 1e-12, "front from 2 images, the rest from 3")
        let both = ToolPricing.dressUp(images: 7, engine: "both", priceA: qwen, priceB: flux)
        XCTAssertEqual(both.estimate, 0.21 + b, accuracy: 1e-12)
        XCTAssertTrue(both.label.hasPrefix("7 images · 2 options · about $"), both.label)
        XCTAssertEqual(ToolPricing.dressUp(images: 0, engine: "a", priceA: qwen, priceB: flux).estimate, 0)

        XCTAssertEqual(ToolPricing.usd(0.00115), "$0.00115")
        XCTAssertEqual(ToolPricing.usd(0.03), "$0.03")
        XCTAssertEqual(ToolPricing.usd(1), "$1.00")
        XCTAssertEqual(ToolPricing.runs(1_234_567), "1.2M runs")
        XCTAssertEqual(ToolPricing.runs(48_210), "48K runs")
        XCTAssertEqual(ToolPricing.runs(1), "1 run")
    }

    func testSheetHasSevenSlotsInTwoGroups() {
        XCTAssertEqual(SheetAngle.allCases.map(\.rawValue), ["face", "profile", "front", "tq", "side", "back", "faceTq"])
        XCTAssertEqual(SheetAngle.faceGroup.map(\.label), ["Face · front", "Face · ¾", "Face · profile"])
        XCTAssertEqual(SheetAngle.bodyGroup.count, 4)
        XCTAssertTrue(SheetAngle.faceTq.isFace)
        let m = SampleData.models()[0]
        XCTAssertEqual(m.slots.count, 7)
        XCTAssertTrue(m.isLocked, "an empty face ¾ is only a warning")
        XCTAssertEqual(m.filled, 6)
    }

    // MARK: Demo flows

    private func fast() -> FakeMuseAPI { FakeMuseAPI(speed: 100_000, genDelay: 0.02) }

    private func waitForRun(_ api: FakeMuseAPI, _ id: String, state: String = "review") async throws -> ToolRun {
        for _ in 0..<400 {
            let r = try await api.toolRun(id: id)
            if r.state == state && (state != "review" || !r.anyItemRunning) { return r }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("run \(id) never reached \(state)")
        return try await api.toolRun(id: id)
    }

    func testImageModelsAreOwnerOnly() async throws {
        let api = fast()
        let steps = try await api.imageModels()
        XCTAssertEqual(steps.map(\.step), ["shot", "edit", "realism", "upscale", "dressA", "dressB"])
        XCTAssertTrue(steps.allSatisfy(\.isDefault))
        XCTAssertEqual(steps[2].priceLine, "$0.025 per output image")

        do {
            _ = try await api.setImageModel(step: .edit, SetImageModelRequest(model: "black-forest-labs/flux-1.1-pro"))
            XCTFail("a text-only model can't edit")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "model_incompatible")
            XCTAssertTrue(e.message.contains("needs an input image"), e.message)
        }
        do {
            _ = try await api.setImageModel(step: .realism, SetImageModelRequest(model: "black-forest-labs/flux-krea-dev", extra: ["disable_safety_checker": .bool(true)]))
            XCTFail("the safety switch is refused")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }

        let set = try await api.setImageModel(step: .realism, SetImageModelRequest(model: "https://replicate.com/google/nano-banana", extra: ["seed": .number(7)]))
        XCTAssertEqual(set.model, "google/nano-banana")
        XCTAssertFalse(set.isDefault)
        XCTAssertEqual(set.extra["seed"], .number(7))
        let owner = try await api.studioSettings()
        XCTAssertEqual(owner.features.tools?.enhance.models?["realism"]?.model, "google/nano-banana")
        let back = try await api.resetImageModel(step: .realism)
        XCTAssertTrue(back.isDefault)
        XCTAssertTrue(back.extra.isEmpty)

        let cat = try await api.imageModelCatalog(CatalogQuery(step: .upscale))
        XCTAssertEqual(cat.collections.map(\.slug), ["super-resolution", "ai-image-restoration"])
        XCTAssertEqual(cat.models.map(\.runCount), cat.models.map(\.runCount).sorted(by: >), "most-run first")
        let search = try await api.imageModelCatalog(CatalogQuery(step: .dressA, q: "kontext"))
        XCTAssertEqual(search.models.first?.compatible, false, "one image field can't take sheet + outfit")
        let detail = try await api.imageModelDetail(id: "black-forest-labs/flux-krea-dev", step: .realism)
        XCTAssertFalse(detail.editableInputs.contains { $0.isSafetySwitch })
        XCTAssertTrue(detail.editableInputs.contains { $0.name == "guidance" })

        _ = try await api.signIn(SignInRequest(email: "member@studio.com", password: "x"))
        await api.setRole("member")
        for call in [{ try await api.imageModels() as Any }, { try await api.imageModelCatalog(CatalogQuery(step: .shot)) as Any }] {
            do {
                _ = try await call()
                XCTFail("members get owner_only")
            } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
        }
        do {
            var r = ShootRequest(modelId: SampleData.demo, outfitId: SampleData.green, scene: "Kitchen", prompt: "p")
            r.models = ["shot": "google/nano-banana"]
            _ = try await api.shoot(r)
            XCTFail("a member can't override the model")
        } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
        let member = try await api.studioSettings()
        XCTAssertNotNil(member.features.tools)
        XCTAssertNil(member.features.tools?.enhance.models, "members never see model names")
        XCTAssertNil(member.features.tools?.dressUp.models)
    }

    func testEnhanceReviewApplyAndRestore() async throws {
        let api = fast()
        let before = try await api.balance().balance
        let est = try await api.enhanceEstimate(modelId: SampleData.demo, EnhanceRequest())
        XCTAssertEqual(est.images, 6, "every filled slot")
        XCTAssertEqual(est.estimate, 6 * 0.043, accuracy: 1e-9)
        do {
            _ = try await api.enhance(modelId: SampleData.demo, EnhanceRequest(realism: "off", upscale: "off"))
            XCTFail("both steps off")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }

        let started = try await api.enhance(modelId: SampleData.demo, EnhanceRequest(realism: "subtle", upscale: "4x"))
        XCTAssertTrue(started.isRunning)
        XCTAssertEqual(started.models?["upscale"], "philz1337x/clarity-upscaler", "the owner sees the models used")
        var run = try await waitForRun(api, started.id)
        XCTAssertEqual(run.phase, "Ready to review")
        XCTAssertEqual(run.cost, run.estimate, accuracy: 1e-9)
        let spent = try await api.balance().balance
        XCTAssertEqual(before - spent, run.cost, accuracy: 1e-9, "held then settled to the exact cost")

        run = try await api.decideToolItem(runId: run.id, slot: "face", ToolDecisionRequest(decision: "keep"))
        XCTAssertEqual(run.item("face")?.pick, "a")
        run = try await api.decideToolItem(runId: run.id, slot: "back", ToolDecisionRequest(decision: "reject"))
        run = try await api.retryToolItem(runId: run.id, slot: "profile", engine: nil)
        XCTAssertEqual(run.item("profile")?.state, "running")
        run = try await waitForRun(api, run.id)
        XCTAssertEqual(run.item("profile")?.results.a?.asset, "enh_profile_r1", "a new result")
        XCTAssertEqual(run.item("profile")?.decision, "pending")
        run = try await api.decideToolItem(runId: run.id, slot: "profile", ToolDecisionRequest(decision: "keep"))

        let applied = try await api.applyToolRun(runId: run.id, ToolApplyRequest())
        XCTAssertEqual(applied.run.state, "applied")
        XCTAssertNil(applied.outfit)
        XCTAssertEqual(applied.model.slot("face")?.image?.asset, "enh_face")
        XCTAssertEqual(applied.model.slot("profile")?.image?.asset, "enh_profile_r1")
        XCTAssertEqual(applied.model.slot("face")?.isAI, true)
        XCTAssertEqual(applied.model.slot("back")?.image?.asset, "g_back", "rejected images keep the old one")

        let versions = try await api.sheetVersions(modelId: SampleData.demo)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].reason, "enhance")
        XCTAssertEqual(versions[0].slots.first { $0.key == "face" }?.image?.asset, "face", "the old sheet is kept")
        let restored = try await api.restoreSheetVersion(modelId: SampleData.demo, versionId: versions[0].id)
        XCTAssertEqual(restored.slot("face")?.image?.asset, "face")
        let after = try await api.sheetVersions(modelId: SampleData.demo)
        XCTAssertEqual(after.map(\.reason), ["restore", "enhance"], "restoring saves the current sheet first")
        do {
            _ = try await api.applyToolRun(runId: run.id, ToolApplyRequest())
            XCTFail("applied once")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    func testDressUpBothMakesANewOutfitAndLeavesTheSheet() async throws {
        let api = fast()
        let sheet = try await api.listModels().first { $0.id == SampleData.demo }!
        let est = try await api.dressUpEstimate(modelId: SampleData.demo, DressUpEstimateRequest(engine: "both"))
        XCTAssertTrue(est.label.hasPrefix("6 images · 2 options · about $"), est.label)
        let started = try await api.dressUp(modelId: SampleData.demo, DressUpRequest(outfitImage: ImageRef(url: "data:image/jpeg;base64,AA=="), name: "Denim day", engine: "both"))
        XCTAssertEqual(started.engines, ["a", "b"])
        XCTAssertEqual(started.items.first?.slot, "front", "the full-body front goes first")
        var run = try await waitForRun(api, started.id)
        XCTAssertTrue(run.items.allSatisfy { $0.results.a != nil && $0.results.b != nil })
        run = try await api.pickToolRun(runId: run.id, pick: "b")
        XCTAssertTrue(run.items.allSatisfy { $0.isKept && $0.pick == "b" }, "whole set")
        run = try await api.decideToolItem(runId: run.id, slot: "face", ToolDecisionRequest(decision: "keep", pick: "a"))
        run = try await api.decideToolItem(runId: run.id, slot: "side", ToolDecisionRequest(decision: "reject"))

        let applied = try await api.applyToolRun(runId: run.id, ToolApplyRequest())
        let o = try XCTUnwrap(applied.outfit)
        XCTAssertEqual(o.name, "Denim day")
        XCTAssertTrue(o.isDressUp)
        XCTAssertEqual(o.state, "ready")
        XCTAssertEqual(o.angles.map { $0?.asset }, ["dressb_front", "dressb_tq", nil, "dressb_back"])
        XCTAssertEqual(o.faces?.map { $0?.asset }, ["dressa_face", nil, "dressb_profile"], "face, face ¾ (missing on the sheet), profile")
        XCTAssertTrue(applied.model.outfitIds.contains(o.id))
        XCTAssertEqual(applied.run.outfitId, o.id)
        XCTAssertEqual(applied.model.slots, sheet.slots, "the original sheet is never changed")
        let outfits = try await api.listOutfits()
        XCTAssertTrue(outfits.contains { $0.id == o.id })
    }

    func testDiscardAndFailureReleaseTheHold() async throws {
        let api = FakeMuseAPI(speed: 100_000, genDelay: 0.3)
        let before = try await api.balance().balance
        let run = try await api.dressUp(modelId: SampleData.demo, DressUpRequest(outfitImage: ImageRef(asset: "c_front")))
        let held = try await api.balance().balance
        XCTAssertLessThan(held, before)
        try await api.discardToolRun(runId: run.id)
        let after = try await api.balance().balance
        XCTAssertEqual(after, before, accuracy: 1e-9, "nothing was made yet")
        let discarded = try await api.toolRun(id: run.id)
        XCTAssertEqual(discarded.state, "discarded")

        let api2 = fast()
        let start = try await api2.balance().balance
        try await api2.setFailNext(true)
        let failing = try await api2.enhance(modelId: SampleData.demo, EnhanceRequest())
        let failed = try await waitForRun(api2, failing.id, state: "failed")
        XCTAssertEqual(failed.error, MemberText.wentWrong)
        let end = try await api2.balance().balance
        XCTAssertEqual(start - end, failed.cost, accuracy: 1e-9, "only what was made is paid for")
    }

    func testArchiveHidesTheModelEverywhere() async throws {
        let api = fast()
        let m = try await api.archiveModel(id: SampleData.demo)
        XCTAssertTrue(m.archived)
        XCTAssertNotNil(m.archivedAt)
        let models = try await api.listModels()
        let outfits = try await api.listOutfits()
        let archived = try await api.listArchivedModels()
        let takes = try await api.listTakes()
        XCTAssertFalse(models.contains { $0.id == SampleData.demo })
        XCTAssertFalse(outfits.contains { $0.modelId == SampleData.demo }, "her outfits leave the pickers too")
        XCTAssertEqual(archived.map(\.id), [SampleData.demo])
        XCTAssertFalse(takes.isEmpty, "finished takes stay in the gallery")
        for work in [
            { _ = try await api.createJob(JobRequest(title: "x", modelId: SampleData.demo, outfitId: SampleData.green, clipId: SampleData.sampleClip)) },
            { _ = try await api.shoot(ShootRequest(modelId: SampleData.demo, outfitId: SampleData.green, scene: "s", prompt: "p")) },
            { _ = try await api.enhance(modelId: SampleData.demo, EnhanceRequest()) },
            { _ = try await api.dressUp(modelId: SampleData.demo, DressUpRequest(outfitImage: ImageRef(asset: "c_front"))) },
            { _ = try await api.fillAngles(modelId: SampleData.demo) },
        ] as [() async throws -> Void] {
            do {
                try await work()
                XCTFail("new work on an archived model")
            } catch let e as ApiError {
                XCTAssertEqual(e.code, "model_archived")
                XCTAssertEqual(e.friendlyMessage, "This model is archived · restore her in Settings → Archived models")
            }
        }
        _ = try await api.unarchiveModel(id: SampleData.demo)
        let back = try await api.listModels()
        let none = try await api.listArchivedModels()
        XCTAssertTrue(back.contains { $0.id == SampleData.demo })
        XCTAssertTrue(none.isEmpty)
        _ = try await api.signIn(SignInRequest(email: "member@studio.com", password: "x"))
        await api.setRole("member")
        do {
            _ = try await api.archiveModel(id: SampleData.demo)
            XCTFail("owner only")
        } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
    }
}
