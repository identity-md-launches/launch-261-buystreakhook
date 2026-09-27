// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {STREAK} from "../../src/STREAK.sol";
import {BuyStreakHook} from "../../src/BuyStreakHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {HookMiner} from "./HookMiner.sol";
import {LaunchFactory} from "./LaunchFactory.sol";

abstract contract StreakFixture is Test {
    using TransientStateLibrary for IPoolManager;

    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant START_DAY = 20_000;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant STREAK_TOPIC = keccak256("StreakUpdated(bytes32,address,uint256,uint256)");

    PoolManager internal manager;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    LaunchFactory internal factory;
    STREAK internal token;
    BuyStreakHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public virtual {
        vm.warp(START_DAY * 1 days);
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        factory = new LaunchFactory(manager);
        bytes32 hash = keccak256(abi.encodePacked(type(BuyStreakHook).creationCode, abi.encode(manager)));
        bytes32 salt = HookMiner.mine(address(factory), hash);
        factory.launch(salt);
        hook = factory.hook();
        token = factory.token();
        key = factory.poolKey();
        poolId = key.toId();
        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
        vm.deal(address(this), 1000 ether);
        vm.prank(ALICE);
        token.approve(address(router), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(router), type(uint256).max);
    }

    function _params(bool buy, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swap(PoolKey memory swapKey, address user, SwapParams memory params, bytes memory data)
        internal
        returns (BalanceDelta)
    {
        vm.prank(user, user);
        return router.swap{value: params.zeroForOne && swapKey.currency0.isAddressZero() ? 100 ether : 0}(
            swapKey, params, PoolSwapTest.TestSettings(false, false), data
        );
    }

    function _buy(address user, uint256 amount) internal returns (BalanceDelta) {
        return _swap(key, user, _params(true, -int256(amount)), abi.encode(user));
    }

    function _routerSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    struct Snapshot {
        uint256 claims;
        uint256 userEth;
        uint256 managerEth;
        uint256 userTokens;
        uint256 managerTokens;
    }

    /// @dev Compare final wallet transfers and claims to the independent AMM Swap event.
    function _checkedSwap(address user, SwapParams memory params, bytes memory data, uint256 bps)
        internal
        returns (BalanceDelta delta, uint256 fee)
    {
        Snapshot memory before_ = Snapshot(
            hook.accruedFees(),
            user.balance,
            address(manager).balance,
            token.balanceOf(user),
            token.balanceOf(address(manager))
        );
        vm.recordLogs();
        delta = _swap(key, user, params, data);
        BalanceDelta core = _coreDelta(vm.getRecordedLogs(), poolId);
        bool ethSpecified = params.zeroForOne == (params.amountSpecified < 0);
        uint256 base = ethSpecified ? _abs(params.amountSpecified) : _abs(core.amount0());
        fee = base * bps / 10_000;
        assertEq(hook.accruedFees() - before_.claims, fee, "claims = rounded ETH fee");
        assertEq(int256(delta.amount0()), int256(core.amount0()) - int256(fee), "ETH-only hook fee");
        assertEq(delta.amount1(), core.amount1(), "STREAK untouched by hook");
        assertEq(ethSpecified ? delta.amount0() : delta.amount1(), params.amountSpecified, "specified exact");
        assertEq(int256(user.balance) - int256(before_.userEth), delta.amount0(), "wallet ETH settlement");
        assertEq(int256(address(manager).balance) - int256(before_.managerEth), -int256(delta.amount0()));
        assertEq(int256(token.balanceOf(user)) - int256(before_.userTokens), delta.amount1());
        assertEq(
            int256(token.balanceOf(address(manager))) - int256(before_.managerTokens),
            -int256(delta.amount1())
        );
        _assertSettled();
    }

    function _coreDelta(Vm.Log[] memory logs, PoolId id) internal view returns (BalanceDelta) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                (int128 a0, int128 a1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(a0, a1);
            }
        }
        revert("missing AMM Swap event");
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.getNonzeroDeltaCount(), 0, "all deltas settled");
        assertFalse(pm.isUnlocked());
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(router), key.currency0), 0);
        assertEq(address(hook).balance, 0, "callbacks never receive ETH");
        assertEq(address(router).balance, 0, "router refunds all excess");
        assertEq(manager.balanceOf(address(hook), 0), hook.accruedFees());
    }

    function _assertStreak(address user, uint256 count, uint256 last, uint256 effective, uint256 bps)
        internal
        view
    {
        (uint256 s, uint256 d, uint256 e, uint256 f) = hook.streakOf(poolId, user);
        assertEq(s, count);
        assertEq(d, last);
        assertEq(e, effective);
        assertEq(f, bps);
        assertEq(hook.feeFor(poolId, user), bps);
    }

    function _abs(int256 amount) internal pure returns (uint256) {
        return uint256(amount < 0 ? -amount : amount);
    }

    receive() external payable {}
}
