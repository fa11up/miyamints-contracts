// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GatingScope} from "../gating/IGatingModule.sol";

/// @notice Free mint configuration passed to factory at instance creation.
struct FreeMintParams {
    uint256 allocation; // NFT count reserved for zero-cost claims (0 = disabled)
    GatingScope scope;  // which entry points the gating module guards
}


