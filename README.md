# StreakRewards

Daily rewards and login streaks for Roblox developers. Version 1.0.0, by Kenson Dev.

Includes a server-authoritative claim service, configurable rewards, UTC or rolling eligibility, DataStore persistence, and a ready-made calendar popup. The default calendar pays seven days of Coins and then repeats. Free and open source under the MIT license.

## Quickstart

Download `dist/StreakRewards.rbxm` (or open `dist/StreakRewards-Demo.rbxl` in Roblox Studio to try it), then follow *Drag-and-drop installation* below. Rojo users can build from `default.project.json`.

## Contents

- `dist/StreakRewards.rbxm`: binary drag-and-drop model.
- `dist/StreakRewards.rbxmx`: XML version of the same model.
- `dist/StreakRewards-Demo.rbxl`: demo place with the system already installed.
- `src/Shared`: typed configuration, remote names, and pure streak logic.
- `src/Server`: service, DataStore adapter, and bootstrap.
- `src/Client`: popup controller and bootstrap.
- `tests/run.luau`: dependency-free Lune logic tests.
- `examples/ProfileStoreAdapter.luau`: documentation-only adapter example. Not packaged or executed automatically.

## Drag-and-drop installation

1. Back up your place. Insert `dist/StreakRewards.rbxm` into Studio using Insert from File.
2. Create a Folder named `StreakRewards` in `ReplicatedStorage`. Move the package's `Shared` folder into it.
3. Move `Server` into `ServerScriptService`, then rename it `StreakRewardsServer`.
4. Move `Client` into `StarterPlayer > StarterPlayerScripts`, then rename it `StreakRewardsClient`.
5. Delete the now-empty package wrapper and its `INSTALL` StringValue. There is no installer Script.
6. Edit `ReplicatedStorage.StreakRewards.Shared.Config`. Press Play. Claim day one and inspect the player's `Coins` attribute.

Final tree:

```text
ReplicatedStorage
  StreakRewards
    Shared
      Config, Types, StreakLogic, Remotes
ServerScriptService
  StreakRewardsServer
    Bootstrap, StreakRewards, DataStoreAdapter, RecordCodec
StarterPlayer
  StarterPlayerScripts
    StreakRewardsClient
      Bootstrap, Controller
```

Install only one copy. The server creates its own remotes in ReplicatedStorage. Do not create client-side remotes or move server code into ReplicatedStorage.

For persistent Studio testing, publish your own test place and enable Game Settings > Security > Enable Studio Access to API Services. Use a separate DataStore name for testing, not your production economy's store. If Studio reports disabled API access, the adapter warns and uses process-local memory. That fallback disappears when the server stops. Live failures fail closed rather than granting from an empty record.

## Rojo installation

With Rojo installed:

```sh
rojo serve default.project.json
```

Connect the Studio Rojo plugin and sync. `default.project.json` maps the live services. `package.project.json` instead builds a Folder-root package for manual installation.

Rebuild all artifacts:

```sh
mkdir -p dist
rojo build package.project.json -o dist/StreakRewards.rbxm
rojo build package.project.json -o dist/StreakRewards.rbxmx
rojo build default.project.json -o dist/StreakRewards-Demo.rbxl
```

## Configuration

Change only `src/Shared/Config.luau`, or its synced ModuleScript. Restart servers after changes. Shared configuration is visible to clients; never put secrets in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `CycleLength` | `7` | Positive integer reward-cycle length. Supply exactly this many reward entries. |
| `CycleMode` | `"Loop"` | `Loop` wraps the reward index; `Cap` repeats the last reward. Neither caps the total streak counter. |
| `TimeMode` | `"UTC"` | `UTC` unlocks at the next UTC midnight; `Rolling` unlocks 86,400 seconds after the last claim. |
| `GracePeriodHours` | `0` | Additional time before a missed claim breaks the streak. Does not allow early claims. |
| `StreakFreeze` | `false` | Grants each fresh/reset record one rescue of a broken interval. No automatic refill. |
| `NotifyOnJoin` | `true` | Opens the popup on initial state. Players can reopen it with the launcher. |
| `Rewards` | Seven Coin entries | Ordered reward table. Each entry has `kind`, `name`, `amount`, and UI `label`. |
| `DataStoreName` | `"StreakRewards_v1"` | Store namespace. Changing it starts a separate history. |
| `RetryAttempts` | `4` | Maximum attempts per DataStore operation. |
| `RetryBaseSeconds` | `0.5` | Exponential backoff base, with jitter. |
| `RemoteCooldownSeconds` | `1` | Server-side per-player remote throttle. |

Reward kinds:

- `Attribute`: adds `amount` to the numeric player attribute named `name`, initializing it to zero if absent.
- `Leaderstats`: adds to a numeric value in the player's `leaderstats` folder.
- `Custom`: calls the registered server reward handler.

**Default Coins are a demonstration balance, not a persistent wallet.** Roblox player attributes and leaderstats disappear on leave unless your own data layer saves them. For a real economy, use a custom handler that updates your persistent wallet and records each receipt idempotently. Install that handler before players can claim. Do not use both this kit and another system to independently award the same receipt.

### Time and streak rules

The first claim starts streak 1. For an existing record, the next claim unlocks at the next UTC midnight or after 24 hours, depending on `TimeMode`. A streak breaks only when `now > nextClaimAt + 86400 + graceHours * 3600`. At that exact deadline, the streak survives. In UTC mode with zero grace, skipping an entire calendar day breaks the streak at the start of the following day plus one second. This inclusive boundary is deliberate.

A freeze rescues one broken interval even if several days were missed. It is consumed by a successful claim, not by viewing the calendar. A later break resets to day one. ResetPlayer creates a fresh record and replenishes the configured freeze. Future-dated existing claims deny new claims until their next valid unlock; they never give an early reward. All eligibility uses server `os.time()`; the client clock only draws the countdown.

The pure API is `StreakLogic.compute(lastClaimTime, streak, now, config, freezeAvailable?)`. It returns `canClaim`, `nextClaimAt`, `newStreak`, `rewardIndex`, and `streakBroken`. `newStreak` describes the next eligible claim, or the current streak while ineligible. `lastClaimTime = 0` means no previous claim.

## Server API

```lua
local rewards = require(game.ServerScriptService.StreakRewardsServer.StreakRewards)

local state = rewards.GetState(player)
if state then
    print(state.streak, state.canClaim, state.nextClaimAt)
end

local connection = rewards.Claimed:Connect(function(claimant, reward, newStreak)
    print(claimant.UserId, reward.label, newStreak)
end)

local resetSucceeded = rewards.ResetPlayer(player)
```

`GetState(player)` returns a server-computed packet or nil if unavailable. `Claimed` fires only after persistence and successful delivery. `ResetPlayer(player)` persists a fresh claim record and returns success; it does not remove currency already granted. Keep admin authorization in your own server code. Never expose reset directly to a remote.

`SetRewardHandler(fn)` overrides delivery for every reward kind, including `Custom`. Signature: `(player, reward, receiptId) -> ()`. Throw on failed delivery. The callback must record the receipt in the same transaction as the wallet change and return without granting again when it has already processed that receipt. Receipts are server-generated GUIDs passed to delivery, not a persisted recovery queue. The service does not provide a wallet implementation.

`SetAdapter(adapter)` replaces persistence before `Start()`. `Start()` is called by the included server bootstrap. To configure a custom adapter or handler deterministically, disable/remove that bootstrap and call SetAdapter, SetRewardHandler, then Start from your own single bootstrap. Do not rely on Script execution order.

### Persistence and adapter guide

Keys are `User_{UserId}`. Schema version 1 stores `{version, lastClaimTime, streak, freezeAvailable}`. The built-in adapter migrates legacy records and rejects future versions. A claim runs eligibility validation inside `UpdateAsync` against the current stored record, not just the join cache. It persists before delivering rewards. Transform callbacks do not yield or grant currency, because Roblox may invoke them more than once.

An adapter implements these dot-call functions:

```lua
Load(userId: number): Record
Update(userId: number, transform: (Record) -> Record): Record
Save(userId: number): ()
Release(userId: number): ()
```

`Load` must return a normalized record or throw, never invent a fresh record after a failed read. `Update` must atomically serialize the transform against the latest record, commit it, and return the final committed result. Its final transform invocation must correspond to that result. It may retry the transform, so do not put side effects in it. `Save` must flush safely without replacing newer records with stale join data. `Release` drops per-user resources only after in-flight operations finish. The built-in adapter uses a fresh UpdateAsync read on leave/shutdown rather than overwriting from cache.

See `examples/ProfileStoreAdapter.luau` for session-locked ProfileStore integration. Bring your own ProfileStore library, store, and profile ownership policy. Do not let both adapters own the same data. If your game already has profiles, integrate the reward record into those profiles instead of opening a second session for the same key. Review the example's notes before adoption.

### Delivery guarantees and failure handling

The claim record and a separate wallet cannot be atomically committed by two unrelated systems. This kit prevents duplicate eligibility across servers; it does not promise exactly-once external rewards. If a write succeeds but the response is lost, or a reward handler fails after the claim commits, the claim can be consumed without payout. The server warns and reports the failure, rather than reopening eligibility and risking duplicate currency. There is no automatic payout reconciliation queue. Use a durable transactional wallet/receipt system and your own support/reconciliation policy for valuable rewards.

The built-in adapter retries failed operations with exponential backoff and jitter. Live persistence errors deny claims. Leave and shutdown saves do not overwrite newer server claims. Roblox shutdown deadlines and outages can still prevent completion; inspect server warnings.

## Client UI and controls

The code-built popup includes a reward calendar, current streak, server-aligned countdown, claim button, close control, and reopen launcher. It uses scale-based sizing, UIScale, and safe-area insets. Touch and mouse use buttons. F7 or gamepad Y toggles the popup; gamepad B closes it. Enter or keypad Enter claims or checks availability while the popup is open and no text box has focus. On gamepad, select the claim button and activate it with A. The calendar follows `CycleLength`; seven is the shipped layout.

The client sends only no-argument `ClaimRequest` and `StateRequest` RemoteEvents. It never supplies reward amounts, timestamps, streaks, or target users. Server state arrives through `StateUpdate`. Replication waits have timeouts so a missing installation shows an unavailable state instead of waiting forever.

## Security notes

- Eligibility, UTC timestamps, reward lookup, and persistence run on the server.
- Remotes are rate-limited per player. Claims serialize per player locally and revalidate atomically across servers.
- A client can alter its own display, but not the authoritative claim decision.
- Config is not secret. Reward handlers and wallet code belong on the server.
- Reset authorization is your responsibility. No admin remote ships with the kit.
- DataStore persistence covers claim history only, not your currency balances.

## Development checks

```sh
export PATH="$HOME/.rokit/bin:$PATH"
lune run tests/run
stylua src tests
selene src
```

The pure tests run outside Roblox. They cannot prove Roblox UI rendering, gamepad navigation, live DataStore API behavior, or ProfileStore integration. Test the demo in Studio and on your target devices before selling rewards in your game.

## FAQ

**Why did Coins disappear after rejoining?** The default is a session-local player attribute. Connect a persistent wallet through a Custom reward handler.

**Why can players claim twice within 24 hours?** UTC mode permits one claim on each UTC date, including immediately before and after midnight. Choose Rolling for a minimum 24-hour interval.

**Why is a claim unavailable in Studio?** Check Output for API-access fallback or installation errors. The server must load state before claims are accepted. Fallback memory lasts only for that Studio server.

**Can I change the cycle length?** Yes. Change CycleLength and Rewards together, then restart. Existing streak totals remain; reward indices follow the new configuration.

**Can I grant another streak freeze?** The shipped option provides one freeze per fresh/reset record. A refill economy requires extending your own adapter and policy; there is no client freeze-grant remote.

**Can I use it in a commercial game?** Yes. It is MIT-licensed; keep the license notice in copies of the source.

## Changelog

### 1.0.0

Initial release. Typed Luau modules, daily claim logic, configurable cycles and timing, one-use freeze, authoritative persistence, adapter API, responsive popup, Lune logic tests, and Rojo package/demo projects. See CHANGELOG.md.

## Built with AI assistance

This project was written with the help of AI coding assistants and then reviewed and tested by the maintainer. Please review the code before using it in production, and open an issue if you find a problem.

## Support this project

This project is free and MIT-licensed. If it saved you time, an optional tip is appreciated and helps keep it maintained.

- **Solana (SOL or USDC on Solana):** `Cx9qsVknF5FYB2sS925zssK6GeiHBSy5gzwss8MxS3wp`
- Pay link (SOL): [`solana:Cx9qsVknF5FYB2sS925zssK6GeiHBSy5gzwss8MxS3wp?label=kensondev&message=Thanks`](solana:Cx9qsVknF5FYB2sS925zssK6GeiHBSy5gzwss8MxS3wp?label=kensondev&message=Thanks)
- Pay link (USDC): [`solana:Cx9qsVknF5FYB2sS925zssK6GeiHBSy5gzwss8MxS3wp?spl-token=EPjFWdd5AufqSSqeM2qN1xyybapC8G4wEGGkZwyTDt1v&label=kensondev`](solana:Cx9qsVknF5FYB2sS925zssK6GeiHBSy5gzwss8MxS3wp?spl-token=EPjFWdd5AufqSSqeM2qN1xyybapC8G4wEGGkZwyTDt1v&label=kensondev)

Please only send SOL or Solana-network USDC to this address. Tips are voluntary and do not buy support, priority or any license rights.

**EVM (Ethereum, Optimism, Base, Arbitrum, Polygon):** `0xF4C46D4D4747d14193e7Dad4eadbf544CFe74Bb0`

**Drips:** this repo has a [`FUNDING.json`](FUNDING.json) so it can receive streams/splits on [Drips](https://www.drips.network/app/projects/github/kensondev/roblox-streak-rewards).

## License

[MIT](./LICENSE) © 2026 Kenson (kensondev)
