# Limit Theory Redux state and roadmap

Survey date: October 24, 2026. Source baseline: `5902f67b`, branch `fix/rendering`.

The repository contains a substantial engine, a procedural spaceflight sandbox, and useful combat and economy prototypes. Most of the work needed to turn those pieces into a persistent, autonomous LT universe remains. The immediate opportunity is to connect existing systems into a small complete game, then expand its simulation and scale.

This roadmap treats LT as a single-player procedural space sandbox: explore, mine, trade, fight, build industry, and progress from piloting one ship to managing assets in a world of autonomous competitors. This is a proposed product scope, not an inventory of every historical LT promise. Multiplayer, planetary landing, and a renderer replacement are outside the initial milestones.

## What is here

“Connected” below means wired into the default application in source. It does not imply that every interaction has been verified in a playthrough. “Prototype” means implemented code or a dedicated test application; “legacy” means a separate older game model whose behavior must be validated and adapted before reuse.

| Area | Current implementation | Gap to an LT game |
| --- | --- | --- |
| Engine | Rust workspace with a launcher, `phx` engine, LuaJIT integration, generated FFI, event stages, worker tasks, input, audio, physics and UI. | Reliable build/test workflow, game lifecycle checks, and simulation contracts suitable for persistence and unattended operation. |
| Rendering | Dedicated render thread by default; immediate backend for comparison; resource handles, post-processing, shader reload/error overlay, profiling and optional stats dashboard. Scene culling and specialized asteroid instancing exist. | Continue fixing measured correctness/performance issues. General scene batching is incomplete: `RenderBatch` supplies culling/sorting, while the Lua scene still draws individual survivors. |
| World generation | Seeded rulesets generate systems, stars, planets, moons, rings and belts; visual materialization and coordinate rebasing exist. Rulesets support multiple systems. | A persistent world model, system activation/deactivation, inter-system travel, discovery, and useful generated locations. Generating several systems is not a playable galaxy. |
| Default game | Main menu, seeded New Game, generated fighter and station, flight, camera modes, HUD, world labels, maps, pause and return to menu. | A complete activity with rewards, consequences and progression. The default ruleset is a deliberately small scene: one system, star, planet and moon, with a ring; station count is limited by planet count. |
| Flight and navigation | Physics-based ship flight, travel-drive states, gravity-zone speed constraints, single-target autopilot and 2D/3D system maps are connected. | Docking/undocking, queued routes, obstacle avoidance, reliable NPC navigation, gates and a galaxy map. Dock/Undock bindings alone do not implement those actions. |
| Orbital motion | `OrbitalSystem` and orbit data exist; the playable test app uses this machinery. | The main application explicitly sets `staticStarSystem = true`, so orbital motion is disabled there. Decide the intended gameplay model before treating orbital simulation as complete. |
| Ships and equipment | Procedural hulls, capital hulls, structural mount discovery, loadout planning and construction lifetime management. Procedural weapon identities include seeds and generator versions. | Player fitting/purchasing, equipment persistence, role balance, costs, repair and ship replacement. |
| Combat | Dedicated weapon testbed runs targeting AI, tracking, fire planning, capacitors, beams/projectiles, shield-first damage and impact effects. | Integrate it into the default game; add player firing/target selection, flying opponents, allegiance, destruction consequences, rewards and recovery. Weapon AI currently means target/trigger control, not a general NPC mind. |
| Economy | Items, inventory, ownership, bank-account data, orders and a substantial market matcher/price model. Stations have inventory/market components. A market simulation app exists. | Correct settlement, populated markets, cargo constraints, station UI, mining, production, logistics and economic agents. The main application does not run the market system. |
| Persistence | User settings are written to disk; some generated mesh assets are cached. | Actual save/load of a running game. The Load Game view is a hardcoded seed picker that calls the legacy universe/loading flow, not a save reader. |
| Autonomous world | Legacy actions/jobs cover mining, transport, docking, patrol, escort, combat and job selection; legacy economy code includes production and factions. | Modern ECS integration and validation. No connected modern general-purpose job planner, production/logistics simulation or faction strategy was found. |
| Development support | Rust tests, FFI tests, many Lua scenario apps, benchmarks, documentation and CI for Windows/macOS/Linux. | Automated Lua gameplay assertions and end-to-end session tests. Scenario names and successful compilation are not evidence that game loops work. |

Primary implementation references:

- [Main application](../script/States/App/LTheoryRedux.lua), [default ruleset](../script/Config/Gen/Rulesets/SinglePlanetWithBelt.lua), [playable system test](../script/States/App/Tests/SolarSystemPlayable.lua).
- [Player controller](../script/Modules/Constructs/Systems/PlayerController.lua), [autopilot](../script/Modules/Constructs/Systems/AutoPilotSystem.lua), [ship bindings](../script/Input/ActionBindings/ShipActions.lua).
- [Universe manager](../script/Modules/CelestialObjects/Managers/UniverseManager/UniverseManager.lua), [visualizer](../script/Modules/CelestialObjects/Managers/SolarSystemVisualizer.lua), [nearby asteroid materialization](../script/Modules/CelestialObjects/Systems/AsteroidFieldSystem.lua).
- [Weapon testbed](../script/States/App/Tests/Testbeds/WeaponSystem.lua), [weapon AI and tick order](../script/Modules/Constructs/Systems/AIWeaponSystem.lua), [armament manager](../script/Modules/Constructs/Managers/ShipArmamentManager.lua).
- [Market system](../script/Modules/Economy/Systems/MarketplaceSystem.lua), [inventory manager](../script/Modules/Economy/Managers/InventoryManager.lua), [market scenario](../script/States/App/Tests/Economy/MarketplaceTest.lua).
- [Load Game view](../script/UI/HmGui/Views/MainMenu/Loadgame.lua), [user settings persistence](../script/Legacy/Systems/Files/InitFiles.lua), [procedural content identity](../script/Shared/Content/ProceduralContentIdentity.lua).
- [Render architecture](engine/render-thread.md), [batch-rendering status](engine/batch-rendering.md), [CI](../.github/workflows/ci.yaml).

## The main integration problems

### One game session needs to own the simulation

`LTheoryRedux`, `SolarSystemPlayable` and the weapon testbed each assemble their own scene and update loop. The weapon systems depend on a host state providing contacts, turret collections and shot-spawning callbacks. The market subscribes to `PreRender`; the engine's event timer measures elapsed time per frame stage. A consistent simulation clock and update order are needed before autonomous economy and saved sessions become dependable.

Extract only the shared session responsibilities needed by the next milestone: world ownership, system updates, entity lifetimes, player state and teardown. Keep scenario apps as thin fixtures over those same services. Avoid another wholesale engine/ECS rewrite.

### Economy implementation is not yet safe settlement

Source review identifies specific reasons to treat the market as a prototype:

- `MarketplaceSystem:transferCurrency` requests `Economy.Wallet`, which is absent from the [component exports](../script/Modules/Economy/Components/__init__.lua). The available [PlayerBankAccount](../script/Modules/Economy/Components/PlayerBankAccountComponent.lua) also exposes a different method interface.
- Orders are reduced or destroyed while matching, before inventory and payment settle. Failed settlement needs an explicit cancellation/rollback or reservation policy.
- `InventoryManager:take` removes available stacks while searching, then returns `nil` if the requested total is unavailable. It does not restore already removed stock on that path.
- `SimpleTradingTest` currently generates and prints a universe and ends with `todo: impl AI tasks next`; it is not a functioning trader simulation.

These findings should become focused regression cases before adding a player market UI. Prices are secondary to conservation of goods and money.

### Generated content needs durable identity

The ECS has runtime IDs and the weapon catalog has a useful versioned procedural identity model, but there is no game-save contract. Preserve 64-bit seeds losslessly, distinguish persistent identities from live handles, version generators and save schemas, and store changes to generated content. Reloading a seed alone would resurrect mined resources and destroyed ships and erase transactions.

### Legacy code is a reference library with live dependencies

The modern main game still uses legacy skybox generation, sound and settings code, and some menu views still enter the legacy universe. Removing `Legacy` wholesale would break useful functionality. Port behavior as a complete loop needs it, retain working adapters, and retire obsolete entry points once their replacements are verified.

## Roadmap

The order is dependency-driven. Each milestone must work through the normal New Game/Continue flow; a new testbed alone does not complete it. Acceptance targets below are proposed gates, not current performance claims.

| Milestone | Player-visible result | Main dependencies |
| --- | --- | --- |
| M0: Reliable shared session | Start, play, pause, restart and exit reliably. | Build/test stability and session ownership. |
| M1: Persistent sandbox | Save a ship and world, exit, and resume them. | M0; persistent identity and simulation time. |
| M2: First complete economic loop | Undock, collect ore or haul cargo, sell it, buy an upgrade, save and resume. | M1; docking, safe settlement, inventory and station UI. |
| M3: Combat with consequences | Fight a flying opponent in that same world and recover from loss. | M2 session/progression; existing weapon stack. |
| M4: Living local economy | NPCs mine, haul and produce; the player can delegate work. | M2 navigation/economy, M3 danger and allegiance. |
| M5: Connected persistent universe | Travel between systems whose inhabitants continue operating. | M1 persistence, M4 simulation and state ownership. |
| M6: Strategic LT play | Build industry and fleets, research equipment, and compete with factions. | M4/M5 autonomous economy and world scale. |
| M7: Playable alpha release | A legible, balanced, stable game with reproducible builds. | Completion of the chosen alpha scope and ongoing quality gates. |

### M0: Reliable shared session

- Fix concurrent FFI-generation output handling and establish a reproducible build/test baseline.
- Introduce a shared game-session owner for world creation, updates, shutdown and return to menu. Centralize subscription and resource cleanup.
- Define simulation time, pause/time-acceleration behavior and system ordering. Move economic work out of rendering events as it is integrated; use bounded simulation steps.
- Remove or clearly disable misleading legacy Load Game/ship-creation routes until the modern replacements exist.
- Add a Lua assertion runner with nonzero failure exits and a small fixed-seed smoke suite. Keep interactive graphics scenarios for visual checks.

**Exit gate:** ten New Game -> pause -> menu -> New Game cycles without duplicate updates or unbounded entity/resource growth; build and logic tests pass; normal menu and main-game paths have an explicit smoke result.

### M1: Persistent sandbox

- Define versioned saves containing universe/ruleset/generator versions, lossless seeds, persistent entity references, simulation time and player state.
- Save ship identity, position/velocity, loadout and damage; include inventory and credits as those systems are introduced. Record world mutations separately from reproducible generated content.
- Recreate physics/render resources from saved logical state. Do not serialize native pointers or transient renderer handles.
- Add save slots, Continue/Load, safe file replacement, corruption reporting and a documented migration policy.

**Exit gate:** save, terminate the process and reload; ship state and modified world objects survive. The same save produces the same generated content, and an unsupported/corrupt save fails clearly without replacing a good save.

### M2: First complete economic loop

- Build docking requests, approach, occupancy, attachment and undocking on the existing autopilot. Add basic collision avoidance before automated station approaches; handle a destroyed/unavailable destination.
- Establish one account/inventory/ownership model. Settlement validates funds, stock and cargo capacity, reserves resources, and commits goods plus payment together. Cancellation, expiry and partial fills conserve value.
- Give asteroids stable resource deposits and depletion. Use existing composition/item definitions, nearby entity materialization and procedural identity as foundations.
- Add a minimal station interface: buy/sell, cargo, repairs and one useful equipment or cargo upgrade.
- Use a deliberately small scenario with two stations and a resource field. Define demand and replenishment explicitly; do not hide the absence of industry behind unlimited stock.
- Save transactions, depleted deposits and upgrades.

**Exit gate:** a new player completes a 20–30 minute mine/haul -> dock -> sell -> upgrade loop without debug commands, then resumes it after restarting. Failed and repeated transactions cannot lose or duplicate goods or credits. Depleted rocks stay depleted after leaving and returning.

### M3: Combat with consequences

- Extract reusable combat hosting from the weapon testbed and preserve its documented target/physics/aim/fire/effect update order.
- Arm the player ship, connect input, targeting and HUD feedback, and introduce a minimal hostile/friendly relationship model.
- Add a flying opponent with pursuit, firing and retreat behavior. Turret targeting alone is insufficient.
- Unify shield/hull damage, entity destruction, cleanup and persistent destruction records. Add rewards/salvage, repair costs and a clear player-death/recovery policy.
- Add one encounter or escort/bounty contract that exercises the whole loop. Balance a small weapon selection before expanding variants.

**Exit gate:** a fight in the normal game awards or costs persistent resources; destroyed targets disappear from navigation, physics and saves; the player can recover from loss without restarting development tools.

### M4: Living local economy

- Port the intent of legacy [Think](../script/Legacy/GameObjects/Actions/Think.lua), [Mine](../script/Legacy/GameObjects/Jobs/Mine.lua), [Transport](../script/Legacy/GameObjects/Jobs/Transport.lua) and [Production](../script/Legacy/Systems/Economy/Production.lua) into modern services.
- Use the same docking, extraction, cargo and transaction operations for NPCs and the player. Add queued routes, retries, cancellation and recovery from blocked paths.
- Start with a small production chain: ore -> material -> useful equipment, with explicit inputs, outputs, processing time, capacity and sinks.
- Give agents budgets and assets; let them choose feasible work from shortages, prices and travel/risk costs. Add contracts generated from real unmet needs.
- Let the player acquire one additional ship and assign a mining or hauling job. This is the first management loop, before full fleet strategy.

**Exit gate:** a fixed-seed system runs unattended for two hours with bounded resource use, valid inventories/accounts and observable production/trade. Disrupting a supplier changes availability; agents can recover when supply returns. A delegated ship earns money through the same rules as the player.

### M5: Connected persistent universe

- Generate a connected travel graph, paired jump endpoints, routes and a galaxy map. Start with a bounded handful of systems.
- Separate persistent world data from the currently materialized scene. Activate/deactivate physics, rendering, audio and subscriptions without deleting logical state.
- Introduce coarse simulation for inactive systems with explicit reconciliation on arrival. Keep ownership, inventories, production and transactions authoritative across both simulation modes.
- Add discovery/sensor knowledge and worthwhile destinations: resource differences, trade opportunities, hazards and encounters.
- Validate coordinate conversion and precision during transitions; extend existing rebasing rather than assuming it already solves streaming.

**Exit gate:** travel A -> B -> A and reload in either system without resetting damage, depleted resources, ships, markets or discovery. NPC trade/production continues outside the active scene; repeated travel does not grow live resources indefinitely.

### M6: Strategic LT play

- Fleet orders, roles, formations and logistics; usable selection and command UI; ownership and command permissions.
- Station/factory construction, shipbuilding, supply chains, operating costs and replacement of economic losses.
- Research/blueprints that create meaningful equipment tradeoffs and feed production, reusing versioned content identities.
- Faction ownership, reputation, access rules and strategic AI that invests, expands and competes using the same resource constraints.
- Deeper exploration, information trading and emergent contracts/events tied to the simulated world.

**Exit gate:** the player can grow from one ship into a sustained industrial/fleet operation, while competitors respond to opportunities and losses. Expansion has costs, supply requirements and meaningful strategic choices.

### M7: Playable alpha release

- Choose and freeze an alpha feature scope. Preserve readable goals and useful feedback at every progression step.
- Onboarding, controls/rebinding, UI scaling, accessibility, audio feedback and coherent visual presentation.
- Economy and combat balance; diverse generated starts tested for solvability; save migration and recovery testing.
- Performance budgets on named reference machines and defined world/ship counts, with frame-time and memory measurements. Scale only after those budgets are measured.
- Packaged build smoke tests on supported platforms, long-session testing, crash diagnostics and reproducible bug reports with seed/save data.

**Exit gate:** someone unfamiliar with the code can install, learn, play, save and continue the chosen alpha loop without developer assistance.

## First implementation backlog

Start with these narrowly scoped changes, in this order. This is deliberately shorter than the long-term feature list.

1. **FFI build isolation:** reproduce parallel library/test compilation against shared `target/ffi` files; isolate generation per compilation or remove unsafe shared intermediate state. Keep serial builds as a temporary diagnostic workaround.
2. **Session lifecycle fixture:** exercise menu/game transitions and assert entity, subscription and physics cleanup; extract the common session owner only as needed.
3. **Identity and first save:** save/load the current small scene, player transform and one world mutation, preserving full seeds and versions.
4. **Transactional inventory/accounts:** unify the account component; test insufficient stock/funds, capacity, partial fills, cancellation and expiry before exposing trades.
5. **Dockable station:** complete approach/dock/undock and failure recovery through the normal controls.
6. **Ore-to-upgrade slice:** connect deposit depletion, cargo, a populated market and one purchasable upgrade; persist the result.

Weapon integration can begin after the shared session exists, but should not displace completion of the first persistent activity. The largest subsequent uncertainties are autonomous agent behavior, economically meaningful production, and reconciliation between active and inactive systems.

## Engine and migration policy

- Keep Rust/Lua, the current ECS and render architecture. Advance engine work when a milestone exposes a correctness, portability or measured performance need.
- Retain working legacy skybox/settings/audio adapters initially. Port jobs, docking, production and faction behavior as their modern milestones require them; validate before removing old implementations.
- Use the existing profiling dashboard and benchmark scenes to investigate performance. Treat general batching/instancing completion as measured optimization work, not a prerequisite for trading or saving.
- Defer a graphics API migration, sweeping ECS rewrite, elaborate orbital realism and an enormous generated galaxy. None completes the first player loop.
- Add tests around invariants: save round trips, conservation in transactions/production, depletion, destroyed references, navigation recovery and lifecycle cleanup. Do not mistake more demo apps for regression coverage.
- Refresh older documentation as features land. [ai/ideas.md](../ai/ideas.md) has useful navigation ideas, but some engine/build observations predate the current renderer. The old restructuring report and `phx` README also describe earlier states.

## Verification of this survey

The assessment traces the default entry point, representative systems, scenario apps, legacy implementations, build scripts and CI. Gameplay integration claims are based on source inspection; this survey does not include an interactive playthrough.

The initial `cargo test --workspace --locked --no-fail-fast --color never` failed during compilation: FFI procedural macros reported missing files and an empty JSON parse in `target/ffi`. The [generator](../engine/lib/luajit-ffi-gen/src/ffi_generator.rs) reads, removes and writes shared module-named files, consistent with a collision between concurrent compilations.

The retry, `cargo test --workspace --locked --no-fail-fast -j 1 --color never`, passed all 76 tests; two documentation tests were ignored. The Windows linker also emitted an `LNK4098` runtime-library conflict warning. The serial pass establishes a working test baseline on this machine, not concurrency safety or gameplay correctness. No engine or game source was changed for this survey.
