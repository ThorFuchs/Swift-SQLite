## What and why

<!-- One change per pull request. Link the issue it resolves. -->

## Checklist

- [ ] Tests cover the change (`swift test` passes on macOS; CI covers Linux)
- [ ] Public symbols are documented and `Scripts/build-docs.sh` passes
- [ ] `swift test --sanitize=thread` passes for concurrency changes
- [ ] The developer kit still validates and its recipes run (`python3 Scripts/validate_developer_kit.py`, `Scripts/run_kit_recipes.sh`) if the change touches public API
- [ ] CHANGELOG.md has an entry under "Unreleased"
- [ ] No source-breaking API change, or the issue discussed it first
