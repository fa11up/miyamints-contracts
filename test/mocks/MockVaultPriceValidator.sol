// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";

/// @notice Mock price validator for unit tests. Always passes validation.
contract MockVaultPriceValidator is IVaultPriceValidator {
    bool public shouldRevert;
    uint256 public fixedProportion = 5e17; // 50% default

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setFixedProportion(uint256 _proportion) external {
        fixedProportion = _proportion;
    }

    function validatePrice(address, uint256) external view override {
        require(!shouldRevert, "MockPriceValidator: forced revert");
    }

    function calculateSwapProportion(
        address, int24, int24, address, bytes32
    ) external view override returns (uint256) {
        return fixedProportion;
    }

    // Returns 0 by default so existing tests are unaffected (no token fees collected in mocks).
    function quoteEthForTokens(address, uint256) external pure override returns (uint256) {
        return 0;
    }
}
