// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StreakFixture} from "./fixtures/StreakFixture.sol";
import {TwoPoolFixture} from "./fixtures/TwoPoolFixture.sol";
import {BuyStreakHook} from "../src/BuyStreakHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract StreakAdversarialTest is StreakFixture {
    using StateLibrary for IPoolManager;

    function testFuzz_factoryFirstBuyAt235959AndSecondDayAtMidnight(uint32 daySeed, uint96 size) public {
        uint256 day = bound(daySeed, 0, 2_000_000);
        uint256 amount = bound(size, 0.0005 ether, 0.02 ether);
        vm.warp(day * 1 days + 86_399);
        assertEq(address(manager).balance, 0, "factory supplied no ETH");
        assertEq(manager.balanceOf(address(hook), 0), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(price, factory.SQRT_PRICE_X96(), "documented rehearsal price");

        vm.expectEmit(true, true, false, true, address(hook));
        emit BuyStreakHook.StreakUpdated(poolId, ALICE, day, 1);
        _checkedSwap(ALICE, _params(true, -int256(amount)), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, day, 1, 90);
        _checkedSwap(ALICE, _params(true, -int256(amount)), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 1, day, 1, 90);

        vm.warp((day + 1) * 1 days);
        vm.expectEmit(true, true, false, true, address(hook));
        emit BuyStreakHook.StreakUpdated(poolId, ALICE, day + 1, 2);
        _checkedSwap(ALICE, _params(true, -int256(amount)), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 2, day + 1, 2, 80);
    }

    function testFuzz_twoSubthresholdBuysCannotAggregateOrBridgeAMissedDay(uint96 shortfall) public {
        uint256 amount = 0.0005 ether - bound(shortfall, 1, 0.00025 ether - 1);
        _buy(ALICE, 0.001 ether);
        vm.warp((START_DAY + 1) * 1 days);
        assertGt(amount * 2, 0.0005 ether, "cumulative volume exceeds a qualifying buy");
        for (uint256 i; i < 2; ++i) {
            _checkedSwap(ALICE, _params(true, -int256(amount)), abi.encode(ALICE), 90);
            _assertStreak(ALICE, 1, START_DAY, 1, 90);
        }
        vm.warp((START_DAY + 2) * 1 days);
        _assertStreak(ALICE, 1, START_DAY, 0, 100);
        _checkedSwap(ALICE, _params(true, -0.0005 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY + 2, 1, 90);
    }

    function testFuzz_floorSurvivesSellsButNotAMissedBuyDay(uint8 countSeed) public {
        uint256 count = bound(countSeed, 7, 16);
        for (uint256 i; i < count; ++i) {
            vm.warp((START_DAY + i) * 1 days);
            _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), i >= 7 ? 30 : 100 - 10 * i);
        }
        _assertStreak(ALICE, count, START_DAY + count - 1, count, 30);
        // A sell on the following day is discounted but cannot keep the streak alive.
        vm.warp((START_DAY + count) * 1 days);
        _checkedSwap(ALICE, _params(false, -10_000 ether), abi.encode(ALICE), 30);
        _checkedSwap(ALICE, _params(false, 0.0001 ether), abi.encode(ALICE), 30);
        _assertStreak(ALICE, count, START_DAY + count - 1, count, 30);
        vm.warp((START_DAY + count + 1) * 1 days);
        _assertStreak(ALICE, count, START_DAY + count - 1, 0, 100);
        _checkedSwap(ALICE, _params(false, 0.0001 ether), abi.encode(ALICE), 100);
        _checkedSwap(ALICE, _params(true, -0.0005 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY + count + 1, 1, 90);
    }

    function testFuzz_partialFillOnNewDayRollsBackAllFourModes(uint96 sizeSeed) public {
        _buy(ALICE, 0.1 ether);
        vm.warp((START_DAY + 1) * 1 days);
        bytes32 beforeState = _stateFingerprint();
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 amount = mode == 0 || mode == 3
                ? bound(sizeSeed, 0.0005 ether, 0.01 ether)
                : bound(sizeSeed, 100_000 ether, 500_000 ether);
            SwapParams memory params = SwapParams(
                mode < 2,
                mode == 0 || mode == 2 ? -int256(amount) : int256(amount),
                mode < 2 ? price - 1 : price + 1
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(BuyStreakHook.PartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            _swap(key, ALICE, params, abi.encode(ALICE));
            assertEq(_stateFingerprint(), beforeState, "failed swap changed balances, price or standing");
            _assertSettled();
        }
        // Failure neither credits today nor prevents a genuine retry from crediting today.
        _checkedSwap(ALICE, _params(true, -0.0005 ether), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 2, START_DAY + 1, 2, 80);
    }

    function test_thresholdMinusOneNeverEmitsOrCountsEvenWhenRepeated() public {
        vm.recordLogs();
        _buy(ALICE, 0.0005 ether - 1);
        _buy(ALICE, 0.0005 ether - 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(hook) && logs[i].topics[0] == STREAK_TOPIC);
        }
        _assertStreak(ALICE, 0, 0, 0, 100);
        _checkedSwap(ALICE, _params(true, -0.0005 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function _stateFingerprint() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(poolId);
        (uint256 count, uint256 day, uint256 effective, uint256 fee) = hook.streakOf(poolId, ALICE);
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                count,
                day,
                effective,
                fee,
                hook.accruedFees(),
                address(manager).balance,
                ALICE.balance,
                token.balanceOf(address(manager)),
                token.balanceOf(ALICE)
            )
        );
    }
}

contract StreakPoolIdentityTest is TwoPoolFixture {
    function test_sameTokenPairHasIndependentStandingAndBurnsAllPoolClaims() public {
        for (uint256 i; i < 7; ++i) {
            vm.warp((START_DAY + i) * 1 days);
            _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), 100 - i * 10);
            if (i >= 4) {
                _checkedSwap(sibling, BOB, _params(true, -0.001 ether), abi.encode(BOB), 100 - (i - 4) * 10);
            }
        }
        assertEq(hook.feeFor(poolId, ALICE), 30);
        assertEq(hook.feeFor(siblingId, ALICE), 100);
        assertEq(hook.feeFor(poolId, BOB), 100);
        assertEq(hook.feeFor(siblingId, BOB), 70);
        _checkedSwap(sibling, ALICE, _params(true, -0.001 ether), abi.encode(ALICE), 100);
        _checkedSwap(BOB, _params(true, -0.001 ether), abi.encode(BOB), 100);
        _assertStreak(ALICE, 7, START_DAY + 6, 7, 30);
        _assertStreak(BOB, 1, START_DAY + 6, 1, 90);
        (uint256 count, uint256 day,,) = hook.streakOf(siblingId, ALICE);
        assertEq(count, 1);
        assertEq(day, START_DAY + 6);
        (count, day,,) = hook.streakOf(siblingId, BOB);
        assertEq(count, 3);
        assertEq(day, START_DAY + 6);

        // This total comes from the trade schedule, not accruedFees().
        uint256 expected = FUNDING_FEES + 0.001 ether * (490 + 270 + 200) / 10_000;
        assertEq(manager.balanceOf(address(hook), 0), expected);
        uint256 deadBefore = DEAD.balance;
        uint256 managerBefore = address(manager).balance;
        uint256 callerBefore = BOB.balance;
        vm.prank(BOB);
        assertEq(hook.burnFees(), expected);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.accruedFees(), 0);
        assertEq(DEAD.balance - deadBefore, expected);
        assertEq(managerBefore - address(manager).balance, expected);
        assertEq(BOB.balance, callerBefore);
        assertEq(hook.burnFees(), 0);
        _assertSettled();
    }

    function testFuzz_borrowedIdentityGetsFullFeeInEveryModeAndPool(uint8 tierSeed, uint96 size) public {
        uint256 tier = bound(tierSeed, 1, 9);
        for (uint256 i; i < tier; ++i) {
            vm.warp((START_DAY + i) * 1 days);
            _buy(ALICE, 0.001 ether);
            _checkedSwap(
                sibling, ALICE, _params(true, -0.001 ether), abi.encode(ALICE), i >= 7 ? 30 : 100 - i * 10
            );
        }
        // Both claimants have standing. Invalid data must not fall back to the origin's discount either.
        _buy(BOB, 0.001 ether);
        _checkedSwap(sibling, BOB, _params(true, -0.001 ether), abi.encode(BOB), 100);
        vm.warp((START_DAY + tier) * 1 days);
        for (uint256 mode; mode < 4; ++mode) {
            uint256 amount = mode == 0 || mode == 3
                ? bound(size, 0.0005 ether, 0.001 ether)
                : bound(size, 50_000 ether, 100_000 ether);
            SwapParams memory params =
                _params(mode < 2, mode == 0 || mode == 2 ? -int256(amount) : int256(amount));
            _checkedSwap(BOB, params, abi.encode(ALICE), 100);
            _checkedSwap(sibling, BOB, params, abi.encode(ALICE), 100);
            _assertStreak(ALICE, tier, START_DAY + tier - 1, tier, tier >= 7 ? 30 : 100 - tier * 10);
            _assertStreak(BOB, 1, START_DAY + tier - 1, 1, 90);
            (uint256 aliceCount, uint256 aliceDay,,) = hook.streakOf(siblingId, ALICE);
            (uint256 bobCount, uint256 bobDay,,) = hook.streakOf(siblingId, BOB);
            assertEq(aliceCount, tier);
            assertEq(bobCount, 1);
            assertEq(aliceDay, START_DAY + tier - 1);
            assertEq(bobDay, START_DAY + tier - 1);
        }
    }
}
