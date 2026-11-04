// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SmartTransferLib} from "../../libraries/SmartTransferLib.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {RevenueSplitLib} from "../../shared/libraries/RevenueSplitLib.sol";
import {IInstanceLifecycle, TYPE_ERC721, STATE_ACTIVE} from "../../interfaces/IInstanceLifecycle.sol";

// ── ERC721AuctionInstance errors ──────────────────────────────────────────────
error InvalidAddress();
error SettlementGasTooLow();
error NoPendingProtocolCut();
error InvalidName();
error InvalidSymbol();
error InvalidLines();
error InvalidDuration();
error InvalidTimeBuffer();
error InvalidBidIncrement();
error DepositRequired();
error URIRequired();
error AuctionDoesNotExist();
error AuctionNotStarted();
error AuctionAlreadySettled();
error AuctionNotEnded();
error AuctionExpired();
error BidBelowMinimum();
error BidTooLow();
error NoBids();
error HasBids();
error NoFeesToClaim();
error TokenDoesNotExist();
error InvalidLine();
error Unauthorized();
error InvalidSplit();
error NotEscrowedWinner();
error RenounceDisabled();

/**
 * @title ERC721AuctionInstance
 * @notice ERC721 contract with built-in English auction mechanics for 1/1 artists.
 *         Artists queue pieces with metadata and ETH deposits, buyers bid in English auctions.
 * @dev Implements parallel auction lines (1-3 concurrent slots) with round-robin token assignment.
 *      All auction parameters are immutable after creation for predictability.
 */
contract ERC721AuctionInstance is ERC721, Ownable, ReentrancyGuard, IInstanceLifecycle {
    uint256 private constant WINNER_MINT_GAS = 500_000;
    uint256 private constant SETTLE_RESERVE_GAS = 400_000;

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    struct Auction {
        uint24 tokenId;
        string tokenURI;
        uint256 minBid;         // Creator's deposit = minimum bid
        address highBidder;
        uint256 highBid;
        uint40 startTime;
        uint40 endTime;
        bool settled;
    }

    // ┌─────────────────────────┐
    // │   Immutable Config      │
    // └─────────────────────────┘

    IAlignmentVault public immutable vault;
    address public immutable protocolTreasury;
    /// @notice Protocol fee (bps) snapshotted at launch; never changes.
    uint16 public immutable protocolFeeBps;
    /// @notice Alignment vault share (bps) chosen at launch; never changes.
    uint16 public immutable alignmentBps;
    uint8 public immutable lines;
    uint40 public immutable baseDuration;
    uint40 public immutable timeBuffer;
    uint256 public immutable bidIncrement;
    address public immutable weth;

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string private _name;
    string private _symbol;

    // Next token ID to be assigned when queuing a piece (1-indexed)
    uint24 public nextTokenId;

    // Per-line queues: lineIndex => array of tokenIds in queue order
    mapping(uint8 => uint24[]) public lineQueues;
    // Per-line: index of next piece to activate from the queue
    mapping(uint8 => uint256) public lineQueueHead;

    // Token data
    mapping(uint24 => Auction) public auctions;
    mapping(uint24 => string) private _tokenURIs;
    // slither-disable-next-line immutable-states
    address public factory;

    /// @dev Vault cuts that could not be sent (vault reverted). Retry via flushPendingVaultCut().
    uint256 public pendingVaultCut;
    /// @notice Protocol cuts the treasury refused, held here until it accepts them.
    uint256 public pendingProtocolCut;

    /// @notice Winner of a settled auction whose token is held here because the safe mint to them failed
    ///         (contract winner without a working onERC721Received). Claim with claimEscrowedToken().
    mapping(uint24 => address) public escrowedWinner;

    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

    event ProtocolCutParked(uint256 amount);
    event PieceQueued(uint24 indexed tokenId, uint8 indexed line, uint256 minBid, string tokenURI);
    event AuctionStarted(uint24 indexed tokenId, uint40 startTime, uint40 endTime);
    event BidPlaced(uint24 indexed tokenId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint24 indexed tokenId, address indexed winner, uint256 amount);
    event UnsoldReclaimed(uint24 indexed tokenId, uint256 forfeitedDeposit);
    event BidMessage(uint24 indexed tokenId, address indexed bidder, string message);
    event VaultContributionFailed(address indexed vault, uint256 amount);
    event WinnerTokenEscrowed(uint24 indexed tokenId, address indexed winner);
    event EscrowedTokenClaimed(uint24 indexed tokenId, address indexed winner, address to);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    struct ConstructorParams {
        address vault;
        address protocolTreasury;
        uint16 protocolFeeBps;
        uint16 alignmentBps;
        address owner;
        string name;
        string symbol;
        uint8 lines;
        uint40 baseDuration;
        uint40 timeBuffer;
        uint256 bidIncrement;
        address factory;
        address weth;
    }

    constructor(ConstructorParams memory p) {
        if (p.vault == address(0)) revert InvalidAddress();
        if (p.protocolTreasury == address(0)) revert InvalidAddress();
        if (p.owner == address(0)) revert InvalidAddress();
        if (uint256(p.protocolFeeBps) + p.alignmentBps > RevenueSplitLib.BPS) revert InvalidSplit();
        if (bytes(p.name).length == 0) revert InvalidName();
        if (bytes(p.symbol).length == 0) revert InvalidSymbol();
        if (p.lines < 1 || p.lines > 3) revert InvalidLines();
        if (p.baseDuration == 0) revert InvalidDuration();
        if (p.timeBuffer == 0) revert InvalidTimeBuffer();
        if (p.bidIncrement == 0) revert InvalidBidIncrement();

        _initializeOwner(p.owner);
        vault = IAlignmentVault(payable(p.vault));
        protocolTreasury = p.protocolTreasury;
        protocolFeeBps = p.protocolFeeBps;
        alignmentBps = p.alignmentBps;
        _name = p.name;
        _symbol = p.symbol;
        lines = p.lines;
        baseDuration = p.baseDuration;
        timeBuffer = p.timeBuffer;
        bidIncrement = p.bidIncrement;
        factory = p.factory;
        weth = p.weth;
        nextTokenId = 1;
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC721;
    }

    // ┌─────────────────────────┐
    // │   ERC721 Overrides      │
    // └─────────────────────────┘

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return _tokenURIs[uint24(tokenId)];
    }

    // ┌─────────────────────────┐
    // │    Piece Queuing        │
    // └─────────────────────────┘

    /**
     * @notice Queue a new piece for auction
     * @dev msg.value becomes the minimum bid (creator's skin in the game).
     *      Piece is assigned to a line via round-robin and starts immediately if line is idle.
     * @param _tokenURI Metadata URI for the piece (required)
     */
    function queuePiece(string calldata _tokenURI) external payable nonReentrant {
        if (msg.sender != owner()) revert Unauthorized();
        if (msg.value == 0) revert DepositRequired();
        if (bytes(_tokenURI).length == 0) revert URIRequired();

        uint24 tokenId = nextTokenId++;
        if (tokenId == 1) emit StateChanged(STATE_ACTIVE);
        uint8 line = uint8((tokenId - 1) % lines);

        auctions[tokenId] = Auction({
            tokenId: tokenId,
            tokenURI: _tokenURI,
            minBid: msg.value,
            highBidder: address(0),
            highBid: 0,
            startTime: 0,
            endTime: 0,
            settled: false
        });
        _tokenURIs[tokenId] = _tokenURI;

        // Add to line queue
        lineQueues[line].push(tokenId);

        emit PieceQueued(tokenId, line, msg.value, _tokenURI);

        // If this is the only piece in the queue for this line, start it
        if (lineQueues[line].length - lineQueueHead[line] == 1) {
            _startAuction(tokenId);
        }
    }

    // ┌─────────────────────────┐
    // │       Bidding           │
    // └─────────────────────────┘

    /**
     * @notice Place a bid on an active auction
     * @dev First bid must meet minBid. Subsequent bids must exceed current by bidIncrement.
     *      Previous bidder is refunded via forceSafeTransferETH. Late bids extend the auction.
     * @param tokenId The token ID to bid on
     * @param message Optional message shown alongside the bid (empty string emits nothing)
     */
    // slither-disable-next-line timestamp
    function createBid(uint24 tokenId, string calldata message) external payable nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp >= auction.endTime) revert AuctionExpired();

        if (auction.highBidder == address(0)) {
            // First bid must meet minimum
            if (msg.value < auction.minBid) revert BidBelowMinimum();
        } else {
            // Subsequent bids must exceed current by increment
            if (msg.value < auction.highBid + bidIncrement) revert BidTooLow();
        }

        // Refund previous bidder
        address previousBidder = auction.highBidder;
        uint256 previousBid = auction.highBid;

        auction.highBidder = msg.sender;
        auction.highBid = msg.value;

        if (previousBidder != address(0)) {
            SafeTransferLib.forceSafeTransferETH(previousBidder, previousBid);
        }

        // Anti-snipe: extend if bid is within timeBuffer of end
        if (auction.endTime - block.timestamp < timeBuffer) {
            auction.endTime = uint40(block.timestamp) + timeBuffer;
        }

        emit BidPlaced(tokenId, msg.sender, msg.value);
        if (bytes(message).length > 0) emit BidMessage(tokenId, msg.sender, message);
    }

    // ┌─────────────────────────┐
    // │     Settlement          │
    // └─────────────────────────┘

    /**
     * @notice Settle an auction after it ends with bids
     * @dev Mints NFT to winner, refunds creator deposit, splits winning bid
     *      (protocol / vault / artist, using the bps snapshotted at launch).
     *      Auto-advances line to next queued piece.
     * @param tokenId The token ID to settle
     */
    // slither-disable-next-line arbitrary-send-eth,reentrancy-benign,reentrancy-eth,timestamp
    function settleAuction(uint24 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highBidder == address(0)) revert NoBids();

        auction.settled = true;

        // Mint NFT to winner with _safeMint. If the winner is a contract whose onERC721Received reverts
        // (or is missing), settlement must not freeze: the token is minted to this contract instead and the
        // winner pulls it to any address with claimEscrowedToken().
        // Reentrancy is safe: auction.settled = true is set above and nonReentrant guards this function.
        address winner = auction.highBidder;
        // Capped so a winner's hook can't burn the gas the rest of settlement needs. The check stops a settler sending
        // too little gas to force the token into escrow.
        if (gasleft() < WINNER_MINT_GAS + WINNER_MINT_GAS / 32 + SETTLE_RESERVE_GAS) revert SettlementGasTooLow();
        try this.safeMintWinner{ gas: WINNER_MINT_GAS }(winner, tokenId) {}
        catch {
            _mint(address(this), tokenId);
            escrowedWinner[tokenId] = winner;
            emit WinnerTokenEscrowed(tokenId, winner);
        }

        // Refund creator's deposit (force-transfer so a non-receiving owner cannot permanently strand the bidder's funds)
        SafeTransferLib.forceSafeTransferETH(owner(), auction.minBid);

        RevenueSplitLib.Split memory s = RevenueSplitLib.split(auction.highBid, protocolFeeBps, alignmentBps);

        _payProtocol(s.protocolCut);

        // Parked cuts go with this one, so small ones add up past the vault's minimum.
        uint256 cut = s.vaultCut + pendingVaultCut;
        pendingVaultCut = 0;
        try vault.receiveContribution{value: cut}(
            Currency.wrap(address(0)),
            cut,
            address(this)
        ) {} catch {
            pendingVaultCut = cut;
            emit VaultContributionFailed(address(vault), cut);
        }
        SmartTransferLib.smartTransferETH(owner(), s.remainder, weth);

        emit AuctionSettled(tokenId, auction.highBidder, auction.highBid);

        // Advance line to next queued piece
        _advanceLine(tokenId);
    }

    /// @dev Self-call target so settleAuction can try/catch the receiver hook. Only callable by this contract.
    function safeMintWinner(address to, uint24 tokenId) external {
        if (msg.sender != address(this)) revert Unauthorized();
        _safeMint(to, tokenId);
    }

    /**
     * @notice Pull an auction-won token that was escrowed at settlement
     * @param tokenId The escrowed token
     * @param to Recipient (safe transfer: contracts must implement IERC721Receiver)
     */
    function claimEscrowedToken(uint24 tokenId, address to) external nonReentrant {
        if (escrowedWinner[tokenId] != msg.sender) revert NotEscrowedWinner();
        delete escrowedWinner[tokenId];
        // The data names the winner, so a MiyaPool receiving this credits them rather than this contract.
        _safeTransfer(address(this), to, tokenId, abi.encode(msg.sender));
        emit EscrowedTokenClaimed(tokenId, msg.sender, to);
    }

    // ┌─────────────────────────┐
    // │    Unsold Reclaim       │
    // └─────────────────────────┘

    /**
     * @notice Reclaim an unsold piece (auction expired with no bids)
     * @dev NFT is never minted. Creator deposit is forfeited to protocol treasury.
     *      Line advances to next queued piece.
     * @param tokenId The token ID to reclaim
     */
    // slither-disable-next-line timestamp
    function reclaimUnsold(uint24 tokenId) external onlyOwner nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highBidder != address(0)) revert HasBids();

        auction.settled = true;

        // Forfeit deposit to protocol treasury
        uint256 deposit = auction.minBid;
        _payProtocol(deposit);

        emit UnsoldReclaimed(tokenId, deposit);

        // Advance line to next queued piece
        _advanceLine(tokenId);
    }

    // ┌─────────────────────────┐
    // │   Vault Fee Claiming    │
    // └─────────────────────────┘

    /**
     * @notice Claim accumulated vault fees and forward to creator
     * @return totalClaimed Amount of ETH claimed
     */
    function claimVaultFees() external onlyOwner nonReentrant returns (uint256 totalClaimed) {
        totalClaimed = vault.claimFees();
        if (totalClaimed == 0) revert NoFeesToClaim();
        SmartTransferLib.smartTransferETH(owner(), totalClaimed, weth);
    }

    /// @dev Pay the treasury this cut and anything parked. A treasury that refuses is never a reason to hold up a sale.
    function _payProtocol(uint256 amount) private {
        uint256 total = amount + pendingProtocolCut;
        if (total == 0) return;
        pendingProtocolCut = 0;
        if (!SafeTransferLib.trySafeTransferETH(protocolTreasury, total, SafeTransferLib.GAS_STIPEND_NO_GRIEF)) {
            pendingProtocolCut = total;
            emit ProtocolCutParked(total);
        }
    }

    /// @notice Retry paying protocol cuts the treasury previously refused. Anyone can call this.
    function flushPendingProtocolCut() external nonReentrant {
        uint256 pending = pendingProtocolCut;
        if (pending == 0) revert NoPendingProtocolCut();
        pendingProtocolCut = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, pending);
    }

    /// @notice Retry sending any previously failed vault cuts.
    /// @dev Permissionless — anyone can call once the vault is healthy again.
    function flushPendingVaultCut() external nonReentrant {
        uint256 pending = pendingVaultCut;
        if (pending == 0) revert NoFeesToClaim();
        pendingVaultCut = 0;
        vault.receiveContribution{value: pending}(Currency.wrap(address(0)), pending, address(this));
    }

    /// @notice Claim accumulated fees from this instance's vault (fixed at launch) and forward them to the owner.
    /// @dev With a single fixed vault this is equivalent to claimVaultFees(); kept for IFactoryInstance.
    function claimAllFees() external onlyOwner nonReentrant {
        uint256 claimed = vault.claimFees();
        if (claimed > 0) SmartTransferLib.smartTransferETH(owner(), claimed, weth);
    }

    // ┌─────────────────────────┐
    // │    Internal Helpers     │
    // └─────────────────────────┘

    function _startAuction(uint24 tokenId) internal {
        Auction storage auction = auctions[tokenId];
        auction.startTime = uint40(block.timestamp);
        auction.endTime = uint40(block.timestamp) + baseDuration;

        emit AuctionStarted(tokenId, auction.startTime, auction.endTime);
    }

    function _advanceLine(uint24 tokenId) internal {
        uint8 line = uint8((tokenId - 1) % lines);
        lineQueueHead[line]++;

        // Start next auction if queue has more pieces
        if (lineQueueHead[line] < lineQueues[line].length) {
            uint24 nextId = lineQueues[line][lineQueueHead[line]];
            _startAuction(nextId);
        }
    }

    // ┌─────────────────────────┐
    // │      View Functions     │
    // └─────────────────────────┘

    /**
     * @notice Get the currently active auction for a line
     * @param line Line index (0-based)
     * @return tokenId Active token ID (0 if no active auction)
     */
    function getActiveAuction(uint8 line) external view returns (uint24 tokenId) {
        if (line >= lines) revert InvalidLine();
        uint256 head = lineQueueHead[line];
        if (head >= lineQueues[line].length) return 0;
        uint24 id = lineQueues[line][head];
        if (auctions[id].settled) return 0;
        return id;
    }

    /**
     * @notice Get queue length for a line (pending + active)
     * @param line Line index (0-based)
     * @return remaining Number of unprocessed pieces in queue
     */
    function getQueueLength(uint8 line) external view returns (uint256 remaining) {
        if (line >= lines) revert InvalidLine();
        return lineQueues[line].length - lineQueueHead[line];
    }

    /**
     * @notice Get auction details
     * @param tokenId Token ID
     */
    // slither-disable-next-line incorrect-equality,timestamp
    function getAuction(uint24 tokenId) external view returns (Auction memory) {
        if (auctions[tokenId].tokenId == 0) revert AuctionDoesNotExist();
        return auctions[tokenId];
    }

    /// @notice Disabled: the artist's share of every sale is sent to owner(), so renouncing would burn it.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }

    // Allow receiving ETH (for vault refunds etc.)
    receive() external payable {}
}
