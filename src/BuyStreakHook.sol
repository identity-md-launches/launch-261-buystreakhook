// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Daily buy discounts with native ETH fees held exclusively as PoolManager claims.
/// @dev Immutable and ownerless. hookData is a pricing hint, never authority to spend funds.
contract BuyStreakHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;

    IPoolManager public immutable poolManager;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant DAY = 86_400;
    uint256 public constant MIN_BUY = 0.0005 ether;
    uint256 public constant BASE_FEE_BPS = 100;
    uint256 public constant MIN_FEE_BPS = 30;
    uint256 public constant DISCOUNT_BPS = 10;

    struct Streak {
        uint256 count;
        uint256 lastDay;
    }

    mapping(PoolId poolId => mapping(address user => Streak)) private _streaks;
    uint256 private _pendingBurn;

    error NotPoolManager();
    error InvalidPoolManager();
    error HookNotImplemented();
    error PartialFill();
    error UnexpectedUnlock();

    event StreakUpdated(PoolId indexed poolId, address indexed user, uint256 day, uint256 streak);
    event FeeAccrued(PoolId indexed poolId, address indexed user, uint256 amount, uint256 feeBps);
    event FeesBurned(uint256 amount);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function streakOf(PoolId poolId, address user)
        public
        view
        returns (uint256 streak, uint256 lastDay, uint256 effectiveStreak, uint256 feeBps)
    {
        Streak memory s = _streaks[poolId][user];
        streak = s.count;
        lastDay = s.lastDay;
        uint256 today = block.timestamp / DAY;
        // Subtraction is guarded, including day zero. Old raw state is retained for display.
        effectiveStreak = today > lastDay && today - lastDay > 1 ? 0 : streak;
        feeBps = effectiveStreak >= 7 ? MIN_FEE_BPS : BASE_FEE_BPS - DISCOUNT_BPS * effectiveStreak;
    }

    function feeFor(PoolId poolId, address user) public view returns (uint256 feeBps) {
        (,,, feeBps) = streakOf(poolId, user);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        address user = _identity(hookData);
        uint256 bps = feeFor(key.toId(), user);
        uint256 fee = FullMath.mulDiv(_abs(params.amountSpecified), bps, 10_000);
        int128 delta = fee.toInt128();
        _accrue(key.toId(), user, fee, bps);
        // Exact-in ETH: less enters the AMM. Exact-out ETH: the AMM supplies extra ETH.
        // Either way, the caller's specified amount remains unchanged.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(delta, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        address user = _identity(hookData);
        // PoolManager makes no external user calls between our before/after callbacks.
        // The streak is only changed below, so both callbacks price from the same state.
        uint256 bps = feeFor(poolId, user);
        bool ethSpecified = _ethSpecified(params);
        uint256 ethLeg = ethSpecified ? _abs(params.amountSpecified) : _abs(int256(delta.amount0()));
        uint256 fee = FullMath.mulDiv(ethLeg, bps, 10_000);
        int256 expected = params.amountSpecified + (ethSpecified ? int256(fee) : int256(0));
        int256 filled = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        if (filled != expected) revert PartialFill();

        int128 returnedFee = 0;
        if (!ethSpecified) {
            returnedFee = fee.toInt128();
            _accrue(poolId, user, fee, bps);
        }
        if (params.zeroForOne && user != address(0) && ethLeg >= MIN_BUY) _recordBuy(poolId, user);
        return (IHooks.afterSwap.selector, returnedFee);
    }

    /// @notice Authoritative amount awaiting burn, including any voluntarily donated ETH claims.
    /// @dev No duplicate accumulator can drift from the ERC-6909 balance.
    function accruedFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), 0);
    }

    /// @notice Anyone may pay gas to burn all accrued fees. No caller-selected destination.
    /// @dev Must be called outside an existing PoolManager unlock. An empty burn is a no-op.
    function burnFees() external returns (uint256 amount) {
        amount = accruedFees();
        if (amount == 0) return 0;
        _pendingBurn = amount;
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = _pendingBurn;
        if (amount == 0) revert UnexpectedUnlock();
        _pendingBurn = 0;
        // Effects precede payout: clear both the pending amount and actual claim balance first.
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), BURN_ADDRESS, amount);
        emit FeesBurned(amount);
        return "";
    }

    function _accrue(PoolId poolId, address user, uint256 fee, uint256 bps) private {
        if (fee == 0) return;
        // Minting creates a debt cancelled by our positive return delta, without moving ETH.
        poolManager.mint(address(this), 0, fee);
        emit FeeAccrued(poolId, user, fee, bps);
    }

    function _identity(bytes calldata data) private view returns (address user) {
        if (data.length != 32) return address(0);
        // Validate canonical ABI padding before decode, so malformed data also gets the base fee.
        uint256 word = abi.decode(data, (uint256));
        if (word > type(uint160).max) return address(0);
        user = abi.decode(data, (address));
        if (user == address(0) || user != tx.origin) return address(0);
    }

    function _recordBuy(PoolId poolId, address user) private {
        Streak storage s = _streaks[poolId][user];
        uint256 today = block.timestamp / DAY;
        if (s.count != 0 && s.lastDay == today) return;
        s.count = s.count != 0 && today != 0 && s.lastDay == today - 1 ? s.count + 1 : 1;
        s.lastDay = today;
        emit StreakUpdated(poolId, user, today, s.count);
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _abs(int256 value) private pure returns (uint256) {
        // Also defined for type(int256).min; oversized fees subsequently fail a checked cast.
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    // These permissions are disabled, so factory initialization and liquidity operations never
    // call these entrypoints. Keeping explicit stubs makes the full IHooks ABI reviewable.
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
