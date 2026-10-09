// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GENESISToken} from "../../src/GENESISToken.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "../vendor/v4-core/src/libraries/FullMath.sol";
import {LaunchHarness, LaunchFactoryStub, Trader, PairTokenStub, IERC20Like} from "./LaunchHarness.sol";

/// @notice Random buys, sells, holder-to-holder transfers and fee collections against the seeded pool.
contract PoolHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public manager;
    GENESISToken public token;
    PairTokenStub public imd;
    LaunchFactoryStub public factory;
    PoolKey public key;
    LaunchFactoryStub.Seed public seedParams;
    bool public tokenIsCurrency0;
    Trader[] public traders;

    uint256 public imdMinted;
    uint256 public tokensBought;
    uint256 public tokensSold;
    uint256 public tokenFeesCollected;
    uint256 public calls;

    constructor(
        IPoolManager manager_,
        GENESISToken token_,
        PairTokenStub imd_,
        LaunchFactoryStub factory_,
        PoolKey memory key_,
        LaunchFactoryStub.Seed memory seed_,
        bool tokenIsCurrency0_
    ) {
        manager = manager_;
        token = token_;
        imd = imd_;
        factory = factory_;
        key = key_;
        seedParams = seed_;
        tokenIsCurrency0 = tokenIsCurrency0_;
        for (uint256 i; i < 3; ++i) {
            traders.push(new Trader(manager_));
        }
    }

    function buy(uint256 traderSeed, uint256 imdIn) external {
        Trader trader = traders[traderSeed % traders.length];
        imdIn = bound(imdIn, 1e6, 50 ether);
        imd.mint(address(trader), imdIn);
        imdMinted += imdIn;
        BalanceDelta delta = trader.swap(key, !tokenIsCurrency0, -int256(imdIn));
        tokensBought += uint256(uint128(tokenIsCurrency0 ? delta.amount0() : delta.amount1()));
        ++calls;
    }

    function buyExactOut(uint256 traderSeed, uint256 tokensOut) external {
        Trader trader = traders[traderSeed % traders.length];
        tokensOut = bound(tokensOut, 1e9, 10_000_000 ether);
        // Fund the trader from the pool's current price, not the opening one: a run of buys can push the
        // price many times above the opening, and a handler call inside its own bounds must never revert.
        // Twice the fee-inclusive no-slippage cost covers the slippage of a 10M buy against a seed of 900M,
        // and the extra 1 IMD covers rounding at tiny sizes.
        uint256 budget = _quoteExactOutNoSlippage(tokensOut) * 2 + 1 ether;
        imd.mint(address(trader), budget);
        imdMinted += budget;
        trader.swap(key, !tokenIsCurrency0, int256(tokensOut));
        tokensBought += tokensOut;
        ++calls;
    }

    function sell(uint256 traderSeed, uint256 fractionBps) external {
        Trader trader = traders[traderSeed % traders.length];
        uint256 held = token.balanceOf(address(trader));
        if (held == 0) return;
        uint256 amount = held * bound(fractionBps, 1, 10_000) / 10_000;
        if (amount == 0) amount = held;
        trader.swap(key, tokenIsCurrency0, -int256(amount));
        tokensSold += amount;
        ++calls;
    }

    function transferBetweenTraders(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        Trader from = traders[fromSeed % traders.length];
        Trader to = traders[toSeed % traders.length];
        amount = bound(amount, 0, token.balanceOf(address(from)));
        assertTrue(from.send(IERC20Like(address(token)), address(to), amount));
        ++calls;
    }

    function collectFees() external {
        BalanceDelta fees = factory.collectFees(seedParams);
        tokenFeesCollected += uint256(uint128(tokenIsCurrency0 ? fees.amount0() : fees.amount1()));
        ++calls;
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    /// @dev IMD needed for `tokensOut` at the current sqrt price with the LP fee added back and no slippage.
    ///      price = sqrtP^2 / 2^192 is currency1 per currency0.
    function _quoteExactOutNoSlippage(uint256 tokensOut) internal view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint256 priceX192 = uint256(sqrtP) * uint256(sqrtP);
        uint256 imdNoFee = tokenIsCurrency0
            ? FullMath.mulDivRoundingUp(tokensOut, priceX192, 1 << 192)
            : FullMath.mulDivRoundingUp(tokensOut, 1 << 192, priceX192);
        return FullMath.mulDivRoundingUp(imdNoFee, 1_000_000, 1_000_000 - key.fee);
    }
}

/// @notice The pool holds value in GENESIS: whatever sequence of swaps, transfers and fee collections
///         happens, the supply is fixed, every token is accounted for across the manager and the
///         holders, traders never hold more than the manager released, and the seed never goes below
///         what it was minus what was sold out of it.
contract GENESISPoolInvariantTest is LaunchHarness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolHandler handler;

    function setUp() public override {
        super.setUp();
        _launch(true);
        handler = new PoolHandler(manager, token, imd, factory, key, seedParams, tokenIsCurrency0);
        factory.transferControl(address(handler));
        targetContract(address(handler));
    }

    function _traderTokens() internal view returns (uint256 sum) {
        uint256 n = handler.traderCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(address(handler.traders(i)));
        }
    }

    function _traderImd() internal view returns (uint256 sum) {
        uint256 n = handler.traderCount();
        for (uint256 i; i < n; ++i) {
            sum += imd.balanceOf(address(handler.traders(i)));
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixedUnderSwaps() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyTokenIsAccountedFor() public view {
        uint256 held = token.balanceOf(POOL_MANAGER) + token.balanceOf(address(factory)) + token.balanceOf(distributor)
            + token.balanceOf(DEAD) + _traderTokens();
        assertEq(held, SUPPLY, "tokens were created or lost through the pool");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tradersHoldOnlyWhatTheManagerReleased() public view {
        assertEq(_traderTokens(), handler.tokensBought() - handler.tokensSold(), "trader holdings drifted from swaps");
        assertEq(
            token.balanceOf(POOL_MANAGER) + token.balanceOf(address(factory)),
            seeded - handler.tokensBought() + handler.tokensSold(),
            "the manager plus collected fees is not the seed adjusted by swaps"
        );
        assertEq(token.balanceOf(address(factory)), handler.tokenFeesCollected(), "collected fees arrived short");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_imdIsAccountedFor() public view {
        assertEq(
            imd.balanceOf(POOL_MANAGER) + imd.balanceOf(address(factory)) + _traderImd(),
            handler.imdMinted(),
            "IMD was created or lost through the pool"
        );
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_seedLiquidityStaysActive() public view {
        // Nobody but the factory holds a position, and nothing removes it.
        (, int24 tick,,) = manager.getSlot0(key.toId());
        if (tick >= seedParams.tickLower && tick < seedParams.tickUpper) {
            assertEq(manager.getLiquidity(key.toId()), seedParams.liquidity, "seed liquidity changed");
        }
    }
}
