// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IInstance
/// @notice Common interface for instance card data across all factory types
/// @dev Implemented by ERC404BondingInstance, ERC1155Instance, and future instance types
interface IInstance {
    /// @notice Returns data needed for project card display
    /// @dev The meaning of each field may vary by factory type:
    ///      - ERC404: price = bonding curve price, supply = bonding supply, maxSupply = maxSupply
    ///      - ERC1155: price = floor price across editions, supply = total minted, maxSupply = sum of limited supplies (0 if any unlimited)
    /// @return price Current price (bonding price or floor price)
    /// @return supply Current supply (bonding supply or total minted)
    /// @return maxSupply Maximum supply (0 if unlimited)
    /// @return isActive Whether project is currently active/mintable
    /// @return extraData Factory-specific encoded data (decode based on contractType)
    function getCardData() external view returns (
        uint256 price,
        uint256 supply,
        uint256 maxSupply,
        bool isActive,
        bytes memory extraData
    );
}
