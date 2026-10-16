# TYCOON

An on-chain board game that lives inside a Uniswap v4 pool, launched through Programmable with the mandatory
launch-protection v1 package. No owner, nothing upgradeable.

## Contracts

| contract | source | origin |
|---|---|---|
| `ProtectedNativeInitializerV1` | `src/launch-protection/ProtectedNativeInitializerV1.sol` | launch-protection v1, unchanged |
| `TycoonToken` | `src/TycoonToken.sol` | `ProtectedLaunchTokenV1` (unchanged) plus `metadata()` and `tokenURI()` |
| `TycoonHook` | `src/TycoonHook.sol` | `ProtectedNative30HookV1` (unchanged kernel) plus the game; additions are marked `TYCOON` |
| `LaunchProtectionModuleV1` | `src/launch-protection/LaunchProtectionModuleV1.sol` | created by the hook, unchanged |
| `EthereumNativeFeeVaultV3` ×2 | `src/ethereum-native30-v3/EthereumNativeFeeVaultV3.sol` | created by the hook, unchanged |

`protection/standard-json.json` and `protection/artifacts/` are the package's exact compiler input and artifacts
(`@programmable/launch` 4.1.7, `contracts/launch-protection-v1`). Everything compiles with the package settings:
solc 0.8.26, via IR, optimizer 200, Cancun, no metadata hash. The sources in `src/launch-protection` and
`src/ethereum-native30-v3` are byte-identical to the package; the module and the vaults compiled here reproduce the
package runtimes exactly.

## Launch and protection

One transaction through the Programmable launch router deploys the initializer, the token and the hook and calls
`initialize`: the whole supply (1,000,000,000 TYCOON) becomes one token-only position that the initializer locks
forever, the opening valuation is checked against the Chainlink ETH/USD feed (at least USD 15,000 FDV), trading
starts, and the launch buy is executed for the developer. Right after the launch the developer sends everything that
buy returned into the START treasury with `fundTreasury`; the team ends with zero tokens.

For the first 300 seconds buys go only through the pinned Universal Router, every buyer and every recipient is
capped at 2% of the supply cumulatively, and the total buy fee starts at 99% and decays linearly to the normal fee
over 30 seconds; the extra part is claimable only by the Programmable treasury. The developer and up to six wallets
fixed in the constructor are exempt from the extra fee only; the caps still apply to them.

## Fees

Every buy and sell pays 3.5% of the gross ETH leg, rounded up per trade:

| share | bps | to |
|---|---|---|
| platform | 30 | `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`, through the fee vault (`claimPlatform`) |
| team | 100 | the immutable creator recipient, through the fee vault (`claimCreator`) |
| streets | 220 | ETH held by the hook, split among street owners by weight; before the first street is bought it waits in a buffer and goes to the first buyer |

The LP fee of the pool is zero. The opening tax of the first 30 seconds is on top of this and goes to the second
vault, owned by the platform treasury.

## The game

The board is 30 squares. Every swap through the pool with an ETH leg of at least 0.01 ETH is a turn: it rolls two
dice for the wallet that signed the transaction and walks its piece. The dice come from the block hash of the piece's
previous move, so the next roll is readable in advance and nobody can bend it. Doubles fling the piece twice as far.
Landing on Go-to-Jail sends the piece to Jail with no payout. One move per piece per block. The launch buy is not a
turn.

Passing START pays TYCOON from the treasury: `treasury × min(your share of the TYCOON held by players, 1%)`. The
treasury starts empty, receives the launch buy through `fundTreasury`, and grows with street price mark-ups.

22 squares are coloured streets, bought with TYCOON while the piece stands on them:

- `buyLand` — an empty street costs base × 1.1 (base = colour rank × 1,000,000 TYCOON); the base is locked as the
  street's price, the 10% goes to the treasury.
- `overbuy` — take a street from its owner for 1.2 × price: the price climbs to 1.1 ×, the old owner receives 1.1 ×.
- `returnLand` — give a street back for 0.9 × price; 0.1 × goes to the treasury.

Street owners share 2.2% of every swap's ETH leg by colour weight (rank 1..8, ×1.25 for a complete colour).
Rewards are pull: `claim()`. A reward left unclaimed for 24 hours after the owner's last claim (or buy-in) can be moved
by anyone (`purge`) to the other street owners, by weight; the streets themselves are never touched.

## Disclosures

- No owner, admin, pause, mint, blacklist or upgrade path in any contract. The token's 2% receiving limit lasts only
  for the first 300 seconds, as in the package.
- The hook is called by the PoolManager on every swap of the pool; the player is `tx.origin`.
- Exact-input and exact-output swaps in both directions are supported; ETH-specified partial fills revert, as in the
  kernel.
- External calls on the swap path: the PoolManager, the token, the protection module and the vaults.

## Build and test

```
forge build
ETH_RPC=<mainnet rpc> forge test   # launch, protection window, fees and the game on a mainnet fork
```
