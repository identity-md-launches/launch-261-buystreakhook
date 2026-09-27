# Accounting and review notes

These are implementation notes and locally tested properties, not an independent audit.
The separate adversarial review and final service/factory reconciliation remain workflow steps.

## Delta accounting

The implementation follows the pinned v4-core [Hooks implementation](../lib/v4-core/src/libraries/Hooks.sol)
and [PoolManager implementation](../lib/v4-core/src/PoolManager.sol). Positive hook deltas
are subtracted from the swapper's delta and credited to the hook. Its claim mint creates the
opposite debt. No custom liquidity, oracle, or dynamic LP-fee override is involved.

Let `S` be the absolute specified amount, `E` the absolute AMM ETH delta, and
`F = floor(ETH base * pre-swap bps / 10000)`.

| Mode | ETH base | Hook return | Full-fill AMM specified delta | Swapper specified delta |
| --- | --- | --- | --- | --- |
| Exact-input buy | S | beforeSwap: specified +F | ETH = -S + F | ETH = -S |
| Exact-output sell | S | beforeSwap: specified +F | ETH = S + F | ETH = S |
| Exact-output buy | E | afterSwap: unspecified +F | STREAK = S | STREAK = S |
| Exact-input sell | E | afterSwap: unspecified +F | STREAK = -S | STREAK = -S |

`afterSwap` compares the actual AMM specified delta to the expected one in this table. Any
difference reverts `PartialFill`, rolling back the earlier claim mint too. In particular,
the beforeSwap delta cannot consume the entire input: the fee is at most 1%, rounded down.
Unchecked truncating casts are not used for returned fees; v4's checked int128 conversion
rejects an oversized fee. FullMath handles multiplication without overflowing its numerator.

For each nonzero fee, `mint(hook, 0, F)` posts a hook debt of `-F`; the hook return accounts
`+F`, netting to zero. Claims don't require the PoolManager to hold ETH at callback time.
The router settles the final swapper delta after the callbacks. The test suite compares
actual transfers with the independently emitted AMM Swap event and asserts every delta
is zero after unlocking.

On payout, the pending unlock amount is zeroed, then `burn(hook, 0, amount)` removes every
ETH claim and posts `+amount`; `take(native, dEaD, amount)` posts `-amount` and transfers ETH.
The claims are already zero before that transfer can invoke recipient code. Failures roll
everything back. Only a manager callback for a pending burn can take this path, and there
is no caller-chosen currency, amount, or destination. Nested manager unlocks are rejected.

`accruedFees()` reads the actual claim balance instead of a second liability counter, so
even third-party ERC-6909 donations are accounted for and burned. The hook never approves
an operator or claim spender. Direct ETH and unrelated tokens are not treated as fee claims.

## Identity and calendar boundaries

All IHooks entrypoints and the unlock callback gate on the immutable manager. Data with
wrong length, noncanonical address padding, zero address, or a different transaction origin
gets no identity. No public callback or burn path spends funds on behalf of `tx.origin`.
The accepted origin check is only a discount rule; it does not authenticate a recipient,
wallet signature, or who economically paid for the transaction. Contract wallets using
relayers/bundlers cannot accrue discounts under their wallet addresses.

Fees are calculated before `_recordBuy`. The manager has no external user call between
the two swap callbacks, so recomputing the quote in afterSwap observes the same streak
state without transient/persistent per-swap scratch storage. The only external call during
fee accrual is the immutable canonical manager's ERC-6909 mint, which has no receiver hook.

The calendar guards day-zero subtraction. A zero count distinguishes an unseen user from
a real purchase on day zero. Repeated purchases in a day emit no extra calendar event;
subthreshold buys, invalid identities, sells, and failed swaps never extend standing. Raw
streaks can grow above seven, but rate calculation caps before multiplying, so the 30 bps
floor cannot underflow. The threshold uses the same ETH base as the fee; an exact-output
buy's additional hook fee cannot make a subthreshold pool leg qualify.

## Validation and limits

- A real PoolManager, mined constructor, and token-only factory unlock exercise initialization
  and the first buy without ETH reserves. Every swap mode is checked for exact specified
  amounts, fee sign/rounding, settlement, and price-limit rollback.
- Stateful randomized sequences compare claims and burns to a separate fee ledger and
  streaks to an independent calendar model. Token supply and settlement conservation are
  asserted throughout. Fuzzing varies swap mode, amount, and prior discount tier.
- Tests attack malformed/mismatched hookData, bundler identity, all callback entrypoints,
  day zero, midnight, missed days, fee floors, exact thresholds, non-ETH pools, distinct
  pools, claim theft, failed router settlement, failed payout, and payout reentrancy.
- Runtime scans reject SELFDESTRUCT, DELEGATECALL, and CALLCODE in both delivered contracts;
  no environment-dependent or filesystem cheatcodes are used by authored tests.
- Local tests do not attest the runtime at the supplied Sepolia manager address, reproduce
  an unavailable factory implementation, or verify an absent final manifest. No fork test,
  formal proof, external static analyzer, independent audit, deployment, or service admission
  is claimed. Deployment parameters requiring reconciliation are explicit in DEPLOYMENT.md.

Foundry may report generic lint warnings about `tx.origin`, timestamp comparisons, and
events after manager calls. These uses are intentional requirements: origin is a pricing
check, time defines the UTC calendar, and the canonical manager's mint has no receiver
callback. Payout reentrancy is covered with test-only recipient code at the fixed destination.
