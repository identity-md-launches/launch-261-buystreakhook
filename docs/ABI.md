# Contract interfaces

Machine-readable ABI arrays:

- [STREAK.json](abi/STREAK.json)
- [BuyStreakHook.json](abi/BuyStreakHook.json)

Regenerate with `python3 scripts/export_abi.py`, or verify freshness with `--check`.
The script invokes `forge inspect` using this repository's pinned build configuration.

## STREAK

Constructor: `constructor()` (nonpayable). The constructor caller receives the whole supply.
Standard OpenZeppelin ERC-20 `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`,
`totalSupply`, `name`, `symbol`, and `decimals`; standard `Transfer` and `Approval` events and
ERC-6093 errors. Infinite approvals are not decremented; there is no public mint or burn.

## BuyStreakHook

Constructor: `constructor(IPoolManager manager)` (ABI type `address`, nonpayable).

| Function | Result / behavior |
| --- | --- |
| `poolManager()` | Immutable manager address. |
| `getHookPermissions()` | v4's 14-boolean permissions tuple; only beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta are true. |
| `streakOf(bytes32 poolId, address user)` | `(uint256 streak, uint256 lastDay, uint256 effectiveStreak, uint256 feeBps)` in that order. |
| `feeFor(bytes32 poolId, address user)` | `uint256 feeBps` for the address's current effective streak. |
| `accruedFees()` | `uint256`, actual manager ERC-6909 balance at id 0, in wei. Includes donated ETH claims. |
| `burnFees()` | Permissionless, nonpayable. Returns the wei burned; zero if empty. No destination parameter. |
| `BURN_ADDRESS()` | Fixed dEaD destination. |
| `DAY()`, `MIN_BUY()` | 86,400 seconds and 500,000,000,000,000 wei. |
| `BASE_FEE_BPS()`, `MIN_FEE_BPS()`, `DISCOUNT_BPS()` | 100, 30, and 10. |

`PoolId` is represented as `bytes32`. Compute it as
`keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`, using types
`(address,address,uint24,int24,address)` and the actual initialized key. Native ETH is
`address(0)`, not WETH. Records are scoped to the whole key, including fee, spacing, and hook.

`streak` and `lastDay` retain historical stored values after expiry; `effectiveStreak` and
`feeBps` reflect the current UTC day without requiring a transaction. An unseen identity
returns `(0, 0, 0, 100)`. Day zero is valid; use `streak == 0` to distinguish an unseen record.
Views quote account standing, not hookData validity. Invalid hookData pays 100 regardless of
the quoted account; non-ETH pools pay zero at runtime regardless of the default quote.

## Events

```solidity
event StreakUpdated(bytes32 indexed poolId, address indexed user, uint256 day, uint256 streak);
event FeeAccrued(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 feeBps);
event FeesBurned(uint256 amount);
```

`StreakUpdated` fires only when a qualifying buy changes a daily record (once per pool,
identity, day). There is no event just because a streak expires; clients calculate expiry.
`FeeAccrued` fires for each nonzero fee at the callback that mints it; `user` is zero for
anonymous pricing. `amount` is wei and `feeBps` is the pre-update rate. Zero-rounding dust
does not emit it. `FeesBurned` fires after a successful nonzero payout. All events roll back
with a failed swap, settlement, or payout.

## Callbacks and errors

The ABI includes standard v4 `IHooks` signatures, with `PoolKey`, `SwapParams`,
`ModifyLiquidityParams`, packed `BalanceDelta` and `BeforeSwapDelta` types. Applications
should swap via a router, not call these callbacks directly. Every callback, including
`unlockCallback(bytes)`, requires the immutable PoolManager caller.

Disabled callbacks revert `HookNotImplemented` when directly called by the manager; v4
does not invoke them because their address bits are off. Consequently pool initialization,
adding/removing liquidity, and donations are unaffected by the hook.

Errors: `NotPoolManager`, `InvalidPoolManager` (zero constructor address),
`HookNotImplemented`, `PartialFill`, and `UnexpectedUnlock` (no pending fee burn).
Constructor permission mismatch uses v4's `HookAddressNotValid(address)`; arithmetic casts
may use `SafeCastOverflow`. v4 wraps hook failures in
`WrappedError(address target, bytes4 selector, bytes reason, bytes details)` with
`HookCallFailed` context, so inspect its nested `reason` to identify `PartialFill`.
Calling a nonempty `burnFees()` during an existing unlock reverts `AlreadyUnlocked`.
