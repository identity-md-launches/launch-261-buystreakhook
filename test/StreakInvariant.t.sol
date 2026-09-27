// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StreakFixture} from "./fixtures/StreakFixture.sol";
import {BuyStreakHook} from "../src/BuyStreakHook.sol";
import {STREAK} from "../src/STREAK.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev An independent state machine and fee ledger; no hook view feeds its expected pricing.
contract StreakHandler is Test {
    address internal constant USER = address(0xa11ce);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    BuyStreakHook public immutable hook;
    PoolKey internal key;
    uint256 public minted;
    uint256 public burned;
    uint256 public modelStreak;
    uint256 public modelDay;
    uint256 public swaps;

    constructor(IPoolManager manager_, PoolSwapTest router_, BuyStreakHook hook_, PoolKey memory key_) {
        manager = manager_;
        router = router_;
        hook = hook_;
        key = key_;
        minted = 0.01 ether; // Fee on the anonymous 1 ETH funding buy in the fixture.
    }

    function trade(uint8 modeSeed, uint96 size, uint8 daysElapsed, bool identity) external {
        vm.warp(vm.getBlockTimestamp() + bound(daysElapsed, 0, 3) * 1 days);
        uint256 mode = bound(modeSeed, 0, 3);
        bool buy = mode < 2;
        bool exactIn = mode == 0 || mode == 2;
        bool ethSpecified = mode == 0 || mode == 3;
        uint256 amount = ethSpecified ? bound(size, 1, 0.002 ether) : bound(size, 1, 100_000 ether);
        SwapParams memory params = SwapParams(
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 bps = identity ? modelFee() : 100;
        vm.recordLogs();
        vm.prank(USER, USER);
        BalanceDelta net = router.swap{value: buy ? 1 ether : 0}(
            key,
            params,
            PoolSwapTest.TestSettings(false, false),
            identity ? abi.encode(USER) : abi.encode(address(0xb0b))
        );
        uint256 ethBase = amount;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 ethDelta, int128 tokenDelta,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                if (!ethSpecified) ethBase = uint256(ethDelta < 0 ? -int256(ethDelta) : int256(ethDelta));
                uint256 fee = ethBase * bps / 10_000;
                assertEq(int256(net.amount0()), int256(ethDelta) - int256(fee));
                assertEq(net.amount1(), tokenDelta);
                minted += fee;
                found = true;
                break;
            }
        }
        assertTrue(found);
        assertEq(ethSpecified ? net.amount0() : net.amount1(), params.amountSpecified);
        if (buy && identity && ethBase >= 0.0005 ether) {
            uint256 today = vm.getBlockTimestamp() / 1 days;
            if (modelStreak == 0 || modelDay != today) {
                modelStreak = modelStreak != 0 && today == modelDay + 1 ? modelStreak + 1 : 1;
                modelDay = today;
            }
        }
        ++swaps;
    }

    function burn() external {
        uint256 expected = minted - burned;
        uint256 beforeDead = DEAD.balance;
        assertEq(hook.burnFees(), expected);
        assertEq(DEAD.balance - beforeDead, expected);
        burned += expected;
    }

    function modelFee() public view returns (uint256) {
        uint256 effective = block.timestamp / 1 days <= modelDay + 1 ? modelStreak : 0;
        return effective >= 7 ? 30 : 100 - effective * 10;
    }
}

contract StreakInvariantTest is StreakFixture {
    StreakHandler internal handler;
    uint256 internal deadAtStart;

    function setUp() public override {
        super.setUp();
        _checkedSwap(ALICE, _params(true, -1 ether), "", 100);
        handler = new StreakHandler(manager, router, hook, key);
        deadAtStart = DEAD.balance;
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = StreakHandler.trade.selector;
        selectors[1] = StreakHandler.burn.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_claimsMatchIndependentFeeLedgerAndBurnDestination() public view {
        assertEq(hook.accruedFees(), handler.minted() - handler.burned());
        assertEq(manager.balanceOf(address(hook), 0), handler.minted() - handler.burned());
        assertEq(DEAD.balance - deadAtStart, handler.burned());
        assertGe(address(manager).balance, hook.accruedFees());
        _assertSettled();
    }

    function invariant_streakAndPricingMatchIndependentCalendar() public view {
        (uint256 count, uint256 day, uint256 effective, uint256 fee) = hook.streakOf(poolId, ALICE);
        assertEq(count, handler.modelStreak());
        assertEq(day, handler.modelDay());
        assertEq(effective, block.timestamp / 1 days <= day + 1 ? count : 0);
        assertEq(fee, handler.modelFee());
        (uint256 bobCount,,,) = hook.streakOf(poolId, BOB);
        assertEq(bobCount, 0, "mismatched data never credits someone else");
    }

    function invariant_fixedTokenSupplyAndConservation() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(ALICE) + token.balanceOf(address(factory)),
            token.totalSupply()
        );
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }
}
