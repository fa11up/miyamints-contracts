// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";
import {ERC1155Instance} from "./ERC1155Instance.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/**
 * @title ERC1155Factory
 * @notice Deploys ERC1155 edition instances and registers them in the MiyaRegistry.
 *         Single responsibility: validate → deploy via CREATE3 → register.
 *         Each instance snapshots the registry's treasury and protocol fee plus the creator's chosen
 *         alignment share at launch. Any creation fee is forwarded to the registry treasury — no custody.
 */
contract ERC1155Factory is Ownable, ReentrancyGuard, IFactory {
    error InvalidAddress();
    error UnapprovedComponent();
    error InvalidName();
    error InvalidVault();
    error NotCreator();

    /// @notice Component tag categories (keccak256 of the tag name).
    bytes32 public constant GATING = keccak256("gating");
    bytes32 public constant DYNAMIC_PRICING = keccak256("dynamic_pricing");

    IMiyaRegistry public immutable registry;
    address public weth;
    address public dynamicPricingModule;

    /// @notice Parameters for instance creation. Defined here — not in shared IFactoryTypes —
    ///         because CreateParams is specific to this factory type.
    struct CreateParams {
        string name;
        string metadataURI;
        address creator;
        address vault;
        uint16 alignmentBps;     // vault share; registry-enforced minimum, artist gets the remainder
        string styleUri;
        address gatingModule;    // address(0) = open
        FreeMintParams freeMint;
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

    constructor(IMiyaRegistry _registry, address _weth) {
        if (address(_registry) == address(0)) revert InvalidAddress();
        _initializeOwner(msg.sender);
        registry = _registry;
        weth = _weth;
    }

    /// @notice Deploy a new ERC1155 instance. Any ETH is forwarded directly to the registry treasury.
    function createInstance(
        bytes32 salt,
        CreateParams calldata params
    ) external payable nonReentrant returns (address instance) {
        if (params.gatingModule != address(0)) {
            if (!registry.isApprovedComponent(params.gatingModule)) revert UnapprovedComponent();
        }
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

        instance = ICreateX(CREATEX).deployCreate3(salt, _buildInitCode(params, treasury, protocolFeeBps));
        ERC1155Instance(payable(instance)).initializeFreeMint(params.freeMint.allocation, params.freeMint.scope);
        registry.registerInstance(instance, params.vault, params.creator);

        emit InstanceCreated(
            instance, params.creator, params.name, params.vault, params.metadataURI, protocolFeeBps, params.alignmentBps
        );
    }

    /// @dev Isolated so that the large abi.encode runs in a fresh stack frame.
    function _buildInitCode(CreateParams calldata params, address treasury, uint16 protocolFeeBps)
        private
        view
        returns (bytes memory)
    {
        ERC1155Instance.InstanceInit memory init = ERC1155Instance.InstanceInit({
            protocolTreasury: treasury,
            protocolFeeBps: protocolFeeBps,
            alignmentBps: params.alignmentBps,
            gatingModule: params.gatingModule,
            dynamicPricingModule: dynamicPricingModule,
            weth: weth
        });
        return abi.encodePacked(
            type(ERC1155Instance).creationCode,
            abi.encode(params.name, params.creator, address(this), params.vault, params.styleUri, init)
        );
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Set the default dynamic pricing module for new instances.
    ///         address(0) disables dynamic pricing for new deployments.
    function setDynamicPricingModule(address module) external onlyOwner {
        if (module != address(0)) {
            if (!registry.isApprovedComponent(module)) revert UnapprovedComponent();
        }
        dynamicPricingModule = module;
    }

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    // ── IFactory ─────────────────────────────────────────────────────────────

    function protocol() external view returns (address) {
        return owner();
    }

    /// @notice Returns supported component feature tags.
    ///         DYNAMIC_PRICING included lazily when a module is set.
    function features() external view returns (bytes32[] memory f) {
        if (dynamicPricingModule != address(0)) {
            f = new bytes32[](2);
            f[0] = GATING;
            f[1] = DYNAMIC_PRICING;
        } else {
            f = new bytes32[](1);
            f[0] = GATING;
        }
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
