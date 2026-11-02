// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IComponentModule} from "../../../interfaces/IComponentModule.sol";

/// @notice Pluggable exponential pricing module for ERC1155 LIMITED_DYNAMIC editions.
/// @dev Implementations approved in MiyaRegistry (setComponent); factory feature tag keccak256("dynamic_pricing").
///      Both functions are pure — no state reads. Acts as a deployed math library.
interface IDynamicPricingModule is IComponentModule {
    error PriceCalculationError();

    /// @notice Current price for the next single mint.
    /// @param basePrice      Starting price in wei.
    /// @param priceIncreaseRate  Basis-point rate per mint (e.g. 100 = 1%).
    /// @param minted         Number already minted before this call.
    function calculatePrice(
        uint256 basePrice,
        uint256 priceIncreaseRate,
        uint256 minted
    ) external pure returns (uint256);

    /// @notice Total cost to mint `amount` tokens starting at `startMinted`.
    /// @param basePrice          Starting price in wei.
    /// @param priceIncreaseRate  Basis-point rate per mint.
    /// @param startMinted        Tokens already minted before this batch.
    /// @param amount             Number of tokens in this batch.
    function calculateBatchCost(
        uint256 basePrice,
        uint256 priceIncreaseRate,
        uint256 startMinted,
        uint256 amount
    ) external pure returns (uint256);
}
