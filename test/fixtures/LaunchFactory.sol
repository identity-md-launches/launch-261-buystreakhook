// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {STREAK} from "../../src/STREAK.sol";
import {BuyStreakHook} from "../../src/BuyStreakHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev Rehearses the described factory sequence; not a copy of an undisclosed live factory.
/// All concrete assumptions are documented in docs/DEPLOYMENT.md.
contract LaunchFactory is IUnlockCallback {
    uint160 public constant SQRT_PRICE_X96 = 792281625142643375935439503360000;
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 184200;
    IPoolManager public immutable manager;
    STREAK public token;
    BuyStreakHook public hook;
    uint256 public mintedToFactory;
    uint256 public seededTokens;
    uint128 public liquidity;
    PoolKey private _key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 salt) external {
        require(address(token) == address(0), "already launched");
        token = new STREAK();
        mintedToFactory = token.balanceOf(address(this));
        require(mintedToFactory == token.totalSupply(), "supply mismatch");
        hook = new BuyStreakHook{salt: salt}(manager);
        _key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(hook));
        manager.initialize(_key, SQRT_PRICE_X96);
        uint256 computed = FullMath.mulDiv(
            mintedToFactory,
            1 << 96,
            TickMath.getSqrtPriceAtTick(TICK_UPPER) - TickMath.getSqrtPriceAtTick(TICK_LOWER)
        );
        require(computed <= type(uint128).max, "liquidity overflow");
        liquidity = uint128(computed);
        manager.unlock("");
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            _key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(uint256(liquidity)), bytes32(0)), ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be token only");
        seededTokens = uint256(-int256(delta.amount1()));
        manager.sync(_key.currency1);
        token.transfer(address(manager), seededTokens);
        require(manager.settle() == seededTokens, "settlement mismatch");
        return "";
    }
}
