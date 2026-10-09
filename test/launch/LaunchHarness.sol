// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GENESISToken} from "../../src/GENESISToken.sol";
import {PoolManager} from "../vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../vendor/v4-core/src/types/PoolId.sol";
import {Currency} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "../vendor/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "../vendor/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "../vendor/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "../vendor/v4-core/src/libraries/StateLibrary.sol";

/// @notice The subset of ERC-20 the launch flows touch, declared here so the harness does not depend
///         on the token's own interface.
interface IERC20Like {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Stand-in for IMD, the paired currency, placed at the real IMD address so the pool sorts its
///         two currencies the way mainnet will. A plain ERC-20 with checked arithmetic: it reverts on
///         an overdrawn transfer and never taxes. Only the harness mints it.
contract PairTokenStub {
    string public constant name = "IdentityMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

/// @notice Pays and collects Uniswap v4 balance deltas for ERC-20 currencies the documented way:
///         sync, transfer, settle for what is owed to the pool; take for what the pool owes.
abstract contract V4Settler is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function _settleDelta(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 owed = uint256(uint128(-delta));
            manager.sync(currency);
            IERC20Like(Currency.unwrap(currency)).transfer(address(manager), owed);
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}

/// @notice Stand-in for the launch factory: deploys the token through CREATE2 so the token's deployer
///         (msg.sender in its constructor) is this contract, holds the supply, forwards the swarm share
///         and the remainder, and seeds the pool single-sided through the pool manager's unlock. It
///         can also poke its position to collect the LP fees swaps have accrued. Only the test drives it.
contract LaunchFactoryStub is V4Settler {
    address private controller = msg.sender;

    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    uint8 private constant SEED = 0;
    uint8 private constant POKE = 1;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    constructor(IPoolManager manager_) V4Settler(manager_) {}

    /// @dev Hands the stub to an invariant handler so it can collect fees during a campaign.
    function transferControl(address next) external onlyController {
        controller = next;
    }

    function deploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20Like token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external onlyController returns (int24) {
        return manager.initialize(key, sqrtPriceX96);
    }

    function seed(Seed calldata seed_) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(SEED, abi.encode(seed_))), (BalanceDelta));
    }

    /// @dev Zero-delta modifyLiquidity: collects the fees the position has earned.
    function collectFees(Seed calldata seed_) external onlyController returns (BalanceDelta fees) {
        return abi.decode(manager.unlock(abi.encode(POKE, abi.encode(seed_))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (uint8 kind, bytes memory payload) = abi.decode(data, (uint8, bytes));
        Seed memory s = abi.decode(payload, (Seed));
        int256 liquidityDelta = kind == SEED ? int256(uint256(s.liquidity)) : int256(0);
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(
            s.key, IPoolManager.ModifyLiquidityParams(s.tickLower, s.tickUpper, liquidityDelta, bytes32(0)), ""
        );
        _settleDelta(s.key.currency0, callerDelta.amount0());
        _settleDelta(s.key.currency1, callerDelta.amount1());
        return abi.encode(kind == SEED ? callerDelta : feesAccrued);
    }
}

/// @notice An ordinary trader: nothing the token has any reason to treat specially. Buys and sells
///         through the pool manager, paying and collecting its own deltas.
contract Trader is V4Settler {
    PoolKey private key;

    constructor(IPoolManager manager_) V4Settler(manager_) {}

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function send(IERC20Like token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, IPoolManager.SwapParams(zeroForOne, amountSpecified, limit), "");
        _settleDelta(key.currency0, delta.amount0());
        _settleDelta(key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice Shared setup for the launch-flow tests: a real Uniswap v4 PoolManager constructed in place at
///         the mainnet PoolManager address, the IMD stub at the mainnet IMD address, and a launch that
///         mirrors the factory's: deploy, 10% to the distributor, 90% single-sided into the pool at the
///         price derived from the 2500 IMD opening cap, remainder to 0xdead.
abstract contract LaunchHarness is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 9_000;
    uint256 internal constant SWARM = SUPPLY * SWARM_BPS / 10_000;
    uint256 internal constant POOL_SHARE = SUPPLY * POOL_BPS / 10_000;
    uint256 internal constant INITIAL_CAP_WEI = 2_500 ether;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant MANIFEST_SQRT_PRICE = 125_270_724_187_523_965_593_206_900;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager internal manager;
    PairTokenStub internal imd;
    LaunchFactoryStub internal factory;
    GENESISToken internal token;
    address internal distributor = makeAddr("distributor");

    PoolKey internal key;
    LaunchFactoryStub.Seed internal seedParams;
    bool internal tokenIsCurrency0;
    uint256 internal seeded;
    uint256 internal remainder;

    function setUp() public virtual {
        // v4's manager records the address it was built at, so it is constructed in place: the creation
        // code (with its constructor argument) is run as if it were runtime code and returns the runtime.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        require(built && runtime.length > 0, "pool manager could not be built in place");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);
        vm.label(POOL_MANAGER, "PoolManager");

        vm.etch(IMD, address(new PairTokenStub()).code);
        imd = PairTokenStub(IMD);
        vm.label(IMD, "IMD");
    }

    /// @dev Runs the whole launch. `tokenFirst` chooses the CREATE2 salt so the token sorts as currency0
    ///      (or currency1) against IMD; mainnet will land on one of the two and the pool must work either way.
    function _launch(bool tokenFirst) internal {
        factory = new LaunchFactoryStub(manager);
        vm.label(address(factory), "factory");

        bytes memory code = type(GENESISToken).creationCode;
        bytes32 codeHash = keccak256(code);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
            if ((predicted < IMD) == tokenFirst) break;
        }
        token = GENESISToken(factory.deploy(code, salt));
        tokenIsCurrency0 = address(token) < IMD;
        require(tokenIsCurrency0 == tokenFirst, "salt search produced the wrong order");
        vm.label(address(token), "GENESIS");

        // 1. the swarm's share, whole, to the distributor
        require(factory.move(IERC20Like(address(token)), distributor, SWARM), "swarm transfer returned false");

        // 2. the pool, at the derived opening price, single-sided with the requester's 90%
        key = _poolKey();
        factory.initialize(key, _openingSqrtPriceX96());
        seedParams = _seedParams();
        uint256 before = token.balanceOf(address(factory));
        factory.seed(seedParams);
        seeded = before - token.balanceOf(address(factory));

        // 3. whatever is left to remainderTo
        remainder = token.balanceOf(address(factory));
        require(factory.move(IERC20Like(address(token)), DEAD, remainder), "remainder transfer returned false");
    }

    function _poolKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(token)));
        return PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    /// @dev sqrt(price) * 2^96 where price is currency1 per currency0 in minor units, from the 2500 IMD
    ///      opening cap over the whole supply, snapped down to a usable tick.
    function _openingSqrtPriceX96() internal view returns (uint160) {
        uint256 ratioX192 = tokenIsCurrency0
            ? FullMath.mulDiv(INITIAL_CAP_WEI, 1 << 192, SUPPLY)
            : FullMath.mulDiv(SUPPLY, 1 << 192, INITIAL_CAP_WEI);
        uint160 raw = uint160(_sqrt(ratioX192));
        return TickMath.getSqrtPriceAtTick(_alignedTick(TickMath.getTickAtSqrtPrice(raw)));
    }

    function _alignedTick(int24 tick) internal pure returns (int24 aligned) {
        aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) aligned -= TICK_SPACING;
    }

    /// @dev The largest liquidity whose single-sided deposit does not exceed the pool share. The range
    ///      starts (token as currency0) or ends (token as currency1) exactly at the opening tick, so the
    ///      position is in range and needs none of the paired currency.
    function _seedParams() internal view returns (LaunchFactoryStub.Seed memory s) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        s.key = key;
        if (tokenIsCurrency0) {
            s.tickLower = tick;
            s.tickUpper = TickMath.maxUsableTick(TICK_SPACING);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(s.tickUpper);
            uint256 liquidity =
                FullMath.mulDiv(FullMath.mulDiv(POOL_SHARE, sqrtP, FixedPoint96.Q96), sqrtB, sqrtB - sqrtP);
            while (SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, uint128(liquidity), true) > POOL_SHARE) --liquidity;
            s.liquidity = uint128(liquidity);
        } else {
            s.tickLower = TickMath.minUsableTick(TICK_SPACING);
            s.tickUpper = tick;
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(s.tickLower);
            uint256 liquidity = FullMath.mulDiv(POOL_SHARE, FixedPoint96.Q96, sqrtP - sqrtA);
            while (SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, uint128(liquidity), true) > POOL_SHARE) --liquidity;
            s.liquidity = uint128(liquidity);
        }
    }

    /// @dev Direction of a swap that buys GENESIS with IMD.
    function _buyIsZeroForOne() internal view returns (bool) {
        return !tokenIsCurrency0;
    }

    /// @dev GENESIS out for `imdIn` at the current pool price with the LP fee removed and no slippage:
    ///      an upper bound on what a buy can return.
    function _quoteBuyNoSlippage(uint256 imdIn) internal view returns (uint256) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        return _quoteBuyNoSlippage(imdIn, sqrtP);
    }

    /// @dev The same quote at a given sqrt price (the price before the swap, when quoting afterwards).
    ///      Exact in 512-bit arithmetic: price = sqrtP^2 / 2^192 is currency1 per currency0.
    function _quoteBuyNoSlippage(uint256 imdIn, uint160 sqrtP) internal view returns (uint256) {
        uint256 inLessFee = imdIn * (1_000_000 - POOL_FEE) / 1_000_000;
        uint256 priceX192 = uint256(sqrtP) * uint256(sqrtP);
        return tokenIsCurrency0
            ? FullMath.mulDiv(inLessFee, 1 << 192, priceX192)
            : FullMath.mulDiv(inLessFee, priceX192, 1 << 192);
    }

    function _sqrtPrice() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(key.toId());
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return tokenIsCurrency0 ? delta.amount0() : delta.amount1();
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return tokenIsCurrency0 ? delta.amount1() : delta.amount0();
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
