# Swift-SQLite developer kit

Kit **0.4.0** is pinned to released **Swift-SQLite 1.2.0**. The two version numbers
are separate: the kit adds instructions and examples for coding agents and changes
nothing in the library.

The kit is one focused, instruction-only `swift-sqlite` skill. It helps an agent
identify a consumer's actual dependency, choose the smallest version-matched
products, write correct transactions, migrations, bound SQL, limits and error
handling, and verify the result in that consumer. It contains no connector,
server, hook, API-key setup, telemetry or automatic download helper.

## Install in Claude Code

This repository is a Claude Code plugin marketplace:

```text
/plugin marketplace add ThorFuchs/Swift-SQLite
/plugin install swift-sqlite@swift-sqlite
```

The [marketplace file](../.claude-plugin/marketplace.json) lists the plugin from
`./plugins/swift-sqlite`. Its [Claude Code manifest](../plugins/swift-sqlite/.claude-plugin/plugin.json)
carries the same name, version and description as the
[portable manifest](../plugins/swift-sqlite/plugin.json). Both commands change user
settings, so they are the user's action.

## Use with Codex and other agents

Copy `plugins/swift-sqlite/skills/swift-sqlite` (or the standalone skill archive's
`swift-sqlite` folder) to `.agents/skills/swift-sqlite` in a consumer workspace and
invoke the skill by name. The portable manifest uses the Agent Plugins format with
`skills/` discovery.

## Contents

| Path | Purpose |
| --- | --- |
| [SKILL.md](../plugins/swift-sqlite/skills/swift-sqlite/SKILL.md) | When to use the skill, product choice, the rules agents get wrong most often |
| [references/versions.md](../plugins/swift-sqlite/skills/swift-sqlite/references/versions.md) | Which release added which API; manifest lines |
| [references/semantics.md](../plugins/swift-sqlite/skills/swift-sqlite/references/semantics.md) | Transactions, errors, commit outcomes, limits, model layer |
| [references/recipes.md](../plugins/swift-sqlite/skills/swift-sqlite/references/recipes.md) | Routing to the 20 compiled recipes and what each asserts |
| [references/troubleshooting.md](../plugins/swift-sqlite/skills/swift-sqlite/references/troubleshooting.md) | Compiler and runtime errors agents hit, with fixes |
| [references/installation.md](../plugins/swift-sqlite/skills/swift-sqlite/references/installation.md) | Installing the kit |
| [references/compatibility.json](../plugins/swift-sqlite/skills/swift-sqlite/references/compatibility.json) | The qualified tag, commit and tree, and the recipe IDs |
| [assets/consumer](../plugins/swift-sqlite/skills/swift-sqlite/assets/consumer/Package.swift) | One executable package; every recipe is a function with a `// RECIPE id` marker and real assertions |

The [evaluation cases](AgentDeveloperKitEvaluations.json) stay outside the skill and
both archives. They include cases where the skill must not be used (GRDB,
SQLite.swift, Core Data, SwiftData).

## Maintaining the kit

```text
python3 Scripts/validate_developer_kit.py           # files, manifests, links, recipe markers, pins, private paths
Scripts/run_kit_recipes.sh                           # recipes against this checkout, Debug and Release
Scripts/run_kit_recipes.sh --tag                     # recipes against the pinned published tag
python3 Scripts/package_developer_kit.py --output DIR  # deterministic plugin and skill archives
```

CI runs the validator and the recipes against the checkout on every pull request,
so an API change that breaks a recipe fails before it merges. Before a kit
release, run the recipes with `--tag` against the published library version.

To move the kit to a new library release: change the pin in the consumer's
`Package.swift`, `LIBRARY_VERSION` in the validator, the manifests' descriptions,
`SKILL.md` and `compatibility.json` (tag, commit, tree), add the release to
`versions.md`, and bump the kit version if the content changed.

## Status

- Kit 0.4.0 is a source candidate in this repository (0.3.0 targeted library
  1.1.0, 0.2.0 library 1.0.0, 0.1.0 library 0.9.0). A download release
  (`developer-kit-v0.4.0`) is a separate maintainer decision.
- Installation from GitHub and end-to-end use in an agent session are not recorded
  yet.
