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
        // Rounding per claim, plus the fees earned by a few wei of shares that round down when a batch is collected.
        assertApproxEqAbs(claimed, feesIn, 24 * 3 + feesIn / 1e15, "fees stranded beyond rounding dust");
    }

    // ── audit round 2: batches close in one step ─────────────────────────────

    function _freshContributors(uint256 from, uint256 count) internal {
        for (uint256 i = from; i < from + count; ++i) {
            address who = address(uint160(0x100000 + i));
            uint256 minimum = vault.MIN_CONTRIBUTION();
            vm.deal(who, 1 ether);
            vm.prank(who);
            (bool ok,) = address(vault).call{ value: minimum }("");
            assertTrue(ok);
        }
    }

    function _convertGas() internal returns (uint256 used) {
        vm.prank(keeper);
        uint256 before = gasleft();
        vault.convertAndAddLiquidity(1, 1);
        used = before - gasleft();
    }

    /// The final review's High: a batch's cost grew with its contributors, past mainnet's transaction gas cap.
    function test_conversionCostDoesNotGrowWithContributors() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        vault.depositFees{ value: 1 ether }();

        _freshContributors(0, 5);
        uint256 few = _convertGas();
        _freshContributors(100, 1500);
        uint256 many = _convertGas();

        assertLt(many, 1_000_000, "fits any block");
        assertApproxEqAbs(many, few, 120_000, "same cost for 5 or 1500 contributors");
        assertEq(vault.benefactorShares(address(uint160(0x100000 + 100))) > 0, true);
    }

    function test_batchSharesFollowEachContribution() public {
        _contribute(artistA, 1 ether);
        _contribute(artistB, 3 ether);
        _convert(keeper);
        assertApproxEqAbs(vault.benefactorShares(artistB), vault.benefactorShares(artistA) * 3, 4);
        assertApproxEqAbs(vault.benefactorShares(artistA) + vault.benefactorShares(artistB), vault.totalShares(), 2);
    }

    function test_fewerSharesCanNeverBeClaimedThanIssuedRoundingOnly() public {
        for (uint256 i; i < 7; ++i) {
            address who = makeAddr(string(abi.encodePacked("r", i)));
            vm.deal(who, 1 ether);
            vm.prank(who);
            (bool ok,) = address(vault).call{ value: 0.001 ether + i * 1e13 }("");
            assertTrue(ok);
        }
        _convert(keeper);
        uint256 sum;
        for (uint256 i; i < 7; ++i) sum += vault.benefactorShares(makeAddr(string(abi.encodePacked("r", i))));
        assertLe(sum, vault.totalShares());
        assertApproxEqAbs(sum, vault.totalShares(), 7);
    }

    /// Someone who never touches the vault again still has the right shares and fees, across later batches.
    function test_untouchedBenefactorKeepsSharesAndFees() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        uint256 aShares = vault.benefactorShares(artistA);
        vault.depositFees{ value: 1 ether }();

        _contribute(artistB, 1 ether);
        _convert(keeper);
        _contribute(artistC, 1 ether);
        _convert(keeper);

        assertEq(vault.benefactorShares(artistA), aShares, "shares unchanged by later batches");
        assertEq(vault.getBenefactorShares(artistA), aShares);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 2, "fees from before others joined are all A's");
        assertEq(vault.getUnclaimedFees(artistB), 0, "B earned nothing before joining");

        vm.prank(artistA);
        assertApproxEqAbs(vault.claimFees(), 1 ether, 2);
        vm.prank(artistA);
        vm.expectRevert();
        vault.claimFees();
    }

    /// Shares arrive only at the batch's close: fees booked while waiting belong to existing holders.
    function test_pendingContributionEarnsNothingBeforeItsBatchCloses() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        _contribute(artistB, 1 ether);
        vault.depositFees{ value: 1 ether }();
        assertEq(vault.benefactorShares(artistB), 0);
        _convert(keeper);
        assertEq(vault.getUnclaimedFees(artistB), 0);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 2);
    }

    /// Contributing again collects the earlier batch first, without touching fees earned on it.
    function test_contributingAgainCollectsTheEarlierBatch() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        uint256 first = vault.benefactorShares(artistA);
        vault.depositFees{ value: 1 ether }();
        _contribute(artistA, 1 ether);
        assertEq(vault.benefactorShares(artistA), first, "pending ETH adds no shares yet");
        assertEq(vault.pendingETH(artistA), 1 ether);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 2);
        _convert(keeper);
        assertGt(vault.benefactorShares(artistA), first);
        assertApproxEqAbs(vault.getUnclaimedFees(artistA), 1 ether, 2, "still exactly the earlier fees");
    }

    function testFuzz_claimsNeverExceedFees(uint64[4] memory amounts, uint64 feeA, uint64 feeB) public {
        address[4] memory who = [artistA, artistB, artistC, makeAddr("d")];
        vm.deal(who[3], 1000 ether);
        uint256 fees;
        for (uint256 i; i < 4; ++i) {
            _contribute(who[i], bound(amounts[i], vault.MIN_CONTRIBUTION(), 50 ether));
            if (i % 2 == 1) {
                _convert(keeper);
                uint256 f = bound(i == 1 ? feeA : feeB, 1e6, 5 ether);
                vault.depositFees{ value: f }();
                fees += f;
            }
        }
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            if (vault.getUnclaimedFees(who[i]) == 0) continue;
            vm.prank(who[i]);
            paid += vault.claimFees();
        }
        assertLe(paid, fees);
        assertApproxEqAbs(paid, fees, 1e6, "only rounding is left");
    }

    function test_feeTokenFloorOfZeroLeavesThemPending() public {
        _contribute(artistA, 1 ether);
        _convert(keeper);
        reg.setConversionKeeper(keeper);
        _contribute(artistB, 1 ether);
        vm.prank(keeper);
        vault.convertAndAddLiquidity(1, 0);
        assertEq(vault.closedBatches(), 2);
    }
}
