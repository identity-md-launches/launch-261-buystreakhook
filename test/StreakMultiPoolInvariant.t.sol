// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TwoPoolFixture} from "./fixtures/TwoPoolFixture.sol";
import {BuyStreakHook} from "../src/BuyStreakHook.sol";
import {STREAK} from "../src/STREAK.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @dev Stores a calendar of actual qualifying trades, then counts adjacent occupied dates.
/// Pricing never uses the hook's views, events or claim balance as an expected value.
contract MultiPoolStreakHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 private constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant STREAK_TOPIC = keccak256("StreakUpdated(bytes32,address,uint256,uint256)");
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    BuyStreakHook public immutable hook;
    STREAK public immutable token;
    PoolKey[2] private pools;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) private purchased;
    mapping(uint256 => mapping(address => uint256)) private latest;
    uint256 public fees;
    uint256 public burned;
    int256 public netManagerETH;
    uint256 public successfulTrades;
    uint256 public rejectedTrades;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        BuyStreakHook hook_,
        PoolKey memory a,
        PoolKey memory b
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        token = STREAK(Currency.unwrap(a.currency1));
        pools[0] = a;
        pools[1] = b;
    }

    function trade(uint8 poolSeed, bool bob, uint8 modeSeed, uint96 size, uint8 identitySeed) external {
        uint256 pool = poolSeed % 2;
        address user = bob ? BOB : ALICE;
        uint256 mode = modeSeed % 4;
        uint256 identity = identitySeed % 6;
        uint256 amount = mode == 0 || mode == 3 ? bound(size, 1, 0.001 ether) : bound(size, 1, 50_000 ether);
        // Regularly exercise the two sides of the qualifying threshold, not just uniform sizes.
        if (mode == 0 && size % 3 != 0) amount = size % 3 == 1 ? 0.0005 ether - 1 : 0.0005 ether;
        bytes memory data = identity == 0
            ? abi.encode(user)
            : identity == 1
                ? abi.encode(bob ? ALICE : BOB)
                : identity == 2
                    ? bytes("")
                    : identity == 3
                        ? abi.encode(address(0))
                        : identity == 4 ? abi.encode(type(uint256).max) : abi.encode(user, uint256(0));
        _trade(pool, user, _params(mode, amount), data, identity == 0);
    }

    function advanceClock(uint8 choice) external {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 midnight = (now_ / 1 days + 1) * 1 days;
        uint256 next = choice % 4 == 0
            ? now_ + 1
            : choice % 4 == 1 ? midnight - 1 : choice % 4 == 2 ? midnight : midnight + 1 days;
        vm.warp(next);
    }

    function burn(bool bob) external {
        uint256 expectedBurn = fees - burned;
        uint256 deadBefore = DEAD.balance;
        uint256 managerBefore = address(manager).balance;
        address caller = bob ? BOB : ALICE;
        uint256 callerBefore = caller.balance;
        vm.prank(caller, caller);
        assertEq(hook.burnFees(), expectedBurn, "permissionless burn pays the independent ledger");
        assertEq(DEAD.balance - deadBefore, expectedBurn);
        assertEq(managerBefore - address(manager).balance, expectedBurn);
        assertEq(caller.balance, callerBefore);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.accruedFees(), 0);
        burned += expectedBurn;
    }

    function rejectPartialFill(uint8 poolSeed, bool bob, uint8 modeSeed) external {
        PoolKey memory key = pools[poolSeed % 2];
        address user = bob ? BOB : ALICE;
        uint256 mode = modeSeed % 4;
        (uint160 price,,,) = manager.getSlot0(key.toId());
        bytes32 beforeState = _fingerprint(key, user);
        SwapParams memory params = _params(mode, mode == 0 || mode == 3 ? 0.001 ether : 50_000 ether);
        params.sqrtPriceLimitX96 = mode < 2 ? price - 1 : price + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BuyStreakHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(user, user);
        router.swap{value: mode < 2 ? 0.1 ether : 0}(
            key, params, PoolSwapTest.TestSettings(false, false), abi.encode(user)
        );
        assertEq(_fingerprint(key, user), beforeState, "partial fill must roll back");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        ++rejectedTrades;
    }

    function expected(uint256 pool, address user)
        public
        view
        returns (uint256 count, uint256 day, uint256 effective, uint256 bps)
    {
        day = latest[pool][user];
        uint256 cursor = day;
        while (purchased[pool][user][cursor]) {
            ++count;
            if (cursor == 0) break;
            --cursor;
        }
        effective = block.timestamp / 1 days <= day + 1 ? count : 0;
        bps = effective >= 7 ? 30 : 100 - 10 * effective;
    }

    function _trade(uint256 pool, address user, SwapParams memory params, bytes memory data, bool valid)
        private
    {
        PoolKey memory key = pools[pool];
        (,,, uint256 bps) = expected(pool, user);
        if (!valid) bps = 100;
        vm.recordLogs();
        vm.prank(user, user);
        BalanceDelta net = router.swap{value: params.zeroForOne ? 0.1 ether : 0}(
            key, params, PoolSwapTest.TestSettings(false, false), data
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 ethBase = _accountSwap(key.toId(), params, net, logs, bps);
        uint256 today = vm.getBlockTimestamp() / 1 days;
        bool newDay = valid && params.zeroForOne && ethBase >= 0.0005 ether && !purchased[pool][user][today];
        if (newDay) {
            purchased[pool][user][today] = true;
            latest[pool][user] = today;
        }
        (uint256 count,,,) = expected(pool, user);
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != STREAK_TOPIC) continue;
            ++events;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(user))));
            assertEq(logs[i].data, abi.encode(today, count));
        }
        assertEq(events, newDay ? 1 : 0, "one event only for a newly occupied qualifying day");
        netManagerETH -= int256(net.amount0());
        ++successfulTrades;
    }

    function _accountSwap(
        PoolId id,
        SwapParams memory params,
        BalanceDelta net,
        Vm.Log[] memory logs,
        uint256 bps
    ) private returns (uint256 ethBase) {
        bool ethSpecified = params.zeroForOne == (params.amountSpecified < 0);
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_TOPIC
                    || logs[i].topics[1] != PoolId.unwrap(id)
            ) continue;
            (int128 ethDelta, int128 tokenDelta,,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            int256 base = ethSpecified ? params.amountSpecified : int256(ethDelta);
            ethBase = uint256(base < 0 ? -base : base);
            uint256 fee = ethBase * bps / 10_000;
            assertEq(int256(net.amount0()), int256(ethDelta) - int256(fee));
            assertEq(net.amount1(), tokenDelta);
            assertEq(ethSpecified ? net.amount0() : net.amount1(), params.amountSpecified);
            fees += fee;
            return ethBase;
        }
        revert("missing real PoolManager Swap event");
    }

    function _params(uint256 mode, uint256 amount) private pure returns (SwapParams memory) {
        return SwapParams(
            mode < 2,
            mode == 0 || mode == 2 ? -int256(amount) : int256(amount),
            mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _fingerprint(PoolKey memory key, address user) private view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 count, uint256 day, uint256 effective, uint256 bps) = hook.streakOf(key.toId(), user);
        bytes32 standing = keccak256(abi.encode(price, tick, count, day, effective, bps));
        return keccak256(
            abi.encode(
                standing,
                hook.accruedFees(),
                address(manager).balance,
                user.balance,
                token.balanceOf(address(manager)),
                token.balanceOf(user)
            )
        );
    }
}

contract StreakMultiPoolInvariantTest is TwoPoolFixture {
    MultiPoolStreakHandler private handler;
    uint256 private deadBefore;
    uint256 private managerBefore;

    function setUp() public override {
        super.setUp();
        assertEq(hook.burnFees(), FUNDING_FEES);
        deadBefore = DEAD.balance;
        managerBefore = address(manager).balance;
        handler = new MultiPoolStreakHandler(manager, router, hook, key, sibling);
        // Reach the floor deliberately before random interleaving. All other user/pool
        // combinations remain fresh, making both origin and cross-pool spoofing observable.
        for (uint256 i; i < 7; ++i) {
            vm.warp((START_DAY + i) * 1 days + 86_399);
            handler.trade(0, false, 0, 0.0005 ether, 0);
            handler.trade(1, true, 0, 0.0005 ether, 0);
        }
        assertEq(hook.feeFor(poolId, ALICE), 30);
        assertEq(hook.feeFor(siblingId, BOB), 30);
        assertEq(handler.successfulTrades(), 14);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MultiPoolStreakHandler.trade.selector;
        selectors[1] = MultiPoolStreakHandler.advanceClock.selector;
        selectors[2] = MultiPoolStreakHandler.burn.selector;
        selectors[3] = MultiPoolStreakHandler.rejectPartialFill.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyPoolAndIdentityMatchesPurchaseCalendar() public view {
        for (uint256 pool; pool < 2; ++pool) {
            PoolId id = pool == 0 ? poolId : siblingId;
            for (uint256 actor; actor < 2; ++actor) {
                address user = actor == 0 ? ALICE : BOB;
                (uint256 count, uint256 day, uint256 effective, uint256 bps) = handler.expected(pool, user);
                (uint256 actualCount, uint256 actualDay, uint256 actualEffective, uint256 actualBps) =
                    hook.streakOf(id, user);
                assertEq(actualCount, count, "raw streak counts occupied consecutive dates");
                assertEq(actualDay, day, "last date belongs to this pool and identity");
                assertEq(actualEffective, effective);
                assertEq(actualBps, bps);
                assertEq(hook.feeFor(id, user), bps);
            }
            (uint256 anonymousCount,,,) = hook.streakOf(id, address(0));
            (uint256 routerCount,,,) = hook.streakOf(id, address(router));
            assertEq(anonymousCount, 0);
            assertEq(routerCount, 0);
        }
    }

    function invariant_claimsBurnsAndManagerETHMatchIndependentLedger() public view {
        uint256 outstanding = handler.fees() - handler.burned();
        assertEq(manager.balanceOf(address(hook), 0), outstanding);
        assertEq(hook.accruedFees(), outstanding);
        assertEq(DEAD.balance - deadBefore, handler.burned());
        assertEq(
            int256(address(manager).balance),
            int256(managerBefore) + handler.netManagerETH() - int256(handler.burned())
        );
        assertGe(address(manager).balance, outstanding);
        _assertSettled();
    }

    function invariant_twoUsersAndTwoPoolsConserveFixedSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(factory)) + token.balanceOf(ALICE)
                + token.balanceOf(BOB),
            token.totalSupply()
        );
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(liquidityRouter)), 0);
    }
}
