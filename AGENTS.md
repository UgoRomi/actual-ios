# Actual implementation reference

- Before implementing or changing Actual-related behavior, inspect the corresponding implementation in the local Actual checkout. Use `ACTUAL_SOURCE` when set; otherwise use `../actual`, relative to this repository.
- Web UI: [`../actual/packages/desktop-client`](../actual/packages/desktop-client).
- Core business logic and engine: [`../actual/packages/loot-core`](../actual/packages/loot-core).
- Use upstream code to verify behavior, data models, and edge cases before adapting them to the native iOS app.
- Check [Engine/upstream.json](Engine/upstream.json) for the pinned revision. If the local checkout differs, consult the pinned revision when assessing engine compatibility.
- If the checkout is unavailable, report that limitation rather than assuming upstream behavior.

# Documentation

- Before starting a task, check the relevant documentation in `docs/` and `README.md`. Update affected documentation when the work changes what it describes.
- Keep plans and responses concise.
