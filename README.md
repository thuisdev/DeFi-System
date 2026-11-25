# Nexum

A small yield system built from three classic DeFi building blocks:

| Contract | Role |
|---|---|
| `NexumToken` (NXM) | Underlying ERC-20. Owner can mint (funds users and the reward pool). |
| `WrappedNexumToken` (wNXM) | 1:1 receipt for staked NXM. Mint/burn gated by `MINTER_ROLE` / `BURNER_ROLE`, both held by `Deposit`. |
| `Staking` | Synthetix-style single-token staking. Stake NXM, earn NXM. |
| `AutocompoundingVault` (aNXM) | solmate ERC-4626 vault for wNXM that streams harvested rewards over 7 days. Share token name is NexumShares. |
| `Deposit` | Entry point. Wraps NXM into wNXM, stakes everything, harvests rewards into the vault. |

```
User ──NXM──▶ Deposit ──stake──▶ Staking
               │                    │ NXM rewards
               │ mint wNXM 1:1      ▼
               │             harvest(): claim → re-stake → mint same amount of wNXM into the vault
               ▼                                          → vault.notifyRewardAmount()
   compound=false: wNXM to receiver
   compound=true:  wNXM into vault → receiver gets aNXM
```

**Core invariant:** `wNXM.totalSupply() == staking.balanceOf(deposit)`. Every wNXM is backed by exactly one staked NXM.
All staking yield flows into the vault, so only aNXM holders earn it; plain wNXM holders keep a liquid 1:1 claim.
This is the same shape as Frax's original frxETH / sfrxETH.

`deposit` takes an explicit `amount`. Pulling the full allowance breaks on `type(uint256).max` approvals, pulling the
full balance takes the size of the deposit away from the user, and "send first, then call" can be front-run.
`totalNexumDeposited` and `totalWrappedNexumMinted` are cumulative, not current balances. After the first harvest
`totalWrappedNexumMinted > totalNexumDeposited`; the difference is all yield harvested so far.
`totalAssets()` counts wNXM (user deposits plus rewards streamed so far), not the raw token balance.

## Sepolia deployment (verified)

| Contract | Address |
|---|---|
| NXM | [`0x0abD0FD769b0A9D8f73186290Df487b5b5FF8A0D`](https://sepolia.etherscan.io/address/0x0abd0fd769b0a9d8f73186290df487b5b5ff8a0d) |
| wNXM | [`0xbdb27b6c65E0A2C05bF531415cABd74f5FD32C95`](https://sepolia.etherscan.io/address/0xbdb27b6c65e0a2c05bf531415cabd74f5fd32c95) |
| Staking | [`0xc8691833E90F9c5001aE9217DfE5C4Ad41B3738f`](https://sepolia.etherscan.io/address/0xc8691833e90f9c5001ae9217dfe5c4ad41b3738f) |
| AutocompoundingVault | [`0x23b4CA9C3fd369C1B90307e3bA05d2C096027104`](https://sepolia.etherscan.io/address/0x23b4ca9c3fd369c1b90307e3ba05d2c096027104) |
| Deposit | [`0xFc01eB195A18f15B0BD293e7B9ed916c24c68FB5`](https://sepolia.etherscan.io/address/0xfc01eb195a18f15b0bd293e7b9ed916c24c68fb5) |

Deployment order is fixed by constructor dependencies: NXM → wNXM → Staking → Vault → Deposit, then
`vault.setDepositContract(deposit)` and both wNXM roles granted to Deposit. See `script/Deploy.s.sol`.

```bash
forge test
forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --sender <address> \
  --broadcast --verify --skip-simulation --slow
```

## App

`web/` is one Sepolia page: connect a wallet, read NXM / wNXM / aNXM, deposit into either receipt, and withdraw back to NXM. RainbowKit opens on Sepolia and asks the wallet to switch if it is on another network.

Minting NXM is restricted to the token owner. Any wallet can connect and read balances. A wallet with no NXM cannot deposit. The owner sees **Mint 1,000 test NXM** on the page and can transfer tokens to someone who wants to try the flow.

```bash
cd web
npm install
npm run dev
```

The WalletConnect QR code needs `VITE_WALLETCONNECT_PROJECT_ID` in `web/.env` (see `web/.env.example`). MetaMask and other injected wallets work without it.

For a public URL, deploy the `web/` directory on Vercel and set that variable there. The project root on Vercel is `web`, not the repository root.

## What I Learned

**The Synthetix accumulator.** Paying many stakers per second is impossible if you update every user. Instead there
is one global counter, `rewardPerToken` ("reward one staked token has earned since the start"), and each user stores
the counter value at their last settlement. Earned = balance × (counter now − counter at last settlement), like an
electricity meter. The rule that makes it correct: `updateReward` must run *before* any change to a balance or to
`totalSupply`, otherwise a new stake would earn rewards retroactively.

**ERC-4626 share math and why `totalAssets()` matters.** Yield in a vault never gets transferred to anyone. It raises
`totalAssets()` while the share supply stays the same, so every share is worth more. Because my `totalAssets()` is an
internal count (`totalStaked + earned()`) and not `balanceOf(this)`, donating tokens directly to the vault cannot move
the share price, which blocks the classic ERC-4626 inflation attack.

**Why rewards are streamed.** If the vault credited a harvest instantly, someone could deposit one block before
`harvest()` and withdraw right after with a share of the yield. Streaming over 7 days makes that worth one second of
rewards (there is a test for exactly this).

**Measure, don't trust.** `harvest()` measures the NXM balance delta around `getReward()` instead of trusting
`earned()`. Minting wNXM for more than actually arrived would silently break the 1:1 backing.

**Thinking in invariants.** Almost every bug I hit during the build would have broken one of three properties (wNXM
fully backed, vault can cover `totalAssets`, staking solvent). Writing those down as invariant tests found a real
edge case I had not thought of (see below).

## Problems & Solutions

**1. Missing re-stake broke the backing.** My first `harvest()` minted wNXM for the rewards but left the reward NXM
sitting in `Deposit`. That creates wNXM without staked NXM behind it, so the last users to redeem would fail. Fix:
re-stake the reward first, then mint ("back it before it exists"). Test: `test_harvest_restakesRewardsAndMintsToVault`.

**2. Two underflows in the vault's reward stream.**
- Setting `lastUpdateTime = block.timestamp` in `harvest()` after the period ended made `earned()` compute
  `periodFinish − lastUpdateTime` < 0. Since solmate calls `totalAssets()` on every deposit and withdrawal, this would
  have bricked the whole vault. Fix: `lastTimeRewardApplicable()`, so `lastUpdateTime` never passes `periodFinish`.
- Withdrawing everything (deposit + streamed rewards) underflowed `totalStaked`, because the rewards were only in
  `earned()`. Fix: `beforeWithdraw` calls `harvest()` first, which moves `earned()` into `totalStaked`. `harvest()`
  returns early instead of reverting on zero, otherwise a user with no rewards could never withdraw.

**3. CEI vs. correctness in `harvest()`.** The reward amount is only known after `getReward()`, so the event and the
counter update come after an external call (Foundry's linter flags `reentrancy-events`). I chose the balance delta
over pre-reading `earned()` because protecting the backing invariant matters more than a pure CEI order. The function
is `nonReentrant`, only calls trusted contracts, and the lint is disabled with a comment explaining why.

**4. Sepolia deployments ran out of gas although the simulation passed.** All five contract creations reverted while
the role calls "succeeded" – only because calls to addresses without code always succeed. `cast receipt … gasUsed`
equalled `cast tx … gas`, so it was out of gas. Sepolia had activated the Glamsterdam upgrade on October 6, which
reprices state creation (EIP-8037), while Foundry still estimated gas locally with the old rules: `cast estimate
--create` against Sepolia showed ~16.7M gas for the token instead of ~3.1M, and even `--gas-estimate-multiplier 300`
was not enough. The fix was `--skip-simulation` (the node, which knows the new rules, estimates gas) plus `--slow`, so
the script stops at the first failure instead of sending calls to empty addresses. The final deployment confirms it:
the NXM token alone used ~7.9M gas. Lesson: a successful simulation is not proof, and network upgrades can break
tooling. I now verify a deployment with `cast code` and role checks instead of trusting the log.

## Testing Approach

43 tests, **~98 % line coverage** (`forge coverage`). Tests reuse the deploy script's order and wiring in
`BaseTest.t.sol`, so they exercise the system the way it is actually deployed.

| Suite | Focus |
|---|---|
| `Tokens.t.sol` | Token metadata, owner-only NXM mint, wNXM roles |
| `Deposit.t.sol` | 1:1 minting, compound path into the vault, harvest re-stakes and syncs, redeem burns only from the caller, counters, events, zero checks, fuzzed backing |
| `AutocompoundingVault.t.sol` | Access control, linear streaming and share price, harvest leaves `totalAssets` unchanged, regression tests for both underflows, inflation-attack defense, just-in-time deposit gets ~nothing |
| `Staking.t.sol` | Proportional rewards (late staker gets only what accrued since joining), no rewards after `periodFinish`, leftover rollover, `exit` with only rewards left, staked NXM never counts as reward funding |
| `Integration.t.sol` | Full journey: Alice compounds, Bob holds wNXM; after harvest Alice receives deposit + all yield, Bob exactly his deposit |
| `invariant/` | Random sequences of deposit / redeem / vault redeem / warp + harvest across three actors, checking the three system invariants after every call |

**Why these.** Each bug from *Problems & Solutions* has a regression test. Beyond that I focused on what can lose
money or lock funds: unauthorized mint/burn/notify, broken backing, underflows that brick the vault, and unfair
reward distribution. Rounding-sensitive values are checked with `assertApproxEqAbs` and tight tolerances.

**What the invariant test found.** With a dust share supply (e.g. 1 wei of aNXM left) and rewards still streaming,
one share becomes worth so much that a normal deposit rounds down to zero shares and solmate reverts with
`ZERO_SHARES`. No funds are lost, but compounding deposits are blocked until the supply grows; at slightly larger
dust levels a depositor could lose part of a deposit to rounding. It is documented and reproduced in
`test_dustShareSupply_largeRewards_blocksSmallDeposits`. Production fixes would be virtual shares / a decimals
offset (as in OpenZeppelin's ERC4626) or minting dead shares at deployment; the vault stays on solmate's ERC4626.
The handler falls back to a plain deposit in that state so the fuzzer can keep exploring the backing invariant.

**Deliberately left out.** No tests for OpenZeppelin/solmate internals (ERC-20 transfers, role admin logic), no fork
tests (the system has no external dependencies), no gas benchmarks. I kept roughly ten focused tests per contract
instead of exhaustive permutations.
