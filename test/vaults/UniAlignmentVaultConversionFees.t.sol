// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniAlignmentVault } from "src/vaults/uni/UniAlignmentVault.sol";
import { MiyaRegistry } from "src/registry/MiyaRegistry.sol";
import { IVaultPriceValidator } from "src/interfaces/IVaultPriceValidator.sol";
import { IMiyaRegistry } from "src/registry/interfaces/IMiyaRegistry.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";

contract CFTok is ERC20 {
    constructor() { _mint(msg.sender, 1e30); }
    function name() public pure override returns (string memory) { return "T"; }
    function symbol() public pure override returns (string memory) { return "T"; }
}

contract CFVal {
    function validatePrice(address, uint256) external pure {}
    function calculateSwapProportion(address, int24, int24, address, bytes32) external pure returns (uint256) { return 5e17; }
}

/// zRouter-like: exact-in swap on the real PoolManager, refunds its ETH balance to the payer.
contract CFRouter is IUnlockCallback {
    PoolManager pm; PoolKey key;
    constructor(PoolManager p, PoolKey memory k) { pm = p; key = k; }
    function swapV4(address to, bool, uint24, int24, address tokenIn, address, uint256 amt, uint256 limit, uint256)
        external payable returns (uint256, uint256 out)
    {
        bool z = tokenIn == address(0);
        if (!z) ERC20(tokenIn).transferFrom(msg.sender, address(this), amt);
        out = abi.decode(pm.unlock(abi.encode(z, amt, to)), (uint256));
        require(out >= limit, "limit");
        if (address(this).balance > 0) payable(msg.sender).transfer(address(this).balance);
    }
    function unlockCallback(bytes calldata d) external returns (bytes memory) {
        (bool z, uint256 amt, address to) = abi.decode(d, (bool, uint256, address));
        BalanceDelta dl = pm.swap(key, IPoolManager.SwapParams(z, -int256(amt),
            z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        if (z) { pm.settle{ value: amt }(); uint256 o = uint256(int256(dl.amount1())); pm.take(key.currency1, to, o); return abi.encode(o); }
        pm.sync(key.currency1); ERC20(Currency.unwrap(key.currency1)).transfer(address(pm), amt); pm.settle();
        uint256 o2 = uint256(int256(dl.amount0())); pm.take(key.currency0, to, o2); return abi.encode(o2);
    }
    receive() external payable {}
}

/// @dev The sweep's proof that a conversion's own swaps paid its fees to the wrong holders, on a real PoolManager.
contract UniAlignmentVaultConversionFeesTest is Test {
    using StateLibrary for PoolManager;
    using PoolIdLibrary for PoolKey;
    PoolManager pm; CFTok token; UniAlignmentVault vault; PoolKey key; MiyaRegistry reg; CFRouter zr;
    address alice = makeAddr("alice"); address bob = makeAddr("bob");

    function setUp() public {
        pm = new PoolManager(address(this));
        token = new CFTok();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10000, 200, IHooks(address(0)));
        pm.initialize(key, 79228162514264337593543950336);
        PoolModifyLiquidityTest lper = new PoolModifyLiquidityTest(pm);
        token.approve(address(lper), type(uint256).max);
        vm.deal(address(this), 1000 ether);
        // thin third-party seed: 1 ETH / 1 token full range
        lper.modifyLiquidity{ value: 2 ether }(key, IPoolManager.ModifyLiquidityParams(-887200, 887200, 1 ether, 0), "");
        reg = new MiyaRegistry(address(this), address(0xFEE), 100, 1000);
        address[] memory toks = new address[](1); toks[0] = address(token);
        reg.addTarget("t", toks);
        reg.setConversionKeeper(address(this));
        zr = new CFRouter(pm, key);
        vault = UniAlignmentVault(payable(LibClone.clone(address(new UniAlignmentVault()))));
        vault.initialize(address(this), address(0xBEEF), address(pm), address(token), address(zr), 10000, 200,
            IVaultPriceValidator(address(new CFVal())), IMiyaRegistry(address(reg)), 0);
        vault.setV4PoolKey(key);
        vm.deal(alice, 100 ether); vm.deal(bob, 100 ether);
    }
    receive() external payable {}

    function _contribute(address who, uint256 amt) internal {
        vm.prank(who);
        vault.receiveContribution{ value: amt }(Currency.wrap(address(0)), amt, who);
    }

    /// Alice's position earns the 1% fee on the swap made during Bob's conversion, before Bob's batch closes.
    /// That fee belongs to Alice (shareholders before the close) but is netted into Bob's LP add.
    function test_feesEarnedDuringConversionSwapStayWithEarlierHolders() public {
        _contribute(alice, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        uint256 aliceBefore = vault.getUnclaimedFees(alice);
        uint256 lpBefore = vault.totalLPUnits();
        uint128 poolL = StateLibrary.getLiquidity(IPoolManager(address(pm)), key.toId());

        (uint256 g0Before,) = StateLibrary.getFeeGrowthGlobals(IPoolManager(address(pm)), key.toId());
        _contribute(bob, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        (uint256 g0After,) = StateLibrary.getFeeGrowthGlobals(IPoolManager(address(pm)), key.toId());
        // ETH fees the pre-existing (Alice's) liquidity earned from the conversion's own swaps. Full range, so
        // inside growth == global growth.
        uint256 earnedByAlicesLiquidity = (g0After - g0Before) * lpBefore >> 128;
        uint256 aliceFees = vault.getUnclaimedFees(alice) - aliceBefore;
        // Bob's conversion swaps several ETH at 1%; Alice's position (~95% of the pool) earns most of that fee.
        assertGt(earnedByAlicesLiquidity, 0.05 ether);
        // Expected: Alice (less the 1% protocol cut) is credited what her liquidity earned before Bob's batch closed.
        assertGe(aliceFees, earnedByAlicesLiquidity * 98 / 100, "fee earned by alice's liquidity was netted into the add");
    }

    function _owed() internal view returns (uint256) {
        return vault.accumulatedFees() - vault.totalFeesClaimed() + vault.accumulatedProtocolFees();
    }

    /// There are no earlier holders on the first conversion, so its own fees stay in the batch.
    function test_firstConversionPaysNoYield() public {
        _contribute(alice, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertEq(vault.accumulatedFees(), 0);
        assertEq(vault.accumulatedProtocolFees(), 0);
    }

    /// The protocol's cut of those fees is booked too, and what is booked never goes into the position.
    function test_bookedFeesStayPayable() public {
        _contribute(alice, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        _contribute(bob, 20 ether);
        vault.convertAndAddLiquidity(1, 1);

        assertGt(vault.accumulatedProtocolFees(), 0, "protocol cut booked");
        assertGe(address(vault).balance, _owed(), "booked fees are all held");

        vm.prank(alice);
        uint256 claimed = vault.claimFees();
        assertGt(claimed, 0);
        assertGe(address(vault).balance, _owed(), "still held after a claim");
    }

    /// Bob's batch must not earn from fees its own conversion paid.
    function test_newBatchEarnsNothingFromItsOwnSwap() public {
        _contribute(alice, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        _contribute(bob, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertEq(vault.getUnclaimedFees(bob), 0);
    }

    /// Three conversions in a row keep the books whole.
    function test_repeatedConversionsStaySolvent() public {
        for (uint256 i; i < 3; ++i) {
            _contribute(alice, 5 ether);
            _contribute(bob, 15 ether);
            vault.convertAndAddLiquidity(1, 1);
            assertGe(address(vault).balance, _owed());
        }
        vm.prank(alice);
        vault.claimFees();
        vm.prank(bob);
        vault.claimFees();
        assertGe(address(vault).balance, vault.accumulatedProtocolFees());
    }

    /// With tokens to spare the add takes all the ETH it is offered, so nothing but the books protects booked fees.
    function test_addLimitedByEthCannotSpendBookedFees() public {
        _contribute(alice, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        _contribute(bob, 20 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertGt(vault.accumulatedProtocolFees(), 0);

        token.transfer(address(vault), 1e27);
        _contribute(bob, 1 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertGe(address(vault).balance, _owed());
    }
}
