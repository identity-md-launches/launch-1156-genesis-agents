// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GENESISToken} from "../../src/GENESISToken.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "../vendor/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {LaunchHarness, LaunchFactoryStub, Trader, IERC20Like} from "./LaunchHarness.sol";

/// @notice The launch as the factory performs it, against a real Uniswap v4 PoolManager built at the
///         mainnet PoolManager address, with IMD at the mainnet IMD address: the token is deployed by
///         the factory, the swarm's 10% goes to the distributor and is claimable whole, 90% seeds the
///         pool single-sided at the price derived from the 2500 IMD opening cap, the remainder goes to
///         0xdead, and an ordinary trader buys and sells through the 1.25% fee pool. Every flow must
///         move exactly what it says. Both currency orders are exercised because mainnet's CREATE2
///         address decides which one the pool gets.
contract GENESISTokenLaunchTest is LaunchHarness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event Transfer(address indexed from, address indexed to, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Distribution
    // ---------------------------------------------------------------------------------------------

    function test_launchDistributesTheWholeSupply_tokenIsCurrency0() public {
        _launch(true);
        _assertDistribution();
    }

    function test_launchDistributesTheWholeSupply_tokenIsCurrency1() public {
        _launch(false);
        _assertDistribution();
    }

    function _assertDistribution() internal view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed during the launch");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept tokens back");
        assertEq(token.balanceOf(distributor), SWARM, "the swarm's share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "the pool manager holds something other than the seed");
        assertEq(token.balanceOf(DEAD), remainder, "the remainder arrived short");
        assertEq(seeded + remainder, POOL_SHARE, "seed plus remainder is not the requester's 90%");
        assertLe(seeded, POOL_SHARE, "the seed took more than poolBps allows");
        assertGe(seeded, POOL_SHARE * 999 / 1000, "the seed left more than 0.1% of the pool share unused");
        assertEq(SWARM + seeded + remainder, SUPPLY, "the launch flows do not add up to the supply");
    }

    function test_swarmShareLeavesTheFactoryWholeAndEmitsTransfer() public {
        factory = new LaunchFactoryStub(manager);
        token = GENESISToken(factory.deploy(type(GENESISToken).creationCode, bytes32(0)));
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(factory), distributor, SWARM);
        assertTrue(factory.move(IERC20Like(address(token)), distributor, SWARM));
        assertEq(token.balanceOf(distributor), SWARM);
        assertEq(token.balanceOf(address(factory)), SUPPLY - SWARM);
    }

    function test_factoryCannotSendTheSwarmShareTwice() public {
        _launch(true);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, address(factory), 0, SWARM));
        factory.move(IERC20Like(address(token)), distributor, SWARM);
    }

    /// @dev Claims drain the distributor to exactly zero, whatever the split, and one wei more reverts.
    function testFuzz_claimsDrainTheDistributorExactly(uint256[8] memory weights) public {
        _launch(false);
        uint256 total;
        for (uint256 i; i < 8; ++i) {
            weights[i] = bound(weights[i], 1, 1e18);
            total += weights[i];
        }
        uint256 paid;
        for (uint256 i; i < 8; ++i) {
            address claimant = address(uint160(0xC1A1 + i));
            uint256 claim = i == 7 ? SWARM - paid : FullMath.mulDiv(SWARM, weights[i], total);
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, claim), "a claim returned false");
            assertEq(token.balanceOf(claimant), claim, "a claim arrived short");
            paid += claim;
        }
        assertEq(paid, SWARM);
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");
        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, distributor, 0, 1));
        token.transfer(address(0xC1A1), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Price and pool parameters
    // ---------------------------------------------------------------------------------------------

    function test_openingPriceMatchesTheManifestProvenance() public {
        _launch(true);
        // Raw derived price, before snapping to a tick, against pool.initialPrice in launch.json
        // (GENESIS as currency0, IMD minor units per GENESIS minor unit).
        uint256 raw = _sqrt(FullMath.mulDiv(INITIAL_CAP_WEI, 1 << 192, SUPPLY));
        assertApproxEqRel(raw, MANIFEST_SQRT_PRICE, 1e9, "derived sqrt price disagrees with the manifest");
        // The pool opened at that price snapped down by less than one tick spacing (60 ticks = 0.6%).
        (uint160 sqrtP, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertLe(sqrtP, raw, "the pool opened above the derived price");
        assertGe(sqrtP, raw * 997 / 1000, "the pool opened more than a tick spacing below the derived price");
        assertEq(tick % TICK_SPACING, 0, "opening tick is not aligned to the tick spacing");
        assertEq(lpFee, POOL_FEE, "the pool does not carry the 1.25% LP fee");
        assertEq(protocolFee, 0);
        // Market cap at the opening price: supply * price = 2500 IMD, within the tick rounding.
        uint256 capWei = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, sqrtP, 1 << 96), sqrtP, 1 << 96);
        assertApproxEqRel(capWei, INITIAL_CAP_WEI, 0.006e18, "opening market cap is not 2500 IMD");
    }

    function test_openingPriceInvertsWhenTokenIsCurrency1() public {
        _launch(false);
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        // price = IMD per GENESIS is now 1/(sqrtP^2 / 2^192): the cap is supply / price.
        uint256 capWei = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sqrtP), 1 << 96, sqrtP);
        assertApproxEqRel(capWei, INITIAL_CAP_WEI, 0.006e18, "opening market cap is not 2500 IMD");
        // With the token as currency1 the seed range ends at the opening tick, so v4 counts it out of
        // range until the first buy moves the price down into it. The first buy activates it.
        assertEq(manager.getLiquidity(key.toId()), 0, "an upper-edge position should start out of range");
        Trader trader = new Trader(manager);
        imd.mint(address(trader), 1e15);
        trader.swap(key, _buyIsZeroForOne(), -int256(1e15));
        assertEq(manager.getLiquidity(key.toId()), seedParams.liquidity, "the first buy did not activate the seed");
        assertGt(token.balanceOf(address(trader)), 0);
    }

    function test_seedIsSingleSidedAndNeedsNoIMD() public {
        _launch(true);
        assertEq(imd.balanceOf(POOL_MANAGER), 0, "the seed pulled IMD");
        assertEq(imd.balanceOf(address(factory)), 0);
        assertEq(manager.getLiquidity(key.toId()), seedParams.liquidity, "seed liquidity is not active");
        assertGt(seedParams.liquidity, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps through the PoolManager, with the 1.25% fee
    // ---------------------------------------------------------------------------------------------

    function test_traderBuysAndSellsThroughTheFeePool_tokenIsCurrency0() public {
        _launch(true);
        _buyAndSellRoundTrip(1 ether);
    }

    function test_traderBuysAndSellsThroughTheFeePool_tokenIsCurrency1() public {
        _launch(false);
        _buyAndSellRoundTrip(1 ether);
    }

    function testFuzz_buySellRoundTrip(uint256 imdIn, bool tokenFirst) public {
        imdIn = bound(imdIn, 1e9, 20 ether);
        _launch(tokenFirst);
        _buyAndSellRoundTrip(imdIn);
    }

    function _buyAndSellRoundTrip(uint256 imdIn) internal {
        Trader trader = new Trader(manager);
        imd.mint(address(trader), imdIn);
        uint256 managerTokenBefore = token.balanceOf(POOL_MANAGER);
        uint256 quote = _quoteBuyNoSlippage(imdIn);

        // Buy: exact IMD in, GENESIS out. The token moves exactly what the manager says it does.
        BalanceDelta buy = trader.swap(key, _buyIsZeroForOne(), -int256(imdIn));
        assertEq(_imdDelta(buy), -int128(int256(imdIn)), "the buy did not take the exact IMD input");
        uint256 bought = uint256(uint128(_tokenDelta(buy)));
        assertGt(bought, 0, "a trader could not buy the token");
        assertEq(token.balanceOf(address(trader)), bought, "the trader received less than the swap delta");
        assertEq(managerTokenBefore - token.balanceOf(POOL_MANAGER), bought, "the manager released a different amount");
        assertEq(imd.balanceOf(POOL_MANAGER), imdIn, "the manager received a different IMD amount");
        assertEq(imd.balanceOf(address(trader)), 0);
        assertLe(bought, quote, "the buy beat the fee-adjusted spot price");
        assertGe(bought, quote * 98 / 100, "the buy slipped more than 2% against a 2250 IMD pool");

        // The 1.25% LP fee accrued, in IMD, to the seed position.
        BalanceDelta fees = factory.collectFees(seedParams);
        uint256 imdFee = uint256(uint128(_imdDelta(fees)));
        assertApproxEqRel(imdFee, imdIn * POOL_FEE / 1_000_000, 1e12, "buy fee is not 1.25% of the input");
        assertEq(_tokenDelta(fees), 0, "a buy accrued fees in GENESIS");
        assertEq(imd.balanceOf(address(factory)), imdFee);

        // Sell everything back: exact GENESIS in, IMD out.
        uint256 managerImdBefore = imd.balanceOf(POOL_MANAGER);
        BalanceDelta sell = trader.swap(key, !_buyIsZeroForOne(), -int256(bought));
        assertEq(_tokenDelta(sell), -int128(int256(bought)), "the sell did not take the exact GENESIS input");
        uint256 imdOut = uint256(uint128(_imdDelta(sell)));
        assertGt(imdOut, 0, "the sell returned nothing");
        assertLt(imdOut, imdIn, "a round trip through a 1.25% fee pool returned more than it put in");
        assertEq(token.balanceOf(address(trader)), 0, "a trader could not sell all of the token");
        assertEq(token.balanceOf(POOL_MANAGER), managerTokenBefore, "the manager did not get the tokens back whole");
        assertEq(imd.balanceOf(address(trader)), imdOut);
        assertEq(managerImdBefore - imd.balanceOf(POOL_MANAGER), imdOut);

        // The sell's fee accrued in GENESIS and is collectable: the position's share of the token.
        BalanceDelta sellFees = factory.collectFees(seedParams);
        uint256 tokenFee = uint256(uint128(_tokenDelta(sellFees)));
        assertApproxEqRel(tokenFee, bought * POOL_FEE / 1_000_000, 1e12, "sell fee is not 1.25% of the input");
        assertEq(token.balanceOf(address(factory)), tokenFee, "the collected fee did not arrive whole");
        assertEq(token.balanceOf(POOL_MANAGER), managerTokenBefore - tokenFee);

        // Supply conservation across the whole trip.
        assertEq(
            token.balanceOf(POOL_MANAGER) + token.balanceOf(address(factory)) + token.balanceOf(distributor)
                + token.balanceOf(DEAD) + token.balanceOf(address(trader)),
            SUPPLY,
            "tokens were created or lost on the way through the pool"
        );
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exactOutputBuyDeliversExactlyWhatWasAsked() public {
        _launch(true);
        Trader trader = new Trader(manager);
        imd.mint(address(trader), 10 ether);
        uint256 want = 123_456.789 ether;
        uint160 sqrtBefore = _sqrtPrice();
        BalanceDelta buy = trader.swap(key, _buyIsZeroForOne(), int256(want));
        assertEq(uint256(uint128(_tokenDelta(buy))), want);
        assertEq(token.balanceOf(address(trader)), want, "exact-output buy delivered a different amount");
        uint256 paid = uint256(uint128(-_imdDelta(buy)));
        assertEq(imd.balanceOf(POOL_MANAGER), paid);
        assertEq(imd.balanceOf(address(trader)), 10 ether - paid);
        // Paid at least the fee-inclusive opening price for the amount, and not absurdly more.
        uint256 quote = _quoteBuyNoSlippage(paid, sqrtBefore);
        assertLe(want, quote, "exact-output buy paid less than the fee-adjusted spot price");
        assertGe(want, quote * 98 / 100, "exact-output buy slipped more than 2%");
    }

    function test_tradersCanTransferBoughtTokensFreely() public {
        _launch(false);
        Trader trader = new Trader(manager);
        imd.mint(address(trader), 1 ether);
        trader.swap(key, _buyIsZeroForOne(), -1 ether);
        uint256 bought = token.balanceOf(address(trader));
        address friend = makeAddr("friend");
        assertTrue(trader.send(IERC20Like(address(token)), friend, bought));
        assertEq(token.balanceOf(friend), bought, "a holder's plain transfer arrived short");
        assertEq(token.balanceOf(address(trader)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths through the PoolManager
    // ---------------------------------------------------------------------------------------------

    function test_sellingMoreThanHeldRevertsInsideTheToken() public {
        _launch(true);
        Trader trader = new Trader(manager);
        imd.mint(address(trader), 1 ether);
        trader.swap(key, _buyIsZeroForOne(), -1 ether);
        uint256 held = token.balanceOf(address(trader));
        // The manager computes the delta, the trader tries to pay it, the token refuses: the unlock
        // bubbles the token's own error and nothing moves.
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, address(trader), held, held + 1)
        );
        trader.swap(key, !_buyIsZeroForOne(), -int256(held + 1));
        assertEq(token.balanceOf(address(trader)), held);
    }

    function test_strangerCannotSeedWithoutTokens() public {
        _launch(true);
        LaunchFactoryStub stranger = new LaunchFactoryStub(manager);
        LaunchFactoryStub.Seed memory s = seedParams;
        s.liquidity = 1e18;
        uint256 owed = uint256(uint128(-_tokenDelta(_previewSeed(s))));
        assertGt(owed, 0);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, address(stranger), 0, owed));
        stranger.seed(s);
        assertEq(manager.getLiquidity(key.toId()), seedParams.liquidity, "a failed seed changed liquidity");
    }

    function test_zeroAmountSwapIsRefusedByTheManager() public {
        _launch(false);
        Trader trader = new Trader(manager);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(key, _buyIsZeroForOne(), 0);
    }

    function test_poolManagerIsNotSpecialToTheToken() public {
        _launch(true);
        // The manager holds the seed, but a transfer it does not have the balance for still reverts,
        // and nobody can pull from it without an allowance: exactly like any other holder.
        uint256 held = token.balanceOf(POOL_MANAGER);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, POOL_MANAGER, held, held + 1));
        token.transfer(address(this), held + 1);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, POOL_MANAGER, address(this), 0, 1)
        );
        token.transferFrom(POOL_MANAGER, address(this), 1);
        assertEq(token.balanceOf(POOL_MANAGER), held);
    }

    /// @dev The delta a seed would produce, computed from a snapshot so the pool is untouched.
    function _previewSeed(LaunchFactoryStub.Seed memory s) internal returns (BalanceDelta delta) {
        uint256 snap = vm.snapshotState();
        LaunchFactoryStub funded = new LaunchFactoryStub(manager);
        uint256 fromDistributor = token.balanceOf(distributor);
        vm.prank(distributor);
        token.transfer(address(funded), fromDistributor);
        delta = funded.seed(s);
        vm.revertToState(snap);
    }
}
