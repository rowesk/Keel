# Contributing to Keel

Keel keeps one ordinary page active and queues destinations without loading them. A change should preserve that model unless an issue explicitly proposes changing it.

For bugs, include the macOS version, Keel build, expected behaviour, actual behaviour, and the shortest reproduction you can make with public or fictional data. Avoid posting personal URLs, cookies, tokens, or browser profiles.

For a feature or a substantial refactor, open an issue before writing it. Explain the browsing problem and the proposed behaviour. A tab strip, parallel browsing window, or a permanently loaded queue would change the product rather than extend it.

For code changes:

1. Read [the domain vocabulary](CONTEXT.md) and the affected module.
2. Keep the change focused. Add regression coverage for behavioural fixes.
3. Run relevant tests, then the [complete verification gate](docs/building.md#verify-changes).
4. Describe the user-visible result, validation, and remaining limitations in the pull request. Include fictional-data screenshots when the UI changes.

Automated tests should stay offscreen. Never make routine verification raise a window or activate another application. Preserve existing snapshot baselines until you have inspected an intended visual change.

By contributing code, you agree to make your contribution available under the project's MIT licence. For vulnerabilities, follow [the security policy](SECURITY.md). Do not post vulnerability details in a public issue.
