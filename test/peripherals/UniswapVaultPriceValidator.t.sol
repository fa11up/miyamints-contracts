// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { UniswapVaultPriceValidator } from "../../src/peripherals/UniswapVaultPriceValidator.sol";

/// @dev Pools here sort the token below WETH, which is INFER's case on mainnet.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint128 public liquidity;
    int24 internal tick;

    constructor(address token0_, address token1_, uint128 liquidity_, int24 tick_) {
        token0 = token0_;
        token1 = token1_;
        liquidity = liquidity_;
        tick = tick_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtPriceAtTick(tick), tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory t, uint160[] memory l) {
        t = new int56[](2);
        l = new uint160[](2);
        t[1] = int56(tick) * int56(uint56(secondsAgos[0]));
    }
}

contract MockV3Factory {
    mapping(uint24 => address) public pools;

    function set(uint24 fee, address pool) external {
        pools[fee] = pool;
    }

    function getPool(address, address, uint24 fee) external view returns (address) {
        return pools[fee];
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 internal r0;
    uint112 internal r1;

    constructor(address token0_, address token1_, uint112 r0_, uint112 r1_) {
        token0 = token0_;
        token1 = token1_;
        r0 = r0_;
        r1 = r1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }
}

contract MockV2Factory {
    address public pair;

    function set(address pair_) external {
        pair = pair_;
    }

    function getPair(address, address) external view returns (address) {
        return pair;
    }
}

/// @dev Every slot reads as empty, so no v4 pool exists.
contract EmptyPoolManager {
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract MockWeth {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }
}

contract UniswapVaultPriceValidatorTest is Test {
    address WETH;
    address constant TOKEN = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;

    MockV2Factory v2;
    MockV3Factory v3;
    UniswapVaultPriceValidator validator;

    function setUp() public {
        // Below TOKEN's address sorting isn't what these tests vary: WETH sorts after the token, like INFER on mainnet.
        WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        vm.etch(WETH, address(new MockWeth()).code);
        v2 = new MockV2Factory();
        v3 = new MockV3Factory();
        validator = new UniswapVaultPriceValidator(WETH, address(v2), address(v3), address(new EmptyPoolManager()), 500, 1800);
        // A real v2 reference: 50 WETH against 50 tokens, so 1 token = 1 WETH.
        v2.set(address(new MockV2Pair(TOKEN, WETH, 50e18, 50e18)));
    }

    /// Tick 69_000 is about 1 token = 1000 WETH, nowhere near the v2 reference.
    function _v3AtWrongPrice(uint128 liquidity) internal {
        _v3At(liquidity, 69_000, 100e18);
    }

    function _v3At(uint128 liquidity, int24 tick, uint256 wethHeld) internal {
        address pool = address(new MockV3Pool(TOKEN, WETH, liquidity, tick));
        MockWeth(WETH).set(pool, wethHeld);
        v3.set(3000, pool);
    }

    /// Enough virtual depth from a one-tick position, but only dust of real WETH behind it.
    function test_narrowPoolWithoutRealWethIsIgnored() public {
        _v3At(1e30, 69_000, 1e15);
        validator.validatePrice(TOKEN, 1 ether);
    }

    function test_dustV3PoolAtWrongPriceIsIgnored() public {
        _v3AtWrongPrice(1);
        validator.validatePrice(TOKEN, 1 ether);
    }

    function test_dustV2PairCannotBlockConversions() public {
        v2.set(address(new MockV2Pair(TOKEN, WETH, 1e12, 1)));
        validator.validatePrice(TOKEN, 1 ether);
    }

    /// The cheapest price a real v2 reference can have: uint112 caps the token reserve near 5e33, and it needs 10 WETH.
    /// Integer rounding of the two prices is nowhere near the 5% limit there.
    function test_cheapestV2ReferenceAgreeingPricesPass() public {
        int24 tick = -338_000;
        uint256 sqrt = TickMath.getSqrtPriceAtTick(tick);
        uint256 wethReserve = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(5e33, sqrt, 1 << 96), sqrt, 1 << 96);
        assertGe(wethReserve, validator.MIN_REFERENCE_WETH(), "reference must count");
        v2.set(address(new MockV2Pair(TOKEN, WETH, 5e33, uint112(wethReserve))));
        _v3At(1e30, tick, 100e18);
        validator.validatePrice(TOKEN, 1 ether);
    }

    function test_cheapestV2ReferenceDisagreeingPricesBlock() public {
        int24 tick = -338_000;
        uint256 sqrt = TickMath.getSqrtPriceAtTick(tick);
        uint256 wethReserve = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(5e33, sqrt, 1 << 96), sqrt, 1 << 96);
        v2.set(address(new MockV2Pair(TOKEN, WETH, 5e33, uint112(wethReserve * 2))));
        _v3At(1e30, tick, 100e18);
        vm.expectRevert(UniswapVaultPriceValidator.PriceDeviationTooHigh.selector);
        validator.validatePrice(TOKEN, 1 ether);
    }

    function test_deepV3PoolAtWrongPriceStillBlocks() public {
        _v3AtWrongPrice(1e30);
        vm.expectRevert(UniswapVaultPriceValidator.PriceDeviationTooHigh.selector);
        validator.validatePrice(TOKEN, 1 ether);
    }

    /// Above tick ~694_500 the old price formula overflowed. A deep pool passes the depth floor and reaches it.
    function test_extremeTickDoesNotPanic() public {
        _v3At(1e30, 800_000, 100e18);
        vm.expectRevert(UniswapVaultPriceValidator.PriceDeviationTooHigh.selector);
        validator.validatePrice(TOKEN, 1 ether);
    }

    // ── quoteEthForTokens (view; never reverts, so the failure cases return 0) ──

    function test_quoteEthForTokens_zeroAmountReturnsZero() public view {
        assertEq(validator.quoteEthForTokens(TOKEN, 0), 0);
    }

    /// V2 only: 30 WETH against 60 tokens, so 1 token = 0.5 WETH.
    function test_quoteEthForTokens_usesV2SpotWhenNoV3() public {
        v2.set(address(new MockV2Pair(TOKEN, WETH, 60e18, 30e18)));
        assertEq(validator.quoteEthForTokens(TOKEN, 4e18), 2e18);
    }

    /// A deep V3 pool at tick 0 (sqrtPrice = 2^96, price exactly 1e18) wins over a disagreeing V2 pair.
    function test_quoteEthForTokens_prefersV3Twap() public {
        v2.set(address(new MockV2Pair(TOKEN, WETH, 60e18, 30e18)));
        _v3At(1e30, 0, 100e18);
        assertEq(validator.quoteEthForTokens(TOKEN, 3e18), 3e18);
    }

    function test_quoteEthForTokens_noPoolsReturnsZero() public {
        v2.set(address(0));
        assertEq(validator.quoteEthForTokens(TOKEN, 1e18), 0);
        // Factories without code are also treated as "no pool".
        UniswapVaultPriceValidator bare =
            new UniswapVaultPriceValidator(WETH, address(0xA1), address(0xA2), address(new EmptyPoolManager()), 500, 1800);
        assertEq(bare.quoteEthForTokens(TOKEN, 1e18), 0);
    }

    /// A share of value, so the answer can't depend on the token's raw price. Fuzzes across real price ranges.
    function testFuzz_fullRangeProportionIsHalfAtAnyPrice(int24 tick) public {
        tick = int24(bound(tick, -400_000, 400_000));
        StaticPrice pm = new StaticPrice(TickMath.getSqrtPriceAtTick(tick));
        uint256 p = validator.calculateSwapProportion(TOKEN, -887_200, 887_200, address(pm), bytes32(0));
        assertApproxEqRel(p, 5e17, 1e15);
    }
}

contract StaticPrice {
    uint160 internal price;

    constructor(uint160 p) {
        price = p;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(price));
    }
}
