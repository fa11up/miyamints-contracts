// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMiyaRegistry } from "../../registry/interfaces/IMiyaRegistry.sol";
import { ERC721DropInstance } from "./ERC721DropInstance.sol";

/**
 * @title ERC721DropFactory
 * @notice Deploys fixed-price ERC721 drops. Each drop snapshots the registry's protocol fee and the creator's
 *         chosen alignment share (at least the registry minimum) at launch, and must use a vault registered in
 *         MiyaRegistry. Ownerless: nothing here can be changed after deployment.
 */
contract ERC721DropFactory {
    IMiyaRegistry public immutable registry;
    address public immutable weth;

    event DropCreated(
        address indexed drop, address indexed creator, address indexed vault, uint16 protocolBps, uint16 alignmentBps
    );

    error InvalidVault();
    error InvalidAddress();

    constructor(IMiyaRegistry registry_, address weth_) {
        if (address(registry_) == address(0)) revert InvalidAddress();
        registry = registry_;
        weth = weth_;
    }

    function createDrop(ERC721DropInstance.InitParams calldata params, address vault, uint16 alignmentBps)
        external
        returns (address drop)
    {
        if (!registry.isVault(vault)) revert InvalidVault();
        registry.checkAlignmentBps(alignmentBps);
        uint16 protocolBps = registry.protocolFeeBps();
        drop = address(
            new ERC721DropInstance(params, msg.sender, registry.treasury(), vault, weth, protocolBps, alignmentBps)
        );
        registry.registerInstance(drop, vault, msg.sender);
        emit DropCreated(drop, msg.sender, vault, protocolBps, alignmentBps);
    }
}
