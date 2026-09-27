import Foundation

func collect(_ client: LLMPlanClient, _ prompt: String) async -> (String, Int, Int, String) {
    await withCheckedContinuation { cont in
        var before = 0
        client.plan(prompt) { event in
            switch event {
            case .item: before += 1
            case .plan(let s, let items): cont.resume(returning: (s, items.count, before, ""))
            case .failed(let m): cont.resume(returning: ("", 0, before, m))
            }
        }
    }
}

@main struct H {
    static func main() async {
        func provider() -> LLMProvider {
            LLMProvider(id: "t", displayName: "t",
                        baseURL: URL(string: "http://127.0.0.1:18080/v1")!,
                        api: .openAIChat, model: "m")
        }
        let r1 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "sse")
        assert(r1.0 == "3.2 GB can go" && r1.1 == 2, "SSE strict: \(r1)")
        print("PASS SSE strict (summary, 2 items)")
        assert(r1.2 == 2, "partial items streamed first: \(r1)")
        print("PASS partial items stream before plan")

        let r2 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "fenced")
        assert(r2.0 == "3.2 GB can go" && r2.1 == 2, "fenced: \(r2)")
        print("PASS fenced JSON decodes")

        let r3 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "plain")
        assert(r3.0 == "3.2 GB can go" && r3.1 == 2, "plain: \(r3)")
        print("PASS non-SSE body decodes")

        let r4 = await collect(LLMPlanClient(provider: provider(), apiKey: "k"), "401")
        assert(r4.3.contains("HTTP 401"), "401: \(r4)")
        print("PASS HTTP error surfaces")

        print("ALL OK")
    }
}
