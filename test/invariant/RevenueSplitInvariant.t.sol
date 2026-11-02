// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitLib} from "../../src/shared/libraries/RevenueSplitLib.sol";

/// @title RevenueSplitInvariantTest
/// @notice Fuzz-based invariants for split(amount, protocolBps, alignmentBps):
///         protocolCut + vaultCut + remainder == input (no wei leak or creation), cuts are floors.
contract RevenueSplitInvariantTest is Test {
    // amount * 10_000 must not overflow
    uint256 constant MAX_AMOUNT = type(uint256).max / 10_000;

    /// @dev Bound fee terms to what MiyaRegistry can produce: protocol <= 500, protocol + alignment <= 10_000.
    function _terms(uint16 p, uint16 a) internal pure returns (uint16, uint16) {
        p = uint16(bound(p, 0, 500));
        a = uint16(bound(a, 0, 10_000 - p));
        return (p, a);
    }

    function testFuzz_splitSumsToInput(uint256 amount, uint16 p, uint16 a) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        (p, a) = _terms(p, a);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, p, a);
        assertEq(s.protocolCut + s.vaultCut + s.remainder, amount, "split leaks or creates wei");
    }

    function testFuzz_cutsAreFloors(uint256 amount, uint16 p, uint16 a) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        (p, a) = _terms(p, a);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, p, a);
        assertEq(s.protocolCut, (amount * p) / 10_000, "protocolCut != floor");
        assertEq(s.vaultCut, (amount * a) / 10_000, "vaultCut != floor");
    }

    function testFuzz_remainderAtLeastArtistShareFloor(uint256 amount, uint16 p, uint16 a) external pure {
        amount = bound(amount, 0, MAX_AMOUNT);
        (p, a) = _terms(p, a);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, p, a);
        assertGe(s.remainder, (amount * (10_000 - p - a)) / 10_000, "remainder below artist share");
    }

    function testFuzz_defaultTermsMatchLegacy(uint256 amount) external pure {
        // 1% / 19% / 80% reproduces the old fixed split exactly
        amount = bound(amount, 0, MAX_AMOUNT);
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, 100, 1900);
        assertEq(s.protocolCut, amount / 100);
        assertEq(s.vaultCut, (amount * 19) / 100);
        assertEq(s.remainder, amount - amount / 100 - (amount * 19) / 100);
    }

    function test_splitZero() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(0, 100, 1000);
        assertEq(s.protocolCut, 0);
        assertEq(s.vaultCut, 0);
        assertEq(s.remainder, 0);
    }

    function test_splitOne() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(1, 100, 1000);
        assertEq(s.protocolCut, 0);
        assertEq(s.vaultCut, 0);
        assertEq(s.remainder, 1);
    }

    function test_splitHundred_minimumAlignment() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(100, 100, 1000);
        assertEq(s.protocolCut, 1);
        assertEq(s.vaultCut, 10);
        assertEq(s.remainder, 89);
    }

    function test_splitOneEther_customAlignment() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(1 ether, 100, 2500);
        assertEq(s.protocolCut, 0.01 ether);
        assertEq(s.vaultCut, 0.25 ether);
        assertEq(s.remainder, 0.74 ether);
    }

    function test_splitAllToVault() external pure {
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(1 ether, 100, 9900);
        assertEq(s.protocolCut, 0.01 ether);
        assertEq(s.vaultCut, 0.99 ether);
        assertEq(s.remainder, 0);
    }
}
