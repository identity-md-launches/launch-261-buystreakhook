# Streak (STREAK)

An ownerless, fixed-supply token and Uniswap v4 daily-buy fee hook for **Sepolia (11155111)**.
STREAK is a test toy: the token and accumulated fees have no value, and no return is promised.

`STREAK` mints 1,000,000,000 tokens with 18 decimals once, entirely to its deploying factory.
`BuyStreakHook(IPoolManager)` has one constructor argument and no admin, setter, pause, mint,
upgrade, or sweep. Its address must encode exactly `0x00CC` in the low 14 bits.

## Build and test

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abi.py --check
```

Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, and `bytecode_hash = "none"` are pinned
in `foundry.toml`. All imported dependencies are ordinary files under `lib/`; no install,
submodule, RPC, environment variable, FFI, or filesystem cheatcode is required by the tests.
Foundry and the pinned compiler must already be installed for offline verification.

The suite deploys a real v4-core PoolManager and mines an actual CREATE2 hook address. Its
factory rehearsal mints to the factory, initializes the pool, and settles a one-sided STREAK
seed with **zero ETH prefunding**. It checks all four swap modes, dust, partial fills, failed
settlement, UTC boundaries, the discount floor, identity spoofing, per-pool isolation,
non-ETH pools, callback access, exact burns, and reentrancy. Fuzz tests and a stateful model
check fee accounting, calendar state, settlement, and supply conservation.

## Fee and streak rules

Days are `block.timestamp / 86_400`. A native-ETH-to-token buy with an ETH leg of at least
0.0005 ETH records at most one daily purchase per pool and identity. Consecutive days add
one; a missed day makes the effective streak zero and the next qualifying buy starts at one.
Sells and smaller buys never extend it.

Every native-ETH pool swap pays `max(100 - 10 * effectiveStreak, 30)` basis points of its ETH
leg, rounded down. The current swap uses the streak **before** recording its purchase. The
first qualifying buy costs 100 bps; the next swap costs 90 bps. Seven days unlock 30 bps.
This hook fee is separate from the pool's static 3000 (0.3%) LP fee.

The specified amount is always honored exactly; a partial fill reverts with `PartialFill`.
For exact-input buys the hook fee comes out of the specified ETH input. For exact-output
sells the pool supplies enough ETH to cover both the specified output and its fee. For
exact-output buys and exact-input sells, the fee uses the ETH the AMM actually moved.
Pools whose currency0 is not native ETH get no hook fees or streak changes.

## Identity and burn behavior

Routers pass `abi.encode(wallet)` as hookData. It is **unauthenticated data**, not a signature.
Only an exactly 32-byte, canonically encoded, nonzero address equal to `tx.origin` is accepted.
All other data gets the full 100 bps fee and credits nobody. The router's `sender` is never
used as the buyer. `tx.origin` only confirms a pricing claim; it never authorizes moving funds.

**Smart-contract wallets signed through a bundler or relayer never earn a discount for the
wallet address**, since that address differs from `tx.origin`. This is not proof of the
ultimate payer or token recipient: an intermediary in an EOA's transaction can pass that
origin's address. There is deliberately no router allowlist or signature-verification layer.

Fees are ERC-6909 native-ETH claims owned by the hook at the PoolManager. No ETH is taken
or transferred in swap callbacks. Anyone can call `burnFees()` outside a PoolManager unlock;
it burns every ETH claim, then takes exactly that ETH directly to
`0x000000000000000000000000000000000000dEaD`. It pays nothing to the caller. Empty burns
are no-ops. Voluntarily donated ETH claims are included. Direct ETH transfers revert;
forced ETH and unrelated assets have no recovery path.

See [ABI documentation](docs/ABI.md), [deployment parameters and handoff](docs/DEPLOYMENT.md),
[accounting and review notes](docs/SECURITY.md), and [dependency pins](docs/DEPENDENCIES.md).
This contribution supplies contracts, tests, and ABI exports. The independently produced
manifest, independent adversarial review, service deployment, and frontend are separate
workflow contributions; none is represented here as completed.
