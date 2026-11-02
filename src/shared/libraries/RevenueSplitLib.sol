// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RevenueSplitLib
/// @notice Revenue split used across all instance types. Each collection snapshots its protocol fee and chooses
///         its alignment share at launch (see MiyaRegistry); the artist receives the rest.
library RevenueSplitLib {
    uint256 internal constant BPS = 10_000;

    struct Split {
        uint256 protocolCut;
        uint256 vaultCut;
        uint256 remainder;
    }

    /// @notice Split `amount` into protocol, vault and artist shares.
    /// @dev Both cuts round down; the remainder absorbs rounding dust. Callers guarantee
    ///      protocolBps + alignmentBps <= BPS (enforced by MiyaRegistry.checkAlignmentBps at launch).
    function split(uint256 amount, uint16 protocolBps, uint16 alignmentBps) internal pure returns (Split memory s) {
        s.protocolCut = (amount * protocolBps) / BPS;
        s.vaultCut = (amount * alignmentBps) / BPS;
        s.remainder = amount - s.protocolCut - s.vaultCut;
    }
}
