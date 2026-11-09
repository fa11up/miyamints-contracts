// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SmartTransferLib} from "../../libraries/SmartTransferLib.sol";
import {PaymentLib} from "../../libraries/PaymentLib.sol";
import {IAlignmentVault, ClaimMode} from "../../interfaces/IAlignmentVault.sol";
import {RevenueSplitLib} from "../../shared/libraries/RevenueSplitLib.sol";
import {IInstanceLifecycle, TYPE_ERC721, STATE_ACTIVE} from "../../interfaces/IInstanceLifecycle.sol";

// ── ERC721AuctionInstance errors ──────────────────────────────────────────────
error InvalidAddress();
error SettlementGasTooLow();
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
error WrongPayment();
error NothingToRefund();
error TokenDoesNotExist();
error InvalidLine();
error Unauthorized();
error InvalidSplit();
error NotEscrowedWinner();
error RenounceDisabled();

/**
 * @title ERC721AuctionInstance
 * @notice ERC721 contract with built-in English auction mechanics for 1/1 artists.
 *         Artists queue pieces with metadata and deposits, buyers bid in English auctions.
 *
 *         One `currency` per auction collection, chosen by the artist at creation (address(0) = ETH, or an ERC-20
 *         on the registry's payment-token allowlist). Deposits, bids, outbid refunds, the settle split and the
 *         unsold reclaim are all in that currency. ETH works as it always has: outbid bidders and the deposit
 *         refund are pushed (forceSafeTransferETH) and the artist's share is sent at settlement. With an ERC-20,
 *         every payout that could be refused is pull-based: an outbid bidder's refund is credited (`claimRefund`)
 *         and the artist's deposit and share go to its balance (`withdraw`), so a blocklisted or reverting address
 *         can never stop a higher bid or a settlement.
 * @dev Implements parallel auction lines (1-3 concurrent slots) with round-robin token assignment.
 *      All auction parameters are immutable after creation for predictability.
 */
contract ERC721AuctionInstance is ERC721, Ownable, ReentrancyGuard, IInstanceLifecycle {
    uint256 private constant WINNER_MINT_GAS = 500_000;
    uint256 private constant SETTLE_RESERVE_GAS = 400_000;
    /// @notice How long after a no-bid auction ends only the owner may close it. After this anyone may, so a queued
    ///         piece can't wait on the owner forever. The owner gets this long to choose when the next piece starts.
    uint256 public constant UNSOLD_CLOSE_GRACE = 7 days;

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
    /// @notice The registry whose payment-token allowlist this collection checks.
    address public immutable registry;
    /// @notice The currency of every auction here: address(0) = ETH, else an allowlisted ERC-20. Fixed at creation.
    address public immutable currency;
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

    /// @dev Per-token accounting (PaymentLib): parked vault and protocol cuts, the artist's balance (ERC-20 only),
    ///      and `escrow` = deposits + live high bids + outbid refunds owed, in `currency`.
    PaymentLib.Ledger internal _pay;

    /// @notice ERC-20 auctions: refunds owed to outbid bidders, claimed with claimRefund().
    mapping(address bidder => uint256) public refundOf;

    /// @notice Winner of a settled auction whose token is held here because the safe mint to them failed
    ///         (contract winner without a working onERC721Received). Claim with claimEscrowedToken().
    mapping(uint24 => address) public escrowedWinner;

    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

    event RefundCredited(address indexed bidder, uint256 amount);
    event RefundClaimed(address indexed bidder, address indexed to, uint256 amount);
    event PieceQueued(uint24 indexed tokenId, uint8 indexed line, uint256 minBid, string tokenURI);
    event AuctionStarted(uint24 indexed tokenId, uint40 startTime, uint40 endTime);
    event BidPlaced(uint24 indexed tokenId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint24 indexed tokenId, address indexed winner, uint256 amount);
    event UnsoldReclaimed(uint24 indexed tokenId, uint256 forfeitedDeposit);
    event BidMessage(uint24 indexed tokenId, address indexed bidder, string message);
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
        address registry;
        address currency;       // address(0) = ETH
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
        if (p.registry == address(0)) revert InvalidAddress();

        _initializeOwner(p.owner);
        vault = IAlignmentVault(payable(p.vault));
        registry = p.registry;
        currency = p.currency;
        address[] memory accepted = new address[](1);
        accepted[0] = p.currency;
        PaymentLib.setAccepted(_pay, p.registry, accepted);
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
     * @dev The deposit becomes the minimum bid (creator's skin in the game), paid in `currency`: ETH as msg.value ==
     *      deposit, an ERC-20 pulled from the owner (msg.value must be 0). `currency` must still be on the registry
     *      allowlist. Piece is assigned to a line via round-robin and starts immediately if line is idle.
     * @param _tokenURI Metadata URI for the piece (required)
     * @param deposit Deposit and minimum bid, in `currency` units
     */
    function queuePiece(string calldata _tokenURI, uint256 deposit) external payable nonReentrant {
        if (msg.sender != owner()) revert Unauthorized();
        if (deposit == 0) revert DepositRequired();
        if (bytes(_tokenURI).length == 0) revert URIRequired();
        PaymentLib.checkAllowed(registry, currency);
        if (currency == PaymentLib.ETH && msg.value != deposit) revert WrongPayment();
        PaymentLib.collect(currency, deposit);
        _pay.escrow[currency] += deposit;

        uint24 tokenId = nextTokenId++;
        if (tokenId == 1) emit StateChanged(STATE_ACTIVE);
        uint8 line = uint8((tokenId - 1) % lines);

        auctions[tokenId] = Auction({
            tokenId: tokenId,
            tokenURI: _tokenURI,
            minBid: deposit,
            highBidder: address(0),
            highBid: 0,
            startTime: 0,
            endTime: 0,
            settled: false
        });
        _tokenURIs[tokenId] = _tokenURI;

        // Add to line queue
        lineQueues[line].push(tokenId);

        emit PieceQueued(tokenId, line, deposit, _tokenURI);

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
     * @dev First bid must meet minBid. Subsequent bids must exceed current by bidIncrement. The bid is paid in
     *      `currency`: ETH as msg.value == amount, an ERC-20 pulled from the bidder (msg.value must be 0).
     *      The previous bidder is refunded: ETH via forceSafeTransferETH, an ERC-20 credited to refundOf (pull, so a
     *      blocklisted or reverting bidder can't stop a higher bid). Late bids extend the auction.
     * @param tokenId The token ID to bid on
     * @param amount The bid, in `currency` units
     * @param message Optional message shown alongside the bid (empty string emits nothing)
     */
    // slither-disable-next-line timestamp
    function createBid(uint24 tokenId, uint256 amount, string calldata message) external payable nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp >= auction.endTime) revert AuctionExpired();

        if (auction.highBidder == address(0)) {
            // First bid must meet minimum
            if (amount < auction.minBid) revert BidBelowMinimum();
        } else {
            // Subsequent bids must exceed current by increment
            if (amount < auction.highBid + bidIncrement) revert BidTooLow();
        }
        if (currency == PaymentLib.ETH && msg.value != amount) revert WrongPayment();
        PaymentLib.collect(currency, amount);

        // Refund previous bidder
        address previousBidder = auction.highBidder;
        uint256 previousBid = auction.highBid;

        auction.highBidder = msg.sender;
        auction.highBid = amount;

        if (previousBidder != address(0)) {
            if (currency == PaymentLib.ETH) {
                _pay.escrow[currency] = _pay.escrow[currency] + amount - previousBid;
                SafeTransferLib.forceSafeTransferETH(previousBidder, previousBid);
            } else {
                _pay.escrow[currency] += amount;
                refundOf[previousBidder] += previousBid;
                emit RefundCredited(previousBidder, previousBid);
            }
        } else {
            _pay.escrow[currency] += amount;
        }

        // Anti-snipe: extend if bid is within timeBuffer of end
        if (auction.endTime - block.timestamp < timeBuffer) {
            auction.endTime = uint40(block.timestamp) + timeBuffer;
        }

        emit BidPlaced(tokenId, msg.sender, amount);
        if (bytes(message).length > 0) emit BidMessage(tokenId, msg.sender, message);
    }

    /**
     * @notice ERC-20 auctions: claim the refunds credited to the caller for outbid bids
     * @param to Recipient (lets a bidder whose own address the token blocks claim elsewhere)
     */
    function claimRefund(address to) external nonReentrant {
        uint256 amount = refundOf[msg.sender];
        if (amount == 0) revert NothingToRefund();
        if (to == address(0)) revert InvalidAddress();
        refundOf[msg.sender] = 0;
        _pay.escrow[currency] -= amount;
        SafeTransferLib.safeTransfer(currency, to, amount);
        emit RefundClaimed(msg.sender, to, amount);
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

        address token = currency;
        _pay.escrow[token] -= auction.minBid + auction.highBid;
        if (token == PaymentLib.ETH) {
            // Refund creator's deposit (force-transfer so a non-receiving owner cannot permanently strand the bidder's
            // funds)
            SafeTransferLib.forceSafeTransferETH(owner(), auction.minBid);

            RevenueSplitLib.Split memory s = RevenueSplitLib.split(auction.highBid, protocolFeeBps, alignmentBps);
            PaymentLib.payProtocol(_pay, protocolTreasury, token, s.protocolCut);
            // Parked cuts go with this one, so small ones add up past the vault's minimum.
            PaymentLib.sendOrPark(_pay, address(vault), token, s.vaultCut);
            SmartTransferLib.smartTransferETH(owner(), s.remainder, weth);
        } else {
            // ERC-20: the deposit and the artist's share go to the owner's balance (withdraw), so a blocklisted owner
            // can't freeze settlement.
            _pay.ownerOwed[token] += auction.minBid;
            PaymentLib.split(_pay, _terms(), token, auction.highBid);
        }

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
     * @dev NFT is never minted. Creator deposit is forfeited to protocol treasury, whoever calls: bidding is over, so
     *      that is the only place it can go. Line advances to next queued piece.
     *      Owner only until UNSOLD_CLOSE_GRACE after the end, then anyone.
     * @param tokenId The token ID to reclaim
     */
    // slither-disable-next-line timestamp
    function reclaimUnsold(uint24 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highBidder != address(0)) revert HasBids();
        if (msg.sender != owner() && block.timestamp < uint256(auction.endTime) + UNSOLD_CLOSE_GRACE) {
            revert Unauthorized();
        }

        auction.settled = true;

        // Forfeit deposit to protocol treasury
        uint256 deposit = auction.minBid;
        _pay.escrow[currency] -= deposit;
        PaymentLib.payProtocol(_pay, protocolTreasury, currency, deposit);

        emit UnsoldReclaimed(tokenId, deposit);

        // Advance line to next queued piece
        _advanceLine(tokenId);
    }

    // ┌─────────────────────────┐
    // │   Vault Fee Claiming    │
    // └─────────────────────────┘

    /**
     * @notice Claim this collection's vault fees in `mode` and forward what the vault pays (INFER, IMD, ETH) to the
     *         owner. `minEthOut` is the floor for ClaimMode.ETH.
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

    /// @notice Retry paying protocol cuts in `token` the treasury previously refused. Anyone can call this.
    function flushPendingProtocolCut(address token) external nonReentrant {
        PaymentLib.flushProtocol(_pay, protocolTreasury, token);
    }

    /// @notice Retry sending previously failed vault cuts in `token`.
    /// @dev Permissionless — anyone can call once the vault is healthy again. A parked cut under the vault's minimum
    ///      can be topped up by `topUp` (ETH: msg.value == topUp; an ERC-20 is pulled from the caller): all of it goes
    ///      to the vault, credited to this collection like the cut, and a total still under the minimum reverts,
    ///      which returns the top-up.
    function flushPendingVaultCut(address token, uint256 topUp) external payable nonReentrant {
        PaymentLib.flushVault(_pay, address(vault), token, topUp);
    }

    /// @notice Count `token` that reached this auction house outside a bid or deposit (royalties, transfers) as
    ///         proceeds and split it like a sale. Only the auction currency; escrow and everything owed is excluded.
    ///         Anyone can call this.
    function sweepUntracked(address token) external nonReentrant {
        if (!_pay.isKnown[token]) revert PaymentLib.TokenNotAccepted(token);
        uint256 extra = PaymentLib.untracked(_pay, token);
        if (extra == 0) revert PaymentLib.NothingToWithdraw();
        PaymentLib.split(_pay, _terms(), token, extra);
    }

    /// @notice ERC-20 auctions: pay the owner its balance (returned deposits and sale proceeds) of `token`.
    function withdraw(address token) external onlyOwner nonReentrant {
        if (PaymentLib.payOwner(_pay, token, owner(), weth) == 0) revert PaymentLib.NothingToWithdraw();
    }

    /// @notice `withdraw` for every token this collection accepts (its one currency).
    function withdrawAll() external onlyOwner nonReentrant {
        if (PaymentLib.payOwner(_pay, currency, owner(), weth) == 0) revert PaymentLib.NothingToWithdraw();
    }

    // ── Payment views ─────────────────────────────────────────────────────────

    /// @notice The one currency of this collection's auctions.
    function acceptedTokens() external view returns (address[] memory) {
        return _pay.accepted;
    }

    function ownerBalance(address token) external view returns (uint256) {
        return _pay.ownerOwed[token];
    }

    function pendingVaultCut(address token) external view returns (uint256) {
        return _pay.vaultOwed[token];
    }

    function pendingProtocolCut(address token) external view returns (uint256) {
        return _pay.protocolOwed[token];
    }

    /// @notice Deposits, live high bids and outbid refunds held, in `token`.
    function escrowed(address token) external view returns (uint256) {
        return _pay.escrow[token];
    }

    function _terms() internal view returns (PaymentLib.Terms memory) {
        return PaymentLib.Terms({
            vault: address(vault), treasury: protocolTreasury, protocolBps: protocolFeeBps, alignmentBps: alignmentBps
        });
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
     * @notice Get the auction taking bids on a line
     * @dev A piece that has ended but isn't closed returns 0: read it with lineQueues(line, lineQueueHead(line)).
     * @param line Line index (0-based)
     * @return tokenId Active token ID (0 if no auction is taking bids)
     */
    function getActiveAuction(uint8 line) external view returns (uint24 tokenId) {
        if (line >= lines) revert InvalidLine();
        uint256 head = lineQueueHead[line];
        if (head >= lineQueues[line].length) return 0;
        uint24 id = lineQueues[line][head];
        if (block.timestamp >= auctions[id].endTime) return 0;
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
