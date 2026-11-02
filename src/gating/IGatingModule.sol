// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IComponentModule} from "../interfaces/IComponentModule.sol";

/// @notice Controls which entry points the gating module is consulted for.
/// Set once at instance creation. Irreversible.
enum GatingScope {
    BOTH,            // gates free mint claims AND paid buys (default)
    FREE_MINT_ONLY,  // gates free mint claims only; paid buys are open
    PAID_ONLY        // gates paid buys only; free mint claims are open FCFS
}

/// @notice Pluggable gating interface for ms2.fun instances (ERC404 and ERC1155).
/// address(0) means open gating — no module deployed.
/// Implementations are approved in MiyaRegistry (setComponent); factory feature tag keccak256("gating").
interface IGatingModule is IComponentModule {
    /// @notice Returns (allowed, permanent).
    ///         When permanent == true, the caller MUST set gatingActive = false —
    ///         this module guarantees it will never block again.
    /// @param user    The buyer address.
    /// @param amount  Token amount (not NFT count).
    /// @param data    Arbitrary data — password hash, merkle proof, etc.
    function canMint(address user, uint256 amount, bytes calldata data)
        external returns (bool allowed, bool permanent);

    /// @notice Record a successful mint. Called by instance after canMint passes.
    /// @param user   The buyer address.
    /// @param amount Token amount minted.
    function onMint(address user, uint256 amount) external;
}
