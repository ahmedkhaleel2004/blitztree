# Provider pipeline test

Runs the real shipping code (`app/PlanParsing.swift` + `app/ModelProvider.swift`)
against a local mock endpoint, covering the shapes real models and endpoints
actually produce:

1. strict SSE stream (partial items stream before the plan)
2. markdown-fenced JSON
3. non-SSE plain JSON body (endpoint ignored `stream: true`)
4. HTTP error propagation

    python3 tests/provider-pipeline/server.py &   # port 18080
    swiftc -parse-as-library app/PlanParsing.swift app/ModelProvider.swift \
        tests/provider-pipeline/main.swift -o /tmp/bz-prov-harness
    /tmp/bz-prov-harness
