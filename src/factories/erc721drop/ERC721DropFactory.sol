// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMiyaRegistry } from "../../registry/interfaces/IMiyaRegistry.sol";
import { ERC721DropInstance } from "./ERC721DropInstance.sol";
import { InitCodeStore } from "../shared/InitCodeStore.sol";

/**
 * @title ERC721DropFactory
 * @notice Deploys fixed-price ERC721 drops. Each drop snapshots the registry's protocol fee and the creator's
 *         chosen alignment share (at least the registry minimum) at launch, and must use a vault registered in
 *         MiyaRegistry. Each accepted payment token must be on the registry's payment-token allowlist (the drop
 *         checks it at creation, in setAcceptedTokens and at every mint). Ownerless: nothing here can be changed
 *         after deployment.
 */
contract ERC721DropFactory {
    IMiyaRegistry public immutable registry;
    address public immutable weth;
    /// @dev ERC721DropInstance creation code, in SSTORE2 data contracts (see InitCodeStore).
    address internal immutable _codeA;
    address internal immutable _codeB;

    event DropCreated(
        address indexed drop, address indexed creator, address indexed vault, uint16 protocolBps, uint16 alignmentBps
    );

    error InvalidVault();
    error InvalidAddress();

    constructor(IMiyaRegistry registry_, address weth_) {
        if (address(registry_) == address(0)) revert InvalidAddress();
        registry = registry_;
        weth = weth_;
        (_codeA, _codeB) = InitCodeStore.write(type(ERC721DropInstance).creationCode);
    }

    function createDrop(ERC721DropInstance.InitParams calldata params, address vault, uint16 alignmentBps)
        external
        returns (address drop)
    {
        if (!registry.isVault(vault)) revert InvalidVault();
        registry.checkAlignmentBps(alignmentBps);
        uint16 protocolBps = registry.protocolFeeBps();
        bytes memory initCode = abi.encodePacked(
            InitCodeStore.read(_codeA, _codeB),
            abi.encode(params, msg.sender, registry.treasury(), vault, address(registry), weth, protocolBps, alignmentBps)
        );
        assembly ("memory-safe") {
            drop := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(drop) {
                // Bubble the constructor's revert reason, as `new` would.
                let m := mload(0x40)
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
        registry.registerInstance(drop, vault, msg.sender);
        emit DropCreated(drop, msg.sender, vault, protocolBps, alignmentBps);
    }
}
