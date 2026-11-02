// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";
import {ERC721AuctionInstance} from "./ERC721AuctionInstance.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/**
 * @title ERC721AuctionFactory
 * @notice Deploys ERC721 auction instances for 1/1 artists and registers them in the MiyaRegistry.
 *         Single responsibility: validate → deploy via CREATE3 → register.
 *         Each instance snapshots the registry's treasury and protocol fee plus the creator's chosen
 *         alignment share at launch. Any creation fee is forwarded to the registry treasury — no custody.
 */
contract ERC721AuctionFactory is Ownable, ReentrancyGuard, IFactory {
    error InvalidAddress();
    error InvalidName();
    error InvalidVault();
    error NotCreator();

    IMiyaRegistry public immutable registry;
    address public weth;

    struct CreateParams {
        string name;
        string metadataURI;
        address creator;
        address vault;
        uint16 alignmentBps;     // vault share; registry-enforced minimum, artist gets the remainder
        string symbol;
        uint8 lines;
        uint40 baseDuration;
        uint40 timeBuffer;
        uint256 bidIncrement;
    }

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        address indexed vault,
        string metadataURI,
        uint16 protocolFeeBps,
        uint16 alignmentBps
    );
    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);

    constructor(IMiyaRegistry _registry, address _weth) {
        if (address(_registry) == address(0)) revert InvalidAddress();
        _initializeOwner(msg.sender);
        registry = _registry;
        weth = _weth;
    }

    /// @notice Deploy a new ERC721 auction instance. Any ETH is forwarded directly to the registry treasury.
    function createInstance(
        bytes32 salt,
        CreateParams calldata params
    ) external payable nonReentrant returns (address instance) {
        registry.checkAlignmentBps(params.alignmentBps);

        if (bytes(params.name).length == 0) revert InvalidName();
        if (params.creator == address(0)) revert InvalidAddress();
        if (msg.sender != params.creator) revert NotCreator();
        if (params.vault == address(0)) revert InvalidAddress();
        if (!registry.isVault(params.vault)) revert InvalidVault();

        address treasury = registry.treasury();
        uint16 protocolFeeBps = registry.protocolFeeBps();

        // Forward fee directly to treasury — factory holds no ETH
        if (msg.value > 0) SafeTransferLib.safeTransferETH(treasury, msg.value);

        // Soft vault capability check
        try IAlignmentVault(payable(params.vault)).supportsCapability(keccak256("YIELD_GENERATION"))
            returns (bool supported) {
            if (!supported) emit VaultCapabilityWarning(params.vault, keccak256("YIELD_GENERATION"));
        } catch {
            emit VaultCapabilityWarning(params.vault, keccak256("YIELD_GENERATION"));
        }

        instance = _deployInstance(salt, params, treasury, protocolFeeBps);
        registry.registerInstance(instance, params.vault, params.creator);

        emit InstanceCreated(
            instance, params.creator, params.name, params.vault, params.metadataURI, protocolFeeBps, params.alignmentBps
        );
    }

    function _deployInstance(bytes32 salt, CreateParams calldata params, address treasury, uint16 protocolFeeBps)
        private
        returns (address instance)
    {
        bytes memory initCode = abi.encodePacked(
            type(ERC721AuctionInstance).creationCode,
            abi.encode(
                ERC721AuctionInstance.ConstructorParams({
                    vault: params.vault,
                    protocolTreasury: treasury,
                    protocolFeeBps: protocolFeeBps,
                    alignmentBps: params.alignmentBps,
                    owner: params.creator,
                    name: params.name,
                    symbol: params.symbol,
                    lines: params.lines,
                    baseDuration: params.baseDuration,
                    timeBuffer: params.timeBuffer,
                    bidIncrement: params.bidIncrement,
                    factory: address(this),
                    weth: weth
                })
            )
        );
        instance = ICreateX(CREATEX).deployCreate3(salt, initCode);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    // ── IFactory ─────────────────────────────────────────────────────────────

    function protocol() external view returns (address) {
        return owner();
    }

    function features() external view returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function requiredFeatures() external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // ── Utilities ────────────────────────────────────────────────────────────

    /// @notice Preview the deterministic address for a given salt.
    function computeInstanceAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
