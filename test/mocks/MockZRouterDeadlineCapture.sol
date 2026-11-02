// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ZRouter mock that captures the last deadline argument (Finding 6).
///         Reads all data from calldata via assembly to avoid Yul stack-too-deep (via_ir=true).
contract MockZRouterDeadlineCapture {
    // slot 0
    uint256 public lastDeadline;
    // slot 1
    uint256 public outRatio;

    constructor() { outRatio = 1e18; }

    receive() external payable {}

    function setOutRatio(uint256 ratio) external { outRatio = ratio; }

    /// @notice Catches any swapVZ call, records the deadline, returns (swapAmount, swapAmount).
    ///         ABI layout for swapVZ(address,bool,uint256,address,address,uint256,uint256,uint256,uint256,uint256):
    ///           4 + 0*32  = 0x04  arg0 (to)
    ///           4 + 7*32  = 0xe4  arg7 (swapAmount)
    ///           4 + 9*32  = 0x124 arg9 (deadline)
    fallback() external payable {
        assembly {
            // slot 0 = lastDeadline — store deadline (arg9)
            sstore(0, calldataload(0x124))
            // return (swapAmount, swapAmount) — arg7 repeated
            let amt := calldataload(0xe4)
            mstore(0x00, amt)
            mstore(0x20, amt)
            return(0x00, 0x40)
        }
    }
}
