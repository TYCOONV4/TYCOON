# TYCOON

An on-chain board game that lives inside a Uniswap v4 pool. Three contracts, no owner, nothing upgradeable.

- `src/MonoToken.sol` — fixed supply ERC-20 (1,000,000,000 TYCOON). No mint, no pause, no transfer tax. Carries the
  project card in `metadata()` and `tokenURI()`.
- `src/MonopolyHook.sol` — the pool hook and the game. Immutable fee split, the board, the pieces, the streets, the
  START treasury, the claims.
- `src/Seeder.sol` — one-shot launch initializer: sends the START treasury to the hook, opens the pool, seeds the
  liquidity, makes the launch buy, burns what is left.

## The game

The board is 30 squares. Every swap through the pool with an ETH leg of at least 0.01 ETH is a turn: it rolls two
dice for the wallet that signed the transaction and walks its piece. The dice come from the block hash of the piece's
previous move, so the next roll is readable in advance and nobody can bend it. Doubles fling the piece twice as far.
Landing on Go-to-Jail sends the piece to Jail with no payout. One move per piece per block.

Passing START pays TYCOON from the treasury: `treasury × min(your share of the TYCOON held by players, 1%)`.

22 squares are coloured streets, bought with TYCOON while the piece stands on them:

- `buyLand` — an empty street costs base × 1.1 (base = colour rank × 1,000,000 TYCOON); the base is locked as the
  street's price, the 10% goes to the treasury.
- `overbuy` — take a street from its owner for 1.2 × price: the price climbs to 1.1 ×, the old owner receives 1.1 ×.
- `returnLand` — give a street back for 0.9 × price; 0.1 × goes to the treasury.

Street owners share 2.2% of every swap's ETH leg by colour weight (rank 1..8, ×1.25 for a complete colour).
Rewards are pull: `claim()`. A reward left unclaimed for 24 hours after the owner's last claim (or buy-in) can be moved
by anyone (`purge`) to the other street owners, by weight; the streets themselves are never touched.

## Fees

3.5% of the gross ETH leg on every buy and sell, including the launch buy:

| share | pips | to |
|---|---|---|
| platform | 3,000 | `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`, accrued as ERC-6909 ETH claims, paid by `collect()` |
| team | 10,000 | the immutable team recipient, same mechanism |
| streets | 22,000 | ETH held by the hook, split among street owners by weight; before the first street is bought it waits in a buffer and goes to the first buyer |

The LP fee of the pool is zero. Nothing else charges anything.

## Launch

One transaction through the Programmable launch router deploys the three contracts and runs `Seeder.ignite`: the
START treasury (10% of supply) goes to the hook, the pool opens, the remaining 90% becomes a single token-only
position owned by `0x000000000000000000000000000000000000dEaD` through the canonical PositionManager, part of the
transaction value makes the launch buy, the bought tokens and the remaining ETH become a full-range position also owned
by the dead address, and whatever is left is burned. No contract holds a withdrawal path for either position. The team
ends the launch with zero tokens.

Launch guard: for the first 20 swaps after the launch buy, and only within 10 blocks of the launch, one buy may take at
most 2% of the supply (20,000,000 TYCOON); a larger buy reverts. Sells are never capped. Whichever ends first, the swap
count or the block window, ends the guard.

## Disclosures

- No owner, admin, pause, mint, blacklist, transfer restriction or upgrade path in any contract.
- The hook is called by the PoolManager on every swap of the pool through any router; the player is `tx.origin`.
- Exact-input and exact-output swaps in both directions are supported; the fee is always taken on the ETH leg.
- External calls on the swap path: none beyond the PoolManager and the token.

## Build and test

```
forge build
ETH_RPC=<mainnet rpc> forge test   # launch and the game on a mainnet fork
```
