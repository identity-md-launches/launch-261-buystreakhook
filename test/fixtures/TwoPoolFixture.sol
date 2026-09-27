// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StreakFixture} from "./StreakFixture.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Real swaps fund two users and another pool of the SAME currencies and hook.
/// Only the LP fee differs, so token-keyed or user-only streak storage cannot pass.
abstract contract TwoPoolFixture is StreakFixture {
    PoolKey internal sibling;
    PoolId internal siblingId;
    uint256 internal constant FUNDING_FEES = 0.022 ether;

    function setUp() public virtual override {
        super.setUp();
        _checkedSwap(ALICE, _params(true, -1 ether), "", 100);
        _checkedSwap(BOB, _params(true, -1 ether), "", 100);
        sibling = key;
        sibling.fee = 500;
        siblingId = sibling.toId();
        assertNotEq(PoolId.unwrap(siblingId), PoolId.unwrap(poolId));
        manager.initialize(sibling, factory.SQRT_PRICE_X96());
        ModifyLiquidityParams memory seed = ModifyLiquidityParams(
            factory.TICK_LOWER(), factory.TICK_UPPER(), int256(uint256(factory.liquidity() / 20)), 0
        );
        vm.startPrank(ALICE);
        token.approve(address(liquidityRouter), type(uint256).max);
        BalanceDelta seeded = liquidityRouter.modifyLiquidity(sibling, seed, "");
        vm.stopPrank();
        assertEq(seeded.amount0(), 0, "second seed is also token only");
        assertLt(seeded.amount1(), 0);
        _checkedSwap(sibling, BOB, _params(true, -0.2 ether), "", 100);
        assertEq(hook.accruedFees(), FUNDING_FEES);
    }
}
