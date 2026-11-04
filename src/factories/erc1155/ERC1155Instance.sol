// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SmartTransferLib } from "../../libraries/SmartTransferLib.sol";
import {IDynamicPricingModule} from "./interfaces/IDynamicPricingModule.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import {IGatingModule, GatingScope} from "../../gating/IGatingModule.sol";

// ── Free mint errors ─────────────────────────────────────────────────────────
error FreeMintDisabled();
error FreeMintAlreadyClaimed();
error FreeMintExhausted();

// ── ERC1155Instance errors ───────────────────────────────────────────────────
error InvalidName();
error InvalidAddress();
error Unauthorized();
error AmountMustBePositive();
error EditionNotFound();
error EditionNotOpen();
error EditionSoldOut();
error ExceedsSupply();
error ExceedsMaxCost();
error InsufficientPayment();
error InsufficientBalance();
error InvalidTitle();
error InvalidPrice();
error UnlimitedMustHaveZeroSupply();
error LimitedMustHavePositiveSupply();
error DynamicPricingRequiresIncreaseRate();
error EditionLimitReached();
error NoFeesToClaim();
error NoPendingVaultCut();
error LengthMismatch();
error GatingCheckFailed();
error ERC1155RejectedTokens();
error NoDynamicPricingModule();
error OnlyFactory();
error AlreadyInitialized();
error InvalidSplit();
error RenounceDisabled();
import { Currency } from "v4-core/types/Currency.sol";
import { RevenueSplitLib } from "../../shared/libraries/RevenueSplitLib.sol";
import { IInstanceLifecycle, TYPE_ERC1155, STATE_MINTING } from "../../interfaces/IInstanceLifecycle.sol";

/**
 * @title ERC1155Instance
 * @notice ERC1155 token instance for open edition artists
 * @dev Supports unlimited/limited editions with fixed or dynamic pricing, mint messages, and a withdraw split
 *      (protocol / alignment vault / artist) whose terms are snapshotted at launch.
 */
// slither-disable-next-line missing-inheritance
contract ERC1155Instance is Ownable, ReentrancyGuard, IInstanceLifecycle {

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    enum PricingModel {
        UNLIMITED,      // Unlimited supply, fixed price
        LIMITED_FIXED,  // Limited supply, fixed price
        LIMITED_DYNAMIC // Limited supply, exponential price increase
    }

    /// @notice All addresses wired at construction. Passed as one struct to keep the
    ///         constructor under the stack-depth limit without via-ir.
    struct InstanceInit {
        address protocolTreasury;
        uint16 protocolFeeBps;    // snapshotted from MiyaRegistry at launch
        uint16 alignmentBps;      // chosen by the creator at launch
        address gatingModule;
        address dynamicPricingModule;
        address weth;
    }

    struct Edition {
        uint256 id;
        string pieceTitle;
        uint256 basePrice;        // Base price for dynamic pricing
        uint256 supply;           // 0 = unlimited
        uint256 minted;
        string metadataURI;
        PricingModel pricingModel;
        uint256 priceIncreaseRate; // For dynamic pricing (basis points, e.g., 100 = 1%)
        uint256 openTime;          // Unix timestamp; 0 = open immediately
    }

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string public name;
    // slither-disable-next-line immutable-states
    address public creator;
    // slither-disable-next-line immutable-states
    address public factory;
    IAlignmentVault public immutable vault;
    address public immutable protocolTreasury;
    /// @notice Protocol fee (bps) snapshotted at launch; never changes.
    uint16 public immutable protocolFeeBps;
    /// @notice Alignment vault share (bps) chosen at launch; never changes.
    uint16 public immutable alignmentBps;
    address public immutable weth;

    // Customization
    string public styleUri;

    mapping(uint256 => Edition) public editions;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // slither-disable-next-line immutable-states
    IGatingModule public gatingModule;
    // slither-disable-next-line immutable-states
    IDynamicPricingModule public dynamicPricingModule;

    // Free mint
    uint256 public freeMintAllocation;
    uint256 public freeMintsClaimed;
    mapping(address => bool) public freeMintClaimed;
    GatingScope public gatingScope;
    bool private _freeMintInitialized;

    uint256 public nextEditionId;
    uint256 public totalProceeds;  // Total ETH collected from mints
    uint256 public totalWithdrawn; // Total ETH passed to withdraw() (prevents double-withdrawal and force-feed attacks)
    /// @dev INVARIANT: pendingVaultCut <= address(this).balance at all times.
    ///      Failed vault contributions stay in the contract, tracked here so they
    ///      cannot be re-withdrawn as artist proceeds.
    uint256 public pendingVaultCut;

    // Events
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    event ApprovalForAll(
        address indexed account,
        address indexed operator,
        bool approved
    );

    event EditionAdded(
        uint256 indexed editionId,
        string pieceTitle,
        uint256 basePrice,
        uint256 supply,
        PricingModel pricingModel
    );

    event Minted(
        address indexed to,
        uint256 indexed editionId,
        uint256 amount,
        uint256 totalCost
    );

    event MintMessage(address indexed minter, uint256 indexed editionId, string message);

    event Withdrawn(
        address indexed creator,
        uint256 artistAmount,
        uint256 vaultCut,
        uint256 protocolCut
    );

    event VaultContributionFailed(address indexed vault, uint256 amount);
    event VaultContributionRetried(address indexed vault, uint256 amount);

    event EditionMetadataUpdated(uint256 indexed editionId, string metadataURI);
    /// @dev ERC-1155 metadata event, which marketplaces index.
    event URI(string value, uint256 indexed id);
    event FreeMintClaimed(address indexed user, uint256 indexed editionId);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(
        string memory _name,
        address _creator,
        address _factory,
        address _vault,
        string memory _styleUri,
        InstanceInit memory _init
    ) {
        if (bytes(_name).length == 0) revert InvalidName();
        if (_creator == address(0)) revert InvalidAddress();
        if (_factory == address(0)) revert InvalidAddress();
        if (_vault == address(0)) revert InvalidAddress();
        if (uint256(_init.protocolFeeBps) + _init.alignmentBps > RevenueSplitLib.BPS) revert InvalidSplit();

        _initializeOwner(_creator);
        name = _name;
        creator = _creator;
        factory = _factory;
        vault = IAlignmentVault(payable(_vault));
        protocolTreasury = _init.protocolTreasury;
        protocolFeeBps = _init.protocolFeeBps;
        alignmentBps = _init.alignmentBps;
        weth = _init.weth;
        styleUri = _styleUri;
        nextEditionId = 1;
        if (_init.gatingModule != address(0)) {
            gatingModule = IGatingModule(_init.gatingModule);
        }
        if (_init.dynamicPricingModule != address(0)) {
            dynamicPricingModule = IDynamicPricingModule(_init.dynamicPricingModule);
        }
        emit StateChanged(STATE_MINTING);
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC1155;
    }

    // ── Free mint ─────────────────────────────────────────────────────────────

    /// @notice Set free mint params. Called by factory once after construction.
    // slither-disable-next-line events-maths
    function initializeFreeMint(uint256 allocation, GatingScope scope) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_freeMintInitialized) revert AlreadyInitialized();
        _freeMintInitialized = true;
        freeMintAllocation = allocation;
        gatingScope = scope;
    }

    /// @notice Claim one free token of a specified edition at zero ETH cost.
    /// @param editionId  The edition to claim from. Must exist.
    /// @param gatingData Passed to gatingModule.canMint if scope requires it.
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth,unused-return
    function claimFreeMint(uint256 editionId, bytes calldata gatingData) external nonReentrant {
        if (freeMintAllocation == 0) revert FreeMintDisabled();
        if (freeMintClaimed[msg.sender]) revert FreeMintAlreadyClaimed();
        if (freeMintsClaimed >= freeMintAllocation) revert FreeMintExhausted();

        Edition storage edition = editions[editionId];
        if (bytes(edition.pieceTitle).length == 0) revert EditionNotFound();
        if (edition.openTime != 0) {
            if (block.timestamp < edition.openTime) revert EditionNotOpen();
        }
        if (edition.supply > 0) {
            if (edition.minted >= edition.supply) revert EditionSoldOut();
        }

        if (address(gatingModule) != address(0) && gatingScope != GatingScope.PAID_ONLY) {
            (bool allowed,) = gatingModule.canMint(msg.sender, 1, gatingData);
            if (!allowed) revert GatingCheckFailed();
            gatingModule.onMint(msg.sender, 1);
        }

        freeMintClaimed[msg.sender] = true;
        freeMintsClaimed++;
        edition.minted++;
        balanceOf[msg.sender][editionId]++;

        emit FreeMintClaimed(msg.sender, editionId);
        emit TransferSingle(msg.sender, address(0), msg.sender, editionId, 1);
    }

    // ┌─────────────────────────┐
    // │   Edition Management    │
    // └─────────────────────────┘

    /**
     * @notice Add a new edition
     * @param pieceTitle Title of the piece
     * @param basePrice Base price (for fixed) or starting price (for dynamic)
     * @param supply Supply limit (0 = unlimited)
     * @param metadataURI Metadata URI for the edition
     * @param pricingModel Pricing model (UNLIMITED, LIMITED_FIXED, LIMITED_DYNAMIC)
     * @param priceIncreaseRate Price increase rate in basis points (for dynamic pricing)
     */
    function addEdition(
        string memory pieceTitle,
        uint256 basePrice,
        uint256 supply,
        string memory metadataURI,
        PricingModel pricingModel,
        uint256 priceIncreaseRate,
        uint256 openTime           // NEW: Unix timestamp; 0 = open immediately
    ) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (bytes(pieceTitle).length == 0) revert InvalidTitle();
        if (basePrice == 0) revert InvalidPrice();

        if (pricingModel == PricingModel.UNLIMITED) {
            if (supply != 0) revert UnlimitedMustHaveZeroSupply();
        } else {
            if (supply == 0) revert LimitedMustHavePositiveSupply();
        }

        if (pricingModel == PricingModel.LIMITED_DYNAMIC) {
            if (address(dynamicPricingModule) == address(0)) revert NoDynamicPricingModule();
            if (priceIncreaseRate == 0) revert DynamicPricingRequiresIncreaseRate();
        }

        if (nextEditionId > type(uint32).max) revert EditionLimitReached();

        uint256 editionId = nextEditionId++;
        editions[editionId] = Edition({
            id: editionId,
            pieceTitle: pieceTitle,
            basePrice: basePrice,
            supply: supply,
            minted: 0,
            metadataURI: metadataURI,
            pricingModel: pricingModel,
            priceIncreaseRate: priceIncreaseRate,
            openTime: openTime      // NEW
        });

        emit EditionAdded(editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Update edition metadata
     * @param editionId Edition ID
     * @param metadataURI New metadata URI
     */
    function updateEditionMetadata(uint256 editionId, string memory metadataURI) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (editions[editionId].id == 0) revert EditionNotFound();

        editions[editionId].metadataURI = metadataURI;
        emit EditionMetadataUpdated(editionId, metadataURI);
        emit URI(metadataURI, editionId);
    }

    // ┌─────────────────────────┐
    // │   Pricing Functions    │
    // └─────────────────────────┘

    /**
     * @notice Get current price for an edition
     * @param editionId Edition ID
     * @return price Current price for the next mint
     */
    function getCurrentPrice(uint256 editionId) public view returns (uint256 price) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return edition.basePrice;
        } else {
            // LIMITED_DYNAMIC
            return dynamicPricingModule.calculatePrice(
                edition.basePrice,
                edition.priceIncreaseRate,
                edition.minted
            );
        }
    }

    /**
     * @notice Calculate total cost for minting multiple tokens
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @return totalCost Total cost for minting the amount
     */
    function calculateMintCost(uint256 editionId, uint256 amount) public view returns (uint256 totalCost) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        if (amount == 0) revert AmountMustBePositive();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return edition.basePrice * amount;
        } else {
            // LIMITED_DYNAMIC
            return dynamicPricingModule.calculateBatchCost(
                edition.basePrice,
                edition.priceIncreaseRate,
                edition.minted,
                amount
            );
        }
    }

    // ┌─────────────────────────┐
    // │    Minting Functions    │
    // └─────────────────────────┘

    /**
     * @notice Mint tokens with optional message
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @param message Optional message shown alongside the mint (empty string emits nothing)
     * @param maxCost Maximum acceptable total cost (0 = no limit, uses msg.value as implicit cap)
     */
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth,timestamp,unused-return
    function mint(
        uint256 editionId,
        uint256 amount,
        bytes32 gatingData,        // NEW: password hash (bytes32(0) = open tier)
        string calldata message,
        uint256 maxCost
    ) external payable nonReentrant {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        if (amount == 0) revert AmountMustBePositive();

        // Time gate check
        if (edition.openTime != 0) {
            if (block.timestamp < edition.openTime) revert EditionNotOpen();
        }

        // Gating check — forwards edition's openTime as the time reference
        if (address(gatingModule) != address(0)) {
            bytes memory encoded = abi.encode(gatingData, edition.openTime);
            (bool allowed,) = gatingModule.canMint(msg.sender, amount, encoded);
            if (!allowed) revert GatingCheckFailed();
            gatingModule.onMint(msg.sender, amount);
        }

        // Check supply limits
        if (edition.pricingModel != PricingModel.UNLIMITED) {
            if (edition.minted + amount > edition.supply) revert ExceedsSupply();
        }

        // Calculate cost
        uint256 totalCost = calculateMintCost(editionId, amount);
        if (maxCost != 0 && totalCost > maxCost) revert ExceedsMaxCost();
        if (msg.value < totalCost) revert InsufficientPayment();

        // Update edition state
        edition.minted += amount;
        balanceOf[msg.sender][editionId] += amount;
        totalProceeds += totalCost;

        // Refund excess
        if (msg.value > totalCost) {
            SmartTransferLib.smartTransferETH(msg.sender, msg.value - totalCost, weth);
        }

        emit TransferSingle(msg.sender, address(0), msg.sender, editionId, amount);
        emit Minted(msg.sender, editionId, amount, totalCost);
        if (bytes(message).length > 0) emit MintMessage(msg.sender, editionId, message);
    }

    // ┌─────────────────────────┐
    // │   Withdraw Functions    │
    // └─────────────────────────┘

    /**
     * @notice Withdraw proceeds, split between protocol treasury, alignment vault and artist
     * @dev Uses the protocolFeeBps / alignmentBps snapshotted at launch; the artist gets the remainder.
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountMustBePositive();
        // Use proceeds accounting to prevent force-fed ETH from bypassing the split
        if (amount > totalProceeds - totalWithdrawn) revert InsufficientBalance();
        totalWithdrawn += amount;

        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, protocolFeeBps, alignmentBps);

        // Protocol cut to treasury
        if (s.protocolCut > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, s.protocolCut);
        }

        // Vault cut — tracks this instance as benefactor
        // If the vault reverts (e.g. broken upgrade), accumulate for retry rather than
        // blocking creator proceeds permanently.
        // Parked cuts go with this one, so small ones add up past the vault's minimum.
        uint256 cut = s.vaultCut + pendingVaultCut;
        uint256 vaultCutSent;
        if (cut > 0) {
            pendingVaultCut = 0;
            try vault.receiveContribution{value: cut}(Currency.wrap(address(0)), cut, address(this)) {
                vaultCutSent = cut;
            } catch {
                pendingVaultCut = cut;
                emit VaultContributionFailed(address(vault), cut);
            }
        }

        // Transfer remainder to artist
        SmartTransferLib.smartTransferETH(owner(), s.remainder, weth);

        emit Withdrawn(owner(), s.remainder, vaultCutSent, s.protocolCut);
    }

    /**
     * @notice Retry sending any accumulated failed vault contributions.
     * @dev Permissionless — anyone can call once the vault is restored.
     */
    function retryVaultContribution() external nonReentrant {
        uint256 pending = pendingVaultCut;
        if (pending == 0) revert NoPendingVaultCut();
        pendingVaultCut = 0;
        vault.receiveContribution{value: pending}(Currency.wrap(address(0)), pending, address(this));
        emit VaultContributionRetried(address(vault), pending);
    }

    /**
     * @notice Claim accumulated vault fees on behalf of this project and distribute to creator
     * @dev Only callable by the project creator
     *      This instance was registered as the benefactor when tithes were sent to the vault
     *      The creator calls this to claim fees and keep the rewards
     * @dev Vault contributions (via withdraw) wait in the vault's open batch and earn shares when the keeper next
     *      converts. Fees can only be claimed after that.
     * @return totalClaimed Amount of ETH claimed from vault
     */
    function claimVaultFees() external onlyOwner nonReentrant returns (uint256 totalClaimed) {
        // Call vault's claimFees, which uses msg.sender (this contract) as the benefactor
        totalClaimed = vault.claimFees();

        // Route all claimed fees to the owner
        if (totalClaimed == 0) revert NoFeesToClaim();
        SmartTransferLib.smartTransferETH(owner(), totalClaimed, weth);
    }

    /// @notice Claim accumulated fees from this instance's vault (fixed at launch) and forward them to the owner.
    /// @dev With a single fixed vault this is equivalent to claimVaultFees(); kept for IFactoryInstance.
    function claimAllFees() external onlyOwner nonReentrant {
        uint256 claimed = vault.claimFees();
        if (claimed > 0) SmartTransferLib.smartTransferETH(owner(), claimed, weth);
    }

    /// @notice Accept ETH from the vault when it pays out claimed fees (UniAlignmentVault.claimFees pays the
    ///         benefactor with a plain call). Such ETH is never counted in totalProceeds or pendingVaultCut,
    ///         so withdraw() cannot route it through the revenue split; claimVaultFees() forwards it to the owner.
    receive() external payable {}

    // ┌─────────────────────────┐
    // │   ERC1155 Functions    │
    // └─────────────────────────┘

    /**
     * @notice Transfer tokens
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert Unauthorized();
        if (to == address(0)) revert InvalidAddress();
        if (balanceOf[from][id] < amount) revert InsufficientBalance();

        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);

        /// @dev ERC1155 compliance: Check if recipient is a contract and call receiver hook
        _doSafeTransferAcceptanceCheck(msg.sender, from, to, id, amount, data);
    }

    /**
     * @notice Batch transfer tokens
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert Unauthorized();
        if (to == address(0)) revert InvalidAddress();
        if (ids.length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < ids.length; i++) {
            if (balanceOf[from][ids[i]] < amounts[i]) revert InsufficientBalance();
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        /// @dev ERC1155 compliance: Check if recipient is a contract and call receiver hook
        _doSafeBatchTransferAcceptanceCheck(msg.sender, from, to, ids, amounts, data);
    }

    /**
     * @notice ERC1155 batch balance query
     * @param accounts Owners to query
     * @param ids Token ids to query (same length as accounts)
     */
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory balances)
    {
        if (accounts.length != ids.length) revert LengthMismatch();
        balances = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            balances[i] = balanceOf[accounts[i]][ids[i]];
        }
    }

    /**
     * @notice ERC165: ERC165, ERC1155 and ERC1155MetadataURI
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0xd9b67a26 // ERC1155
            || interfaceId == 0x0e89341c; // ERC1155MetadataURI
    }

    /**
     * @notice ERC1155MetadataURI: metadata URI of an edition
     * @param id Edition ID
     */
    function uri(uint256 id) external view returns (string memory) {
        Edition storage edition = editions[id];
        if (edition.id == 0) revert EditionNotFound();
        return edition.metadataURI;
    }

    /**
     * @notice Set approval for all
     */
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // ┌─────────────────────────┐
    // │   Metadata Functions    │
    // └─────────────────────────┘

    /**
     * @notice Get all edition IDs
     * @return editionIds Array of all edition IDs
     */
    function getAllEditionIds() external view returns (uint256[] memory editionIds) {
        uint256 count = nextEditionId - 1;
        editionIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            editionIds[i] = i + 1;
        }
    }

    /**
     * @notice Get edition count
     * @return count Total number of editions
     */
    function getEditionCount() external view returns (uint256 count) {
        return nextEditionId - 1;
    }

    /**
     * @notice Get full edition details
     * @param editionId Edition ID
     * @return Edition struct containing all edition details
     */
    function getEdition(uint256 editionId) external view returns (Edition memory) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        return edition;
    }


    // ┌─────────────────────────┐
    // │   Style Management      │
    // └─────────────────────────┘

    /// @notice Disabled: the artist's share of every withdraw is sent to owner(), so renouncing would burn it.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Set project-level style URI (creator only)
    function setStyle(string memory uri) external {
        if (msg.sender != owner()) revert Unauthorized();
        styleUri = uri;
    }

    // ┌─────────────────────────────────────┐
    // │   ERC1155 Receiver Safety Checks    │
    // └─────────────────────────────────────┘

    /**
     * @dev Internal function to invoke onERC1155Received on a target address
     * @param operator The address which initiated the transfer
     * @param from The address which previously owned the token
     * @param to The address which will own the token
     * @param id The token ID being transferred
     * @param amount The amount of tokens being transferred
     * @param data Additional data with no specified format
     */
    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeCall(IERC1155Receiver.onERC1155Received, (operator, from, id, amount, data))
            );
            if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != IERC1155Receiver.onERC1155Received.selector) {
                revert ERC1155RejectedTokens();
            }
        }
    }

    /**
     * @dev Internal function to invoke onERC1155BatchReceived on a target address
     * @param operator The address which initiated the batch transfer
     * @param from The address which previously owned the tokens
     * @param to The address which will own the tokens
     * @param ids Array of token IDs being transferred
     * @param amounts Array of amounts being transferred
     * @param data Additional data with no specified format
     */
    function _doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeCall(IERC1155Receiver.onERC1155BatchReceived, (operator, from, ids, amounts, data))
            );
            if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != IERC1155Receiver.onERC1155BatchReceived.selector) {
                revert ERC1155RejectedTokens();
            }
        }
    }
}

/**
 * @title IERC1155Receiver
 * @dev Interface for contracts that want to support safe transfers from ERC1155 token contracts
 */
interface IERC1155Receiver {
    /**
     * @notice Handle the receipt of a single ERC1155 token type
     * @param operator The address which initiated the transfer
     * @param from The address which previously owned the token
     * @param id The ID of the token being transferred
     * @param value The amount of tokens being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);

    /**
     * @notice Handle the receipt of multiple ERC1155 token types
     * @param operator The address which initiated the batch transfer
     * @param from The address which previously owned the tokens
     * @param ids An array containing ids of each token being transferred
     * @param values An array containing amounts of each token being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}

