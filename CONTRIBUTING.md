# Contributing

TrimWM is intentionally small, dependency-free, and optimized for immediate
behavior. Contributions must preserve those properties.

## Expectations

Contributions are for experienced developers who can independently reason
about Swift, AppKit, Accessibility, concurrency, and window-manager
invariants. This project is not a learning sandbox, and maintainers cannot
provide basic programming mentorship.

Before opening a pull request:

- Understand and be able to explain every submitted change.
- Prefer the smallest complete solution.
- Do not add external packages or runtime dependencies.
- Add tests for new behavior and regressions.
- Review the complete diff and run the full test suite.

## AI-assisted contributions

AI assistance is allowed, but the contributor remains fully responsible for
the result.

- Use a current state-of-the-art coding or reasoning model. Output from weak,
  outdated, or cost-optimized models is not acceptable.
- Never submit raw or unreviewed generated code.
- Verify the architecture, correctness, security, licensing, and tests
  yourself.
- Before opening a pull request, understand the code well enough to maintain,
  debug, and defend every decision without relying on the model.

“The model wrote it” is never an acceptable explanation for a change.

## Verification

Run the full deterministic test suite:

```sh
xcodebuild test \
  -project TrimWM.xcodeproj \
  -scheme TrimWM \
  -configuration Debug \
  -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO
```
