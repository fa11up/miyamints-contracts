// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { TestableUniAlignmentVault } from "../helpers/TestableUniAlignmentVault.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { IVaultPriceValidator } from "../../src/interfaces/IVaultPriceValidator.sol";
import { IMiyaRegistry } from "../../src/registry/interfaces/IMiyaRegistry.sol";
import { MockZRouter } from "../mocks/MockZRouter.sol";
import { MockVaultPriceValidator } from "../mocks/MockVaultPriceValidator.sol";
import { MockEXECToken } from "../mocks/MockEXECToken.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

/// @notice Regressions for audit H2 (fee watermark strands / erases unclaimed fees) and H3 (conversion caller
///         reward paid out of benefactors' fees, scaled by tx.gasprice).
/// @dev Fee income is injected with depositFees() to stand in for LP yield; the per-share accounting under test
///      is identical whichever way fees arrive.
contract UniAlignmentVaultFeeAccountingTest is Test {
    TestableUniAlignmentVault vault;
    address artistA = makeAddr("collectionA");
    address artistB = makeAddr("collectionB");
    address artistC = makeAddr("collectionC");
    address griefer = makeAddr("griefer");
    address keeper = makeAddr("keeper");
    MiyaRegistry reg;

    function setUp() public {
        MockEXECToken token = new MockEXECToken(1_000_000e18);
        reg = new MiyaRegistry(address(this), address(0xFEE), 100, 1000);
        address[] memory toks = new address[](1);
        toks[0] = address(token);
        reg.addTarget("t", toks);
        MockZRouter zr = new MockZRouter();
        token.transfer(address(zr), 100_000e18);
        vault = TestableUniAlignmentVault(payable(LibClone.clone(address(new TestableUniAlignmentVault()))));
        vault.initialize(address(this), address(1), address(0x2222), address(token), address(zr), 3000, 60,
            IVaultPriceValidator(address(new MockVaultPriceValidator())), IMiyaRegistry(address(reg)), 0);
        vault.setV4PoolKey(PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0))));
        vm.deal(artistA, 1000 ether);
        vm.deal(artistB, 1000 ether);
        vm.deal(artistC, 1000 ether);
        vm.deal(griefer, 1 ether);
        vm.deal(address(this), 1000 ether);
    }

    function _contribute(address who, uint256 amt) internal {
        vm.prank(who);
        vault.receiveContribution{ value: amt }(Currency.wrap(address(0)), amt, who);
    }

    function _convert(address caller) internal {
        reg.setConversionKeeper(caller);
        vm.prank(caller);
        vault.convertAndAddLiquidity(1, 1);
    }

    /// H2: new shares must not dilute holders' UNCLAIMED past fees.
    function test_newSharesDoNotStrandUnclaimedFees() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        vault.depositFees{ value: 1 ether }(); // A alone earned 1 ETH
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 1);

        _contribute(artistB, 1 ether); // B joins before A claims
        _convert(keeper);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 1, "A keeps fees earned before B joined");
        assertEq(vault.getUnclaimedFees(artistB), 0, "B earns nothing retroactively");

        vault.depositFees{ value: 2 ether }(); // now split ~50/50
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 2 ether, 1e3);
        assertApproxEqAbs(vault.getUnclaimedFees(artistB), 1 ether, 1e3);

        vm.prank(artistA);
        uint256 a = vault.claimFees();
        vm.prank(artistB);
        uint256 b = vault.claimFees();
        assertLe(a + b, 3 ether);
        assertApproxEqAbs(a + b, 3 ether, 1e3, "nothing stranded");
    }

    /// H2: re-contributing on A's behalf (e.g. anyone calling the permissionless ERC721DropInstance.withdraw())
    ///     must not erase A's unclaimed fees.
    function test_recontributionDoesNotWipeUnclaimedFees() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        vault.depositFees{ value: 1 ether }();
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 1);

        _contribute(artistA, 0.01 ether);
        _convert(griefer);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 1, "A's fees survive the share change");

        uint256 before = artistA.balance;
        vm.prank(artistA);
        vault.claimFees();
        assertApproxEqAbs(artistA.balance - before, 1 ether, 1);
    }

    /// H3: caller reward is capped, has no gas-price term and never comes out of benefactors' fees.
    function test_callerRewardCannotDrainBenefactorFees() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        vault.depositFees{ value: 1 ether }(); // 1 ETH owed to A
        uint256 bal = address(vault).balance;

        vm.prank(griefer);
        vault.receiveContribution{ value: 0.001 ether }(Currency.wrap(address(0)), 0.001 ether, griefer);
        vm.txGasPrice((bal - 0.0012 ether) / 115_000); // the pre-fix attack gas price
        uint256 g0 = griefer.balance;
        _convert(griefer);
        assertEq(griefer.balance - g0, 0.00001 ether, "reward = 1% of the 0.001 ETH batch, no gas term");

        vm.txGasPrice(1);
        uint256 before = artistA.balance;
        vm.prank(artistA);
        vault.claimFees();
        assertApproxEqAbs(artistA.balance - before, 1 ether, 1, "A's fees intact");
    }

    /// H3: whatever the gas price, the vault stays solvent for every fee obligation.
    function testFuzz_callerRewardKeepsVaultSolvent(uint256 gasPrice, uint96 batch) public {
        gasPrice = bound(gasPrice, 0, 1e15);
        uint256 amt = bound(uint256(batch), vault.MIN_CONTRIBUTION(), 100 ether);
        _contribute(artistA, 1 ether);
        _convert(keeper);
        vault.depositFees{ value: 1 ether }();

        _contribute(artistB, amt);
        vm.txGasPrice(gasPrice);
        uint256 g0 = griefer.balance;
        _convert(griefer);
        assertLe(griefer.balance - g0, vault.CONVERSION_REWARD());
        assertLe(griefer.balance - g0, amt * vault.MAX_CONVERSION_REWARD_BPS() / 10000);

        uint256 owed = vault.getUnclaimedFees(artistA) + vault.getUnclaimedFees(artistB)
            + vault.accumulatedProtocolFees() + vault.totalPendingETH();
        assertLe(owed, address(vault).balance, "solvent");
    }

    /// H2 invariant (fuzz): over random contribute / convert / fee / claim sequences, sum of claims never
    ///     exceeds fees distributed and, once everyone has claimed, nothing beyond dust is left behind.
    function testFuzz_claimsNeverExceedFeesAndNothingStranded(uint256 seed) public {
        address[3] memory who = [artistA, artistB, artistC];
        uint256 feesIn;
        uint256 claimed;
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address actor = who[r % 3];
            uint256 action = (r >> 8) % 4;
            uint256 amt = bound(r >> 16, 0.001 ether, 5 ether);
            if (action == 0) {
                _contribute(actor, amt);
            } else if (action == 1) {
                if (vault.totalPendingETH() != 0) _convert(griefer);
            } else if (action == 2) {
                if (vault.totalShares() != 0) {
                    vault.depositFees{ value: amt }();
                    feesIn += amt;
                }
            } else if (vault.getUnclaimedFees(actor) != 0) {
                vm.prank(actor);
                claimed += vault.claimFees();
            }
            assertLe(claimed, feesIn, "claims exceed fees");
        }
        // Rejected rewards are the only other fee source; griefer is an EOA so there are none here.
        assertEq(vault.accumulatedFees(), feesIn);
        for (uint256 i; i < 3; ++i) {
            if (vault.getUnclaimedFees(who[i]) != 0) {
                vm.prank(who[i]);
                claimed += vault.claimFees();
            }
        }
        assertLe(claimed, feesIn, "claims exceed fees");
        assertApproxEqAbs(claimed, feesIn, 24 * 3, "fees stranded beyond rounding dust");
    }
}
