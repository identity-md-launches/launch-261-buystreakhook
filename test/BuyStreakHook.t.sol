// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StreakFixture} from "./fixtures/StreakFixture.sol";
import {HookMiner} from "./fixtures/HookMiner.sol";
import {STREAK} from "../src/STREAK.sol";
import {BuyStreakHook} from "../src/BuyStreakHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

contract BuyStreakHookTest is StreakFixture {
    using StateLibrary for IPoolManager;

    function test_launchFactoryFirstBuyWithNoETH() public {
        assertEq(factory.mintedToFactory(), 1_000_000_000 ether);
        assertEq(factory.seededTokens() + token.balanceOf(address(factory)), token.totalSupply());
        assertEq(address(manager).balance, 0, "no prefunding");
        assertEq(address(factory).balance, 0);
        assertEq(token.balanceOf(address(manager)), factory.seededTokens());
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(price, factory.SQRT_PRICE_X96());
        (BalanceDelta delta, uint256 fee) =
            _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), 100);
        assertGt(delta.amount1(), 0);
        assertEq(fee, 0.00001 ether);
        assertEq(address(manager).balance, 0.001 ether);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_exactOutBuyChargesUnspecifiedETHAndPreservesTokenOutput() public {
        (BalanceDelta delta,) = _checkedSwap(ALICE, _params(true, 100_000 ether), abi.encode(ALICE), 100);
        assertEq(delta.amount1(), 100_000 ether);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_exactInSellChargesUnspecifiedETH() public {
        _buy(ALICE, 0.1 ether);
        _checkedSwap(ALICE, _params(false, -100_000 ether), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_exactOutSellChargesSpecifiedETHAndPreservesETHOutput() public {
        _buy(ALICE, 0.1 ether);
        (BalanceDelta delta, uint256 fee) =
            _checkedSwap(ALICE, _params(false, 0.001 ether), abi.encode(ALICE), 90);
        assertEq(delta.amount0(), 0.001 ether);
        assertEq(fee, 0.000009 ether);
    }

    function test_dustAllFourModesRoundsToZero() public {
        _buy(ALICE, 0.1 ether);
        (, uint256 fee) = _checkedSwap(ALICE, _params(true, -1), abi.encode(ALICE), 90);
        assertEq(fee, 0);
        (, fee) = _checkedSwap(ALICE, _params(true, 1), abi.encode(ALICE), 90);
        assertEq(fee, 0);
        (, fee) = _checkedSwap(ALICE, _params(false, -1), abi.encode(ALICE), 90);
        assertEq(fee, 0);
        (, fee) = _checkedSwap(ALICE, _params(false, 1), abi.encode(ALICE), 90);
        assertEq(fee, 0);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_UTCBoundaryAndSameDayEventDeduplication() public {
        vm.warp((START_DAY + 1) * 1 days - 1);
        vm.expectEmit(true, true, false, true, address(hook));
        emit BuyStreakHook.StreakUpdated(poolId, ALICE, START_DAY, 1);
        _buy(ALICE, 0.001 ether);
        vm.recordLogs();
        _buy(ALICE, 0.001 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(hook) && logs[i].topics[0] == STREAK_TOPIC);
        }
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
        vm.warp((START_DAY + 1) * 1 days);
        _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 2, START_DAY + 1, 2, 80);
    }

    function test_missedDayResetsBeforePricing() public {
        _buy(ALICE, 0.001 ether);
        vm.warp((START_DAY + 1) * 1 days + 1 days - 1);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
        vm.warp((START_DAY + 2) * 1 days);
        _assertStreak(ALICE, 1, START_DAY, 0, 100);
        _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY + 2, 1, 90);
    }

    function test_feeFloorAndPricingBeforeStreakUpdate() public {
        for (uint256 i; i < 12; ++i) {
            vm.warp((START_DAY + i) * 1 days);
            uint256 bps = i >= 7 ? 30 : 100 - 10 * i;
            _checkedSwap(ALICE, _params(true, -0.001 ether), abi.encode(ALICE), bps);
            uint256 next = i >= 6 ? 30 : 90 - 10 * i;
            _assertStreak(ALICE, i + 1, START_DAY + i, i + 1, next);
        }
        _checkedSwap(ALICE, _params(false, 0.0005 ether), abi.encode(ALICE), 30);
    }

    function test_thresholdUsesSpecifiedETHIncludingFee() public {
        _buy(ALICE, 0.0005 ether - 1);
        _assertStreak(ALICE, 0, 0, 0, 100);
        _buy(ALICE, 0.0005 ether);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
        vm.warp((START_DAY + 1) * 1 days);
        _buy(ALICE, 0.0005 ether - 1);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_exactOutBuyThresholdUsesPoolETHBeforeFee() public {
        // 1 token is below the threshold even with the hook fee; 100,000 exceeds it.
        _checkedSwap(ALICE, _params(true, 1 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 0, 0, 0, 100);
        _checkedSwap(ALICE, _params(true, 100_000 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_exactOutBuyFeeCannotPushSubthresholdTradeIntoQualification() public {
        (BalanceDelta delta, uint256 fee) =
            _checkedSwap(ALICE, _params(true, 49_600 ether), abi.encode(ALICE), 100);
        uint256 totalPaid = uint256(-int256(delta.amount0()));
        assertGe(totalPaid, 0.0005 ether);
        assertLt(totalPaid - fee, 0.0005 ether, "threshold is the pool leg, excluding this fee");
        _assertStreak(ALICE, 0, 0, 0, 100);
    }

    function test_firstDustBuyNeedsNoFeeOrETHPrefunding() public {
        assertEq(address(manager).balance, 0);
        (, uint256 fee) = _checkedSwap(ALICE, _params(true, -1), abi.encode(ALICE), 100);
        assertEq(fee, 0);
        _assertStreak(ALICE, 0, 0, 0, 100);
    }

    function test_sellsNeverExtendOrStartStreak() public {
        _buy(ALICE, 0.1 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 1_000_000 ether);
        _checkedSwap(BOB, _params(false, 0.001 ether), abi.encode(BOB), 100);
        _assertStreak(BOB, 0, 0, 0, 100);
        vm.warp((START_DAY + 1) * 1 days);
        _checkedSwap(ALICE, _params(false, -100_000 ether), abi.encode(ALICE), 90);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
        vm.warp((START_DAY + 2) * 1 days);
        _checkedSwap(ALICE, _params(false, 0.001 ether), abi.encode(ALICE), 100);
        _assertStreak(ALICE, 1, START_DAY, 0, 100);
    }

    function test_dayZeroFirstBuyAndBoundaryDoNotUnderflow() public {
        vm.warp(0);
        _assertStreak(ALICE, 0, 0, 0, 100);
        _buy(ALICE, 0.001 ether);
        _assertStreak(ALICE, 1, 0, 1, 90);
        _buy(ALICE, 0.001 ether);
        _assertStreak(ALICE, 1, 0, 1, 90);
        vm.warp(1 days);
        _buy(ALICE, 0.001 ether);
        _assertStreak(ALICE, 2, 1, 2, 80);
    }

    function test_invalidIdentityAlwaysFullFeeAndNoCredit() public {
        _buy(ALICE, 0.001 ether);
        vm.warp((START_DAY + 1) * 1 days);
        bytes[7] memory invalid = [
            bytes(""),
            abi.encode(address(0)),
            abi.encode(ALICE),
            abi.encode(address(router)),
            abi.encodePacked(BOB),
            abi.encode(BOB, uint256(0)),
            abi.encode(type(uint256).max)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            _checkedSwap(BOB, _params(true, -0.001 ether), invalid[i], 100);
            _assertStreak(BOB, 0, 0, 0, 100);
        }
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
        (uint256 routerStreak,,,) = hook.streakOf(poolId, address(router));
        assertEq(routerStreak, 0);
    }

    function test_missingIdentityCannotUseOwnExistingDiscount() public {
        _buy(ALICE, 0.001 ether);
        vm.warp((START_DAY + 1) * 1 days);
        _checkedSwap(ALICE, _params(true, -0.001 ether), "", 100);
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_poolIsolation() public {
        _buy(ALICE, 0.001 ether);
        vm.warp((START_DAY + 1) * 1 days);
        _buy(ALICE, 0.001 ether);
        STREAK second = new STREAK();
        PoolKey memory other =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(second)), 3000, 60, IHooks(hook));
        manager.initialize(other, uint160(1 << 96));
        second.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 10 ether}(
            other, ModifyLiquidityParams(-600, 600, 100 ether, 0), ""
        );
        uint256 claimsBefore = hook.accruedFees();
        _swap(other, ALICE, _params(true, -0.001 ether), abi.encode(ALICE));
        assertEq(hook.accruedFees() - claimsBefore, 0.00001 ether);
        _assertStreak(ALICE, 2, START_DAY + 1, 2, 80);
        (uint256 s, uint256 d, uint256 e, uint256 f) = hook.streakOf(other.toId(), ALICE);
        assertEq(s, 1);
        assertEq(d, START_DAY + 1);
        assertEq(e, 1);
        assertEq(f, 90);
    }

    function test_nonETHPoolHasZeroDeltasAndNoEffects() public {
        STREAK a = new STREAK();
        STREAK b = new STREAK();
        (STREAK t0, STREAK t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory other =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        manager.initialize(other, uint160(1 << 96));
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 100_000 ether, 0), "");
        t0.transfer(ALICE, 100 ether);
        t1.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            vm.recordLogs();
            BalanceDelta delta = _swap(
                other,
                ALICE,
                _params(i < 2, i % 2 == 0 ? -int256(1 ether) : int256(1 ether)),
                abi.encode(ALICE)
            );
            BalanceDelta core = _coreDelta(vm.getRecordedLogs(), other.toId());
            assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(core));
        }
        assertEq(hook.accruedFees(), 0);
        (uint256 s,,,) = hook.streakOf(other.toId(), ALICE);
        assertEq(s, 0);
        vm.prank(address(manager));
        (, BeforeSwapDelta beforeDelta, uint24 lpFee) =
            hook.beforeSwap(ALICE, other, _params(true, -1 ether), "");
        assertEq(BeforeSwapDelta.unwrap(beforeDelta), 0);
        assertEq(lpFee, 0);
        vm.prank(address(manager));
        (, int128 afterDelta) =
            hook.afterSwap(ALICE, other, _params(true, -1 ether), BalanceDelta.wrap(0), "");
        assertEq(afterDelta, 0);
        _assertSettled();
    }

    function test_partialFillAllFourModesRevertAndRollback() public {
        _buy(ALICE, 0.1 ether);
        uint256 claimsBefore = hook.accruedFees();
        uint256 ethBefore = address(manager).balance;
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        for (uint256 i; i < 4; ++i) {
            bool buy = i < 2;
            int256 amount = i == 0
                ? -int256(1 ether)
                : i == 1 ? int256(1_000_000 ether) : i == 2 ? -int256(1_000_000 ether) : int256(0.01 ether);
            SwapParams memory params = SwapParams(buy, amount, buy ? price - 1 : price + 1);
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
            assertEq(hook.accruedFees(), claimsBefore);
            assertEq(address(manager).balance, ethBefore);
            (uint160 unchanged,,,) = IPoolManager(address(manager)).getSlot0(poolId);
            assertEq(unchanged, price);
        }
        _assertStreak(ALICE, 1, START_DAY, 1, 90);
    }

    function test_burnAllFeesOnlyToDeadAndRepeatedBurnIsEmpty() public {
        _buy(ALICE, 0.1 ether);
        _checkedSwap(ALICE, _params(false, 0.001 ether), abi.encode(ALICE), 90);
        uint256 amount = hook.accruedFees();
        uint256 beforeDead = DEAD.balance;
        uint256 beforeCaller = BOB.balance;
        uint256 beforeManager = address(manager).balance;
        vm.expectEmit(false, false, false, true, address(hook));
        emit BuyStreakHook.FeesBurned(amount);
        vm.prank(BOB);
        assertEq(hook.burnFees(), amount);
        assertEq(hook.accruedFees(), 0);
        assertEq(DEAD.balance - beforeDead, amount);
        assertEq(BOB.balance, beforeCaller);
        assertEq(beforeManager - address(manager).balance, amount);
        assertEq(hook.burnFees(), 0);
        _assertSettled();
        _buy(BOB, 0.001 ether);
        assertEq(hook.burnFees(), 0.00001 ether);
    }

    function test_failedBurnRollsBackClaimsAndCanRetry() public {
        _buy(ALICE, 0.001 ether);
        uint256 amount = hook.accruedFees();
        // Test-only rejection at the fixed destination; production dEaD has no runtime code.
        vm.etch(DEAD, hex"60006000fd");
        vm.expectRevert();
        hook.burnFees();
        assertEq(hook.accruedFees(), amount);
        vm.etch(DEAD, "");
        assertEq(hook.burnFees(), amount);
        assertEq(hook.accruedFees(), 0);
        _assertSettled();
    }

    function test_donatedClaimsAreAlsoBurnedAndCannotBeStolen() public {
        BurnProbe probe = new BurnProbe(manager, hook);
        probe.donate{value: 1 ether}();
        assertEq(hook.accruedFees(), 1 ether);
        vm.expectRevert();
        probe.steal();
        uint256 beforeDead = DEAD.balance;
        hook.burnFees();
        assertEq(DEAD.balance - beforeDead, 1 ether);
        assertEq(hook.accruedFees(), 0);
    }

    function test_burnInsideExistingUnlockRevertsWithoutAccountingChange() public {
        _buy(ALICE, 0.001 ether);
        BurnProbe probe = new BurnProbe(manager, hook);
        uint256 amount = hook.accruedFees();
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        probe.nestedBurn();
        assertEq(hook.accruedFees(), amount);
        assertEq(hook.burnFees(), amount);
    }

    function test_burnClearsClaimsBeforeRecipientCanReenter() public {
        _buy(ALICE, 0.001 ether);
        uint256 amount = hook.accruedFees();
        ReentrantBurnReceiver recipient = new ReentrantBurnReceiver(hook);
        vm.etch(DEAD, address(recipient).code);
        assertEq(hook.burnFees(), amount);
        assertEq(ReentrantBurnReceiver(payable(DEAD)).observed(), amount);
        assertEq(hook.accruedFees(), 0);
        _assertSettled();
    }

    function test_failedRouterSettlementRollsBackSwapFeeAndStreak() public {
        // A first buy executes both callbacks but the router cannot pay its ETH debt.
        vm.expectRevert();
        vm.prank(ALICE, ALICE);
        router.swap(key, _params(true, -0.001 ether), _routerSettings(), abi.encode(ALICE));
        assertEq(hook.accruedFees(), 0);
        assertEq(address(manager).balance, 0);
        _assertStreak(ALICE, 0, 0, 0, 100);
        _buy(ALICE, 0.1 ether);
        uint256 claims = hook.accruedFees();
        uint256 managerETH = address(manager).balance;
        // Bob has no tokens, so transferFrom fails after the fee was minted in afterSwap.
        vm.expectRevert();
        _swap(key, BOB, _params(false, -10_000 ether), abi.encode(BOB));
        assertEq(hook.accruedFees(), claims);
        assertEq(address(manager).balance, managerETH);
        _assertStreak(BOB, 0, 0, 0, 100);
        _assertSettled();
    }

    function test_relayedWalletIdentityDoesNotEarnDiscount() public {
        // Model a smart wallet calling the router while a distinct bundler is tx.origin.
        address wallet = address(0xCAFE);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet, BOB);
        router.swap{value: 0.001 ether}(
            key, _params(true, -0.001 ether), _routerSettings(), abi.encode(wallet)
        );
        (uint256 walletStreak,,,) = hook.streakOf(poolId, wallet);
        assertEq(walletStreak, 0);
        _assertStreak(BOB, 0, 0, 0, 100);
        assertEq(hook.accruedFees(), 0.00001 ether);
    }

    function test_permissionsExactly00CCAndInvalidConstructorRejected() public {
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & 0x3fff, 0x00cc);
        bytes32 hash = keccak256(abi.encodePacked(type(BuyStreakHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted = HookMiner.predict(address(this), salt, hash);
        while (uint160(predicted) & 0x3fff == 0x00cc) {
            salt = bytes32(uint256(salt) + 1);
            predicted = HookMiner.predict(address(this), salt, hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new BuyStreakHook{salt: salt}(manager);
        vm.expectRevert(BuyStreakHook.InvalidPoolManager.selector);
        new BuyStreakHook(IPoolManager(address(0)));
    }

    function test_everyCallbackRejectsNonManagerAndUnlockNeedsPendingBurn() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[11] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (ALICE, key, uint160(1 << 96))),
            abi.encodeCall(IHooks.afterInitialize, (ALICE, key, uint160(1 << 96), int24(0))),
            abi.encodeCall(IHooks.beforeAddLiquidity, (ALICE, key, lp, bytes(""))),
            abi.encodeCall(IHooks.afterAddLiquidity, (ALICE, key, lp, zero, zero, bytes(""))),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (ALICE, key, lp, bytes(""))),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (ALICE, key, lp, zero, zero, bytes(""))),
            abi.encodeCall(IHooks.beforeSwap, (ALICE, key, _params(true, -1 ether), abi.encode(ALICE))),
            abi.encodeCall(IHooks.afterSwap, (ALICE, key, _params(true, -1 ether), zero, abi.encode(ALICE))),
            abi.encodeCall(IHooks.beforeDonate, (ALICE, key, uint256(0), uint256(0), bytes(""))),
            abi.encodeCall(IHooks.afterDonate, (ALICE, key, uint256(0), uint256(0), bytes(""))),
            abi.encodeCall(IUnlockCallback.unlockCallback, (bytes("")))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(BuyStreakHook.NotPoolManager.selector));
        }
        vm.prank(address(manager));
        vm.expectRevert(BuyStreakHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(uint256(1 ether), BOB));
    }

    function test_runtimeHasNoEscapeOpcodesOrAdminSurface() public {
        bytes memory code = address(hook).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
        (bool ok,) = address(hook).call(abi.encodeWithSignature("sweep(address)", BOB));
        assertFalse(ok);
        (ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    function testFuzz_fourModesConserveFunds(uint96 size, uint8 mode, uint8 daysEarned) public {
        uint256 earned = bound(daysEarned, 0, 9);
        // Funding buy is anonymous, giving tokens without changing standing.
        _checkedSwap(ALICE, _params(true, -1 ether), "", 100);
        for (uint256 i; i < earned; ++i) {
            vm.warp((START_DAY + i) * 1 days);
            _buy(ALICE, 0.001 ether);
        }
        mode = uint8(bound(mode, 0, 3));
        uint256 bps = earned >= 7 ? 30 : 100 - earned * 10;
        uint256 amount = mode == 0 || mode == 3 ? bound(size, 1, 0.01 ether) : bound(size, 1, 100_000 ether);
        SwapParams memory params =
            _params(mode < 2, mode == 0 || mode == 2 ? -int256(amount) : int256(amount));
        _checkedSwap(ALICE, params, abi.encode(ALICE), bps);
    }
}

contract BurnProbe is IUnlockCallback {
    IPoolManager immutable manager;
    BuyStreakHook immutable hook;

    constructor(IPoolManager manager_, BuyStreakHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function donate() external payable {
        manager.unlock(abi.encode(uint256(0), msg.value));
    }

    function steal() external {
        manager.unlock(abi.encode(uint256(1), uint256(1)));
    }

    function nestedBurn() external {
        manager.unlock(abi.encode(uint256(2), uint256(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint256 mode, uint256 amount) = abi.decode(data, (uint256, uint256));
        if (mode == 0) {
            manager.sync(Currency.wrap(address(0)));
            manager.settle{value: amount}();
            manager.mint(address(this), 0, amount);
            manager.transfer(address(hook), 0, amount);
        } else if (mode == 1) {
            manager.burn(address(hook), 0, amount);
            manager.take(Currency.wrap(address(0)), address(this), amount);
        } else {
            hook.burnFees();
        }
        return "";
    }
    receive() external payable {}
}

contract ReentrantBurnReceiver {
    BuyStreakHook immutable hook;
    uint256 public observed;

    constructor(BuyStreakHook hook_) {
        hook = hook_;
    }

    receive() external payable {
        require(hook.accruedFees() == 0, "claims must be zero before payout");
        require(hook.burnFees() == 0, "cannot burn twice");
        (bool ok,) = address(hook).call(abi.encodeCall(IUnlockCallback.unlockCallback, (bytes(""))));
        require(!ok, "cannot forge callback");
        observed += msg.value;
    }
}
