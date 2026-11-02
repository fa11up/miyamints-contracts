// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IComponentModule} from "../../src/interfaces/IComponentModule.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @notice Minimal IComponentModule implementation for testnet / local seeding.
///         Stores a metadata URI so the frontend creation wizard can discover and display it.
///         Not a functional module — do not use as a liquidity deployer or gating module on mainnet.
contract MockComponentModule is IComponentModule, Ownable {
    string private _metadataURI;

    constructor(address owner_, string memory uri_) {
        _initializeOwner(owner_);
        _metadataURI = uri_;
    }

    function metadataURI() external view returns (string memory) {
        return _metadataURI;
    }

    function setMetadataURI(string calldata uri) external onlyOwner {
        _metadataURI = uri;
        emit MetadataURIUpdated(uri);
    }
}
