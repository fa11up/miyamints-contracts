// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SmartTransferLib } from "../../libraries/SmartTransferLib.sol";
import { PaymentLib } from "../../libraries/PaymentLib.sol";
import {IDynamicPricingModule} from "./interfaces/IDynamicPricingModule.sol";
import { IAlignmentVault, ClaimMode } from "../../interfaces/IAlignmentVault.sol";
import { TokenPrice } from "../interfaces/TokenPrice.sol";
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
error LengthMismatch();
error GatingCheckFailed();
error ERC1155RejectedTokens();
error NoDynamicPricingModule();
error OnlyFactory();
error AlreadyInitialized();
error InvalidSplit();
error RenounceDisabled();
error TokenNotPriced();
error WrongPayment();
import { RevenueSplitLib } from "../../shared/libraries/RevenueSplitLib.sol";
import { IInstanceLifecycle, TYPE_ERC1155, STATE_MINTING } from "../../interfaces/IInstanceLifecycle.sol";

/**
 * @title ERC1155Instance
 * @notice ERC1155 token instance for open edition artists
 * @dev Supports unlimited/limited editions with fixed or dynamic pricing, mint messages, and a split
 *      (protocol / alignment vault / artist) whose terms are snapshotted at launch.
 *
 *      Payment tokens: the owner keeps an `acceptedTokens` list (each on the registry allowlist; address(0) = ETH)
 *      and each edition carries a base price per token. A LIMITED_DYNAMIC edition's price in every token rises by
 *      the same rule. Proceeds are kept per token, as paid; the permissionless `distribute(token)` splits them and
 *      only the owner withdraws its share (`withdraw(token)`, `withdrawAll()`).
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
        address registry;          // payment-token allowlist
        address[] acceptedTokens;  // address(0) = ETH
    }

    struct Edition {
        uint256 id;
        string pieceTitle;
        uint256 supply;           // 0 = unlimited
        uint256 minted;
        string metadataURI;
        PricingModel pricingModel;
        uint256 priceIncreaseRate; // For dynamic pricing (basis points, e.g., 100 = 1%)
        uint256 openTime;          // Unix timestamp; 0 = open immediately
        TokenPrice[] prices;       // base price in each token the edition sells for (dynamic: the first mint's price)
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
    /// @notice The registry whose payment-token allowlist this collection checks.
    address public immutable registry;
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
    /// @dev Per-token accounting (PaymentLib). INVARIANT: for every token, the balance held >= what is owed.
    PaymentLib.Ledger internal _pay;
    /// @notice Total sale proceeds ever collected, per token.
    mapping(address token => uint256) public totalProceeds;

    // Events
    /// @notice withdrawAll skipped `token`: its split or payout reverted. Withdraw it on its own to see why.
    event WithdrawSkipped(address indexed token);
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
        TokenPrice[] prices,
        uint256 supply,
        PricingModel pricingModel
    );
    event EditionPricesSet(uint256 indexed editionId, TokenPrice[] prices);

    event Minted(
        address indexed to,
        uint256 indexed editionId,
        uint256 amount,
        address token,
        uint256 totalCost
    );

    event MintMessage(address indexed minter, uint256 indexed editionId, string message);


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
        if (_init.registry == address(0)) revert InvalidAddress();

        _initializeOwner(_creator);
        name = _name;
        creator = _creator;
        factory = _factory;
        vault = IAlignmentVault(payable(_vault));
        registry = _init.registry;
        PaymentLib.setAccepted(_pay, _init.registry, _init.acceptedTokens);
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
    /// @param gatingData abi.encode(bytes32 passwordHash), or empty for the open tier, used if scope requires it. As in
    ///        mint(), the module gets the edition's openTime from here: a caller's value could skip a time lock.
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
            bytes32 passwordHash = gatingData.length == 0 ? bytes32(0) : abi.decode(gatingData, (bytes32));
            (bool allowed,) = gatingModule.canMint(msg.sender, 1, abi.encode(passwordHash, edition.openTime));
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
     * @param prices Base price per accepted token (for fixed) or starting price (for dynamic); each must be > 0
     * @param supply Supply limit (0 = unlimited)
     * @param metadataURI Metadata URI for the edition
     * @param pricingModel Pricing model (UNLIMITED, LIMITED_FIXED, LIMITED_DYNAMIC)
     * @param priceIncreaseRate Price increase rate in basis points (for dynamic pricing; applies to every token)
     */
    function addEdition(
        string memory pieceTitle,
        TokenPrice[] memory prices,
        uint256 supply,
        string memory metadataURI,
        PricingModel pricingModel,
        uint256 priceIncreaseRate,
        uint256 openTime           // Unix timestamp; 0 = open immediately
    ) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (bytes(pieceTitle).length == 0) revert InvalidTitle();
        PaymentLib.checkPrices(_pay, prices, false);

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
        Edition storage e = editions[editionId];
        e.id = editionId;
        e.pieceTitle = pieceTitle;
        e.supply = supply;
        e.metadataURI = metadataURI;
        e.pricingModel = pricingModel;
        e.priceIncreaseRate = priceIncreaseRate;
        e.openTime = openTime;
        for (uint256 i; i < prices.length; ++i) {
            e.prices.push(prices[i]);
        }

        emit EditionAdded(editionId, pieceTitle, prices, supply, pricingModel);
    }

    /// @notice Replace an edition's base prices (each token accepted, each price > 0). A dynamic edition keeps its
    ///         position on the curve: the new base prices rise from the pieces already minted.
    function setEditionPrices(uint256 editionId, TokenPrice[] calldata prices) external {
        if (msg.sender != owner()) revert Unauthorized();
        Edition storage e = editions[editionId];
        if (e.id == 0) revert EditionNotFound();
        PaymentLib.checkPrices(_pay, prices, false);
        while (e.prices.length != 0) e.prices.pop();
        for (uint256 i; i < prices.length; ++i) {
            e.prices.push(prices[i]);
        }
        emit EditionPricesSet(editionId, prices);
    }

    /// @notice Replace the accepted tokens (each on the registry allowlist). Balances already held in a removed
    ///         token stay withdrawable; editions can only sell for accepted tokens.
    function setAcceptedTokens(address[] calldata tokens) external onlyOwner {
        PaymentLib.setAccepted(_pay, registry, tokens);
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

    /// @notice Base price of an edition in `token`; `priced` is false if the edition doesn't sell for it.
    function priceOf(uint256 editionId, address token) public view returns (bool priced, uint256 price) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        return PaymentLib.priceIn(edition.prices, token);
    }

    /**
     * @notice Get current price for an edition in `token`
     * @param editionId Edition ID
     * @param token Payment token (address(0) = ETH)
     * @return price Current price for the next mint
     */
    function getCurrentPrice(uint256 editionId, address token) public view returns (uint256 price) {
        Edition storage edition = editions[editionId];
        (bool priced, uint256 basePrice) = priceOf(editionId, token);
        if (!priced) revert TokenNotPriced();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return basePrice;
        } else {
            // LIMITED_DYNAMIC
            return dynamicPricingModule.calculatePrice(basePrice, edition.priceIncreaseRate, edition.minted);
        }
    }

    /**
     * @notice Calculate total cost in `token` for minting multiple tokens
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @param token Payment token (address(0) = ETH)
     * @return totalCost Total cost for minting the amount
     */
    function calculateMintCost(uint256 editionId, uint256 amount, address token)
        public
        view
        returns (uint256 totalCost)
    {
        Edition storage edition = editions[editionId];
        if (amount == 0) revert AmountMustBePositive();
        (bool priced, uint256 basePrice) = priceOf(editionId, token);
        if (!priced) revert TokenNotPriced();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return basePrice * amount;
        } else {
            // LIMITED_DYNAMIC
            return dynamicPricingModule.calculateBatchCost(basePrice, edition.priceIncreaseRate, edition.minted, amount);
        }
    }

    // ┌─────────────────────────┐
    // │    Minting Functions    │
    // └─────────────────────────┘

    /**
     * @notice Mint tokens with optional message, paying in `token`
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @param message Optional message shown alongside the mint (empty string emits nothing)
     * @param token Payment token (address(0) = ETH): accepted by this collection and on the registry allowlist
     * @param maxCost Maximum acceptable total cost in `token`. ETH: 0 = no limit (msg.value caps it) and any excess
     *        msg.value is refunded. ERC-20: required; exactly the cost is pulled (msg.value must be 0).
     */
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth,timestamp,unused-return
    function mint(
        uint256 editionId,
        uint256 amount,
        bytes32 gatingData,        // password hash (bytes32(0) = open tier)
        string calldata message,
        address token,
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
        if (address(gatingModule) != address(0) && gatingScope != GatingScope.FREE_MINT_ONLY) {
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
        PaymentLib.checkUsable(_pay, registry, token);
        uint256 totalCost = calculateMintCost(editionId, amount, token);
        if (token == PaymentLib.ETH) {
            if (maxCost != 0 && totalCost > maxCost) revert ExceedsMaxCost();
            if (msg.value < totalCost) revert InsufficientPayment();
        } else {
            if (msg.value != 0) revert WrongPayment();
            if (totalCost > maxCost) revert ExceedsMaxCost();
            PaymentLib.collect(token, totalCost);
        }

        // Update edition state
        edition.minted += amount;
        balanceOf[msg.sender][editionId] += amount;
        totalProceeds[token] += totalCost;
        _pay.unsplit[token] += totalCost;

        // Refund excess
        if (token == PaymentLib.ETH && msg.value > totalCost) {
            SmartTransferLib.smartTransferETH(msg.sender, msg.value - totalCost, weth);
        }

        emit TransferSingle(msg.sender, address(0), msg.sender, editionId, amount);
        emit Minted(msg.sender, editionId, amount, token, totalCost);
        if (bytes(message).length > 0) emit MintMessage(msg.sender, editionId, message);
    }

    // ┌─────────────────────────┐
    // │   Withdraw Functions    │
    // └─────────────────────────┘

    /// @notice Split the proceeds held in `token`: protocol cut to the treasury, vault cut to the vault (both
    ///         parked if refused), the rest to the owner's balance. Callable by anyone, so the cuts never wait on the
    ///         artist.
    function distribute(address token) external nonReentrant {
        if (!_distribute(token)) revert AmountMustBePositive();
    }

    /// @notice Pay the owner its balance of `token` (address(0) = ETH), splitting any unsplit proceeds first.
    function withdraw(address token) external onlyOwner nonReentrant {
        bool split = _distribute(token);
        if (PaymentLib.payOwner(_pay, token, owner(), weth) == 0 && !split) revert InsufficientBalance();
    }

    /// @notice `withdraw` for every token this collection has ever accepted.
    function withdrawAll() external onlyOwner nonReentrant {
        address[] storage known = _pay.known;
        bool any;
        for (uint256 i; i < known.length; ++i) {
            // One token that can't split or pay out (a refusing vault, a blocklisted owner) is skipped, not fatal.
            try this.withdrawAllStep(known[i]) returns (bool did) {
                if (did) any = true;
            } catch {
                emit WithdrawSkipped(known[i]);
            }
        }
        if (!any) revert InsufficientBalance();
    }

    /// @notice withdrawAll's step for one token. Only this contract can call it (inside withdrawAll's guard).
    function withdrawAllStep(address token) external returns (bool did) {
        if (msg.sender != address(this)) revert Unauthorized();
        did = _distribute(token);
        if (PaymentLib.payOwner(_pay, token, owner(), weth) != 0) did = true;
    }

    function _distribute(address token) internal returns (bool) {
        uint256 amount = _pay.unsplit[token];
        if (amount == 0) return false;
        _pay.unsplit[token] = 0;
        PaymentLib.split(
            _pay,
            PaymentLib.Terms({
                vault: address(vault),
                treasury: protocolTreasury,
                protocolBps: protocolFeeBps,
                alignmentBps: alignmentBps
            }),
            token,
            amount
        );
        return true;
    }

    /// @notice Retry paying protocol cuts in `token` the treasury previously refused. Anyone can call this.
    function flushPendingProtocolCut(address token) external nonReentrant {
        PaymentLib.flushProtocol(_pay, protocolTreasury, token);
    }

    /// @notice Count `token` that reached this contract outside a mint as proceeds, so the next split shares it.
    ///         Only tokens this collection has accepted. Anyone can call this.
    function sweepUntracked(address token) external nonReentrant {
        if (!_pay.isKnown[token]) revert PaymentLib.TokenNotAccepted(token);
        uint256 untracked = PaymentLib.untracked(_pay, token);
        if (untracked == 0) revert AmountMustBePositive();
        totalProceeds[token] += untracked;
        _pay.unsplit[token] += untracked;
    }

    /**
     * @notice Retry sending the vault cuts in `token` the vault previously rejected.
     * @dev Permissionless — anyone can call once the vault is restored. A parked cut under the vault's minimum
     *      (e.g. the last split of a sold-out collection) can be topped up by `topUp` (ETH: msg.value == topUp; an
     *      ERC-20 is pulled from the caller): all of it goes to the vault, credited to this collection like the cut,
     *      and a total still under the minimum reverts, which returns the top-up.
     */
    function flushPendingVaultCut(address token, uint256 topUp) external payable nonReentrant {
        PaymentLib.flushVault(_pay, address(vault), token, topUp);
    }

    // ── Payment views ─────────────────────────────────────────────────────────

    function acceptedTokens() external view returns (address[] memory) {
        return _pay.accepted;
    }

    /// @notice Every token this collection has ever accepted (withdrawAll walks these).
    function knownTokens() external view returns (address[] memory) {
        return _pay.known;
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return _pay.isAccepted[token];
    }

    /// @notice Sale proceeds in `token` not yet split.
    function unsplitProceeds(address token) external view returns (uint256) {
        return _pay.unsplit[token];
    }

    /// @notice The owner's withdrawable balance of `token` (excludes unsplit proceeds).
    function ownerBalance(address token) external view returns (uint256) {
        return _pay.ownerOwed[token];
    }

    function pendingVaultCut(address token) external view returns (uint256) {
        return _pay.vaultOwed[token];
    }

    function pendingProtocolCut(address token) external view returns (uint256) {
        return _pay.protocolOwed[token];
    }

    /**
     * @notice Claim this collection's vault fees in `mode` and forward what the vault pays (INFER, IMD, ETH) to the
     *         owner. `minEthOut` is the floor for ClaimMode.ETH.
     * @dev Vault contributions wait in the vault's open batch and earn shares when the keeper next converts. Fees
     *      can only be claimed after that.
     */
    function claimVaultFees(ClaimMode mode, uint256 minEthOut)
        external
        onlyOwner
        nonReentrant
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        return PaymentLib.claimVaultFees(address(vault), mode, minEthOut, owner(), weth, true);
    }

    /// @notice Claim this instance's vault fees as tokens and forward them to the owner (IFactoryInstance).
    function claimAllFees() external onlyOwner nonReentrant {
        PaymentLib.claimVaultFees(address(vault), ClaimMode.TOKENS, 0, owner(), weth, false);
    }

    /// @notice Accept ETH from the vault when it pays out claimed fees; claimVaultFees() forwards it to the owner.
    ///         ETH from anywhere else stays out of the split until sweepUntracked(address(0)) counts it.
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

    /// @notice Disabled: the artist's share of every split is owed to owner(), so renouncing would strand it.
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

