// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "solady/tokens/ERC721.sol";
import { ERC2981 } from "solady/tokens/ERC2981.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { LibString } from "solady/utils/LibString.sol";
import { RevenueSplitLib } from "../../shared/libraries/RevenueSplitLib.sol";
import { PaymentLib } from "../../libraries/PaymentLib.sol";
import { IAlignmentVault, ClaimMode } from "../../interfaces/IAlignmentVault.sol";
import { TokenPrice } from "../interfaces/TokenPrice.sol";
import { IInstanceLifecycle, TYPE_ERC721, STATE_MINTING } from "../../interfaces/IInstanceLifecycle.sol";

/**
 * @title ERC721DropInstance
 * @notice Fixed-price PFP drop: sequential ids from 1 to `maxSupply`, up to 8 mint phases (each with a window,
 *         a price per accepted token, optional Merkle allowlist and per-wallet cap), owner reserve mints, delayed
 *         reveal and a one-way metadata lock.
 *
 *         Payment tokens: the owner keeps an `acceptedTokens` list (each on the registry allowlist; address(0) =
 *         ETH) and each phase prices any of them. A mint names the token and a `maxCost`. Proceeds are kept per
 *         token, as paid, and split by the permissionless `distribute(token)` with the terms snapshotted at launch:
 *         `protocolBps` to the treasury, `alignmentBps` to the alignment vault (in the token paid), the rest to the
 *         owner's balance for that token, which only the owner withdraws (`withdraw(token)`, `withdrawAll()`).
 *         A refused vault cut is parked per token (`pendingVaultCut(token)`) and retried with the next split or
 *         `flushPendingVaultCut`; it is never redirected to the owner. A refused protocol cut is parked likewise.
 */
contract ERC721DropInstance is ERC721, ERC2981, Ownable, ReentrancyGuard, IInstanceLifecycle {
    using LibString for uint256;

    struct Phase {
        uint64 start; // unix seconds, inclusive
        uint64 end; // unix seconds, exclusive; 0 = no end
        uint32 maxPerWallet; // 0 = unlimited
        bytes32 merkleRoot; // 0 = public; else leaf = keccak256(bytes.concat(keccak256(abi.encode(minter))))
        uint32 supplyCap; // most this phase can sell in total; 0 = no cap beyond maxSupply
        TokenPrice[] prices; // price per piece in each token this phase sells for (accepted tokens only; 0 = free)
    }

    struct InitParams {
        string name;
        string symbol;
        uint32 maxSupply;
        uint32 ownerReserve; // pieces only ownerMint can mint, held back from every phase; fixed at creation
        string baseURI; // revealed metadata prefix; empty until reveal
        string unrevealedURI; // served for every token until reveal
        string contractURI;
        address royaltyReceiver;
        uint96 royaltyBps;
        address[] acceptedTokens; // address(0) = ETH; each must be on the registry allowlist
        Phase[] phases;
    }

    uint256 public constant MAX_PHASES = 8;

    address public immutable treasury;
    IAlignmentVault public immutable vault;
    /// @notice The registry whose payment-token allowlist this drop checks.
    address public immutable registry;
    address public immutable weth;
    uint16 public immutable protocolBps;
    uint16 public immutable alignmentBps;
    uint32 public immutable maxSupply;
    uint32 public immutable ownerReserve;

    string internal _name;
    string internal _symbol;
    string public baseURI;
    string public unrevealedURI;
    string public contractURI;
    bool public metadataLocked;
    bool public royaltyLocked;

    /// @notice Highest ERC-2981 royalty a drop can set (10%), at creation and in setRoyalty. The app promises this cap.
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    Phase[] internal _phases;
    /// @dev Bumped by every setPhases so per-wallet counters never carry over to a different phase list.
    uint256 public phasesEpoch;
    mapping(uint256 epoch => mapping(uint256 phaseId => mapping(address minter => uint256))) internal _minted;

    /// @dev Total sold per phase, scoped to the phase list like `_minted`.
    mapping(uint256 epoch => mapping(uint256 phaseId => uint256)) internal _phaseMinted;
    uint256 public totalSupply;
    uint256 public ownerMinted;

    PaymentLib.Ledger internal _pay;

    /// @notice withdrawAll skipped `token`: its split or payout reverted. Withdraw it on its own to see why.
    event WithdrawSkipped(address indexed token);
    event PhasesSet(Phase[] phases);
    event PhasePricesSet(uint256 indexed phaseId, TokenPrice[] prices);
    event Minted(
        address indexed to, uint256 indexed phaseId, uint256 firstId, uint256 quantity, address token, uint256 paid
    );
    event MetadataUpdated(string baseURI, string unrevealedURI, string contractURI);
    event MetadataLocked();
    /// @dev EIP-4906: tells marketplaces to refresh every token's metadata.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event RoyaltyLocked();
    event RoyaltySet(address indexed receiver, uint96 bps);

    error InvalidParams();
    error PhaseNotActive();
    error NotAllowlisted();
    error WalletLimit();
    error SoldOut();
    error PhaseSoldOut();
    error ReserveExceeded();
    error WrongPayment();
    error ExceedsMaxCost();
    error TokenNotPriced();
    error Locked();
    error NothingToWithdraw();
    error RenounceDisabled();
    error RoyaltyTooHigh();

    constructor(
        InitParams memory p,
        address owner_,
        address treasury_,
        address vault_,
        address registry_,
        address weth_,
        uint16 protocolBps_,
        uint16 alignmentBps_
    ) {
        if (p.maxSupply == 0 || bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidParams();
        if (owner_ == address(0) || treasury_ == address(0) || vault_ == address(0)) revert InvalidParams();
        if (registry_ == address(0)) revert InvalidParams();
        if (uint256(protocolBps_) + alignmentBps_ > RevenueSplitLib.BPS) revert InvalidParams();
        if (p.ownerReserve > p.maxSupply) revert InvalidParams();
        _initializeOwner(owner_);
        treasury = treasury_;
        vault = IAlignmentVault(payable(vault_));
        registry = registry_;
        weth = weth_;
        protocolBps = protocolBps_;
        alignmentBps = alignmentBps_;
        maxSupply = p.maxSupply;
        ownerReserve = p.ownerReserve;
        _name = p.name;
        _symbol = p.symbol;
        baseURI = p.baseURI;
        unrevealedURI = p.unrevealedURI;
        contractURI = p.contractURI;
        if (p.royaltyReceiver != address(0)) _setRoyalty(p.royaltyReceiver, p.royaltyBps);
        PaymentLib.setAccepted(_pay, registry_, p.acceptedTokens);
        _setPhases(p.phases);
        emit StateChanged(STATE_MINTING);
    }

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC721;
    }

    // ┌─────────────────────────┐
    // │          Views          │
    // └─────────────────────────┘

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        if (bytes(baseURI).length == 0) return unrevealedURI;
        return string.concat(baseURI, id.toString());
    }

    function phases() external view returns (Phase[] memory) {
        return _phases;
    }

    function phaseCount() external view returns (uint256) {
        return _phases.length;
    }

    /// @notice Tokens `minter` has minted in phase `phaseId` of the current phase list
    function mintedInPhase(uint256 phaseId, address minter) external view returns (uint256) {
        return _minted[phasesEpoch][phaseId][minter];
    }

    /// @notice Sold so far in each phase of the current list (same order as `phases`).
    function phasesMinted() external view returns (uint256[] memory minted) {
        minted = new uint256[](_phases.length);
        for (uint256 i; i < minted.length; ++i) {
            minted[i] = _phaseMinted[phasesEpoch][i];
        }
    }

    /// @notice Pieces phases can still sell: what is left of maxSupply after the unused owner reserve.
    function publicRemaining() external view returns (uint256) {
        return maxSupply - totalSupply - (ownerReserve - ownerMinted);
    }

    function isPhaseActive(uint256 phaseId) public view returns (bool) {
        if (phaseId >= _phases.length) return false;
        Phase storage ph = _phases[phaseId];
        return block.timestamp >= ph.start && (ph.end == 0 || block.timestamp < ph.end);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return ERC721.supportsInterface(id) || ERC2981.supportsInterface(id) || id == 0x49064906; // EIP-4906
    }

    // ┌─────────────────────────┐
    // │         Minting         │
    // └─────────────────────────┘

    /// @notice Mint in phase `phaseId`, paying in `token` (address(0) = ETH: msg.value must equal the cost).
    /// @param maxCost Most the caller will pay in `token`. ETH: 0 = no limit (msg.value already caps it). ERC-20:
    ///        required, since the cost is pulled from an allowance.
    function mint(uint256 phaseId, uint256 quantity, bytes32[] calldata proof, address token, uint256 maxCost)
        external
        payable
        nonReentrant
    {
        _mintInPhase(msg.sender, phaseId, quantity, proof, token, maxCost);
    }

    /// @notice Mint to another wallet. The allowlist and per-wallet limit apply to the payer, not `to`.
    function mintTo(
        address to,
        uint256 phaseId,
        uint256 quantity,
        bytes32[] calldata proof,
        address token,
        uint256 maxCost
    ) external payable nonReentrant {
        _mintInPhase(to, phaseId, quantity, proof, token, maxCost);
    }

    function _mintInPhase(
        address to,
        uint256 phaseId,
        uint256 quantity,
        bytes32[] calldata proof,
        address token,
        uint256 maxCost
    ) internal {
        if (!isPhaseActive(phaseId)) revert PhaseNotActive();
        Phase storage ph = _phases[phaseId];
        if (ph.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProofLib.verifyCalldata(proof, ph.merkleRoot, leaf)) revert NotAllowlisted();
        }
        uint256 already = _minted[phasesEpoch][phaseId][msg.sender];
        if (ph.maxPerWallet != 0 && already + quantity > ph.maxPerWallet) revert WalletLimit();
        PaymentLib.checkUsable(_pay, registry, token);
        (bool priced, uint256 price) = PaymentLib.priceIn(ph.prices, token);
        if (!priced) revert TokenNotPriced();
        uint256 cost = price * quantity;
        if (token == PaymentLib.ETH) {
            if (msg.value != cost) revert WrongPayment();
            if (maxCost != 0 && cost > maxCost) revert ExceedsMaxCost();
        } else {
            if (msg.value != 0) revert WrongPayment();
            if (cost > maxCost) revert ExceedsMaxCost();
        }
        uint256 sold = _phaseMinted[phasesEpoch][phaseId] + quantity;
        if (ph.supplyCap != 0 && sold > ph.supplyCap) revert PhaseSoldOut();
        _phaseMinted[phasesEpoch][phaseId] = sold;
        _minted[phasesEpoch][phaseId][msg.sender] = already + quantity;
        PaymentLib.collect(token, cost);
        _pay.unsplit[token] += cost;
        uint256 first = _mintBatch(to, quantity);
        emit Minted(to, phaseId, first, quantity, token, cost);
    }

    /// @notice Free mints for the team, giveaways or migrations. They count toward `maxSupply`.
    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        if (ownerMinted + quantity > ownerReserve) revert ReserveExceeded();
        ownerMinted += quantity;
        uint256 first = _mintBatch(to, quantity);
        emit Minted(to, type(uint256).max, first, quantity, address(0), 0);
    }

    // ┌─────────────────────────┐
    // │        Proceeds         │
    // └─────────────────────────┘

    /// @notice Split the proceeds held in `token`: protocol cut to the treasury, vault cut to the vault (both
    ///         parked if refused), the rest to the owner's balance. Callable by anyone, so neither cut can be withheld.
    function distribute(address token) external nonReentrant {
        if (!_distribute(token)) revert NothingToWithdraw();
    }

    /// @notice Pay the owner its balance of `token` (address(0) = ETH), splitting any unsplit proceeds first.
    function withdraw(address token) external onlyOwner nonReentrant {
        bool split = _distribute(token);
        if (PaymentLib.payOwner(_pay, token, owner(), weth) == 0 && !split) revert NothingToWithdraw();
    }

    /// @notice `withdraw` for every token this drop has ever accepted.
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
        if (!any) revert NothingToWithdraw();
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
        PaymentLib.split(_pay, _terms(), token, amount);
        return true;
    }

    /// @notice Count `token` that reached this drop outside a mint (royalties, transfers) as proceeds, so the next
    ///         split shares it. Only tokens this drop has accepted. Anyone can call this.
    function sweepUntracked(address token) external nonReentrant {
        if (!_pay.isKnown[token]) revert PaymentLib.TokenNotAccepted(token);
        uint256 extra = PaymentLib.untracked(_pay, token);
        if (extra == 0) revert NothingToWithdraw();
        _pay.unsplit[token] += extra;
    }

    /// @notice Retry paying protocol cuts in `token` the treasury previously refused. Anyone can call this.
    function flushPendingProtocolCut(address token) external nonReentrant {
        PaymentLib.flushProtocol(_pay, treasury, token);
    }

    /// @notice Retry delivering vault cuts in `token` the vault previously rejected. Anyone can call this.
    /// @dev A parked cut under the vault's minimum can be topped up by `topUp` (ETH: msg.value == topUp; an ERC-20
    ///      is pulled from the caller): all of it goes to the vault, credited to this collection, and a total still
    ///      under the minimum reverts, which returns the top-up.
    function flushPendingVaultCut(address token, uint256 topUp) external payable nonReentrant {
        PaymentLib.flushVault(_pay, address(vault), token, topUp);
    }

    /// @notice Claim this collection's vault fees in `mode` and forward what the vault pays (INFER, IMD, ETH) to
    ///         the owner. `minEthOut` is the floor for ClaimMode.ETH.
    function claimVaultFees(ClaimMode mode, uint256 minEthOut)
        external
        onlyOwner
        nonReentrant
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        return PaymentLib.claimVaultFees(address(vault), mode, minEthOut, owner(), weth, true);
    }

    // ┌─────────────────────────┐
    // │     Payment views       │
    // └─────────────────────────┘

    function acceptedTokens() external view returns (address[] memory) {
        return _pay.accepted;
    }

    /// @notice Every token this drop has ever accepted (withdrawAll walks these).
    function knownTokens() external view returns (address[] memory) {
        return _pay.known;
    }

    function isAcceptedToken(address token) external view returns (bool) {
        return _pay.isAccepted[token];
    }

    /// @notice Price per piece of phase `phaseId` in `token`; `priced` is false if the phase doesn't sell for it.
    function priceOf(uint256 phaseId, address token) external view returns (bool priced, uint256 price) {
        if (phaseId >= _phases.length) return (false, 0);
        return PaymentLib.priceIn(_phases[phaseId].prices, token);
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

    function _terms() internal view returns (PaymentLib.Terms memory) {
        return PaymentLib.Terms({
            vault: address(vault), treasury: treasury, protocolBps: protocolBps, alignmentBps: alignmentBps
        });
    }

    // ┌─────────────────────────┐
    // │      Owner settings     │
    // └─────────────────────────┘

    /// @notice Replace the phase list. Per-wallet and per-phase counts start fresh (see `phasesEpoch`).
    function setPhases(Phase[] calldata newPhases) external onlyOwner {
        _setPhases(newPhases);
    }

    /// @notice Replace the token prices of one phase, keeping its counts.
    function setPhasePrices(uint256 phaseId, TokenPrice[] calldata prices) external onlyOwner {
        if (phaseId >= _phases.length) revert InvalidParams();
        PaymentLib.checkPrices(_pay, prices, true);
        TokenPrice[] storage stored = _phases[phaseId].prices;
        while (stored.length != 0) stored.pop();
        for (uint256 i; i < prices.length; ++i) {
            stored.push(prices[i]);
        }
        emit PhasePricesSet(phaseId, prices);
    }

    /// @notice Replace the accepted tokens (each on the registry allowlist). Balances already held in a removed
    ///         token stay withdrawable; phases can only sell for accepted tokens.
    function setAcceptedTokens(address[] calldata tokens) external onlyOwner {
        PaymentLib.setAccepted(_pay, registry, tokens);
    }

    /// @notice Update metadata. Setting a non-empty `baseURI` reveals the collection.
    function setMetadata(string calldata baseURI_, string calldata unrevealedURI_, string calldata contractURI_)
        external
        onlyOwner
    {
        if (metadataLocked) revert Locked();
        baseURI = baseURI_;
        unrevealedURI = unrevealedURI_;
        contractURI = contractURI_;
        emit MetadataUpdated(baseURI_, unrevealedURI_, contractURI_);
        emit BatchMetadataUpdate(1, maxSupply);
    }

    /// @notice Freeze metadata forever. Requires a revealed `baseURI`.
    function lockMetadata() external onlyOwner {
        if (bytes(baseURI).length == 0) revert InvalidParams();
        metadataLocked = true;
        emit MetadataLocked();
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (royaltyLocked) revert Locked();
        _setRoyalty(receiver, bps);
    }

    function _setRoyalty(address receiver, uint96 bps) internal {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltySet(receiver, bps);
    }

    function lockRoyalty() external onlyOwner {
        royaltyLocked = true;
        emit RoyaltyLocked();
    }

    /// @notice Disabled: the artist's share of every split is owed to owner(), so renouncing would strand it.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev Accepts vault fee payouts (forwarded in `claimVaultFees`) and secondary royalties. Royalties count as
    ///      proceeds once someone calls `sweepUntracked(address(0))`.
    receive() external payable { }

    // ┌─────────────────────────┐
    // │        Internals        │
    // └─────────────────────────┘

    function _mintBatch(address to, uint256 quantity) internal returns (uint256 first) {
        if (quantity == 0) revert InvalidParams();
        first = totalSupply + 1;
        uint256 last = totalSupply + quantity;
        // The unused reserve stays out of reach of phases. ownerMint has already counted its own pieces.
        if (last + ownerReserve - ownerMinted > maxSupply) revert SoldOut();
        totalSupply = last;
        for (uint256 id = first; id <= last; ++id) {
            _mint(to, id);
        }
    }

    function _setPhases(Phase[] memory newPhases) internal {
        if (newPhases.length > MAX_PHASES) revert InvalidParams();
        delete _phases;
        ++phasesEpoch;
        for (uint256 i; i < newPhases.length; ++i) {
            Phase memory ph = newPhases[i];
            if (ph.end != 0 && ph.end <= ph.start) revert InvalidParams();
            PaymentLib.checkPrices(_pay, ph.prices, true);
            Phase storage stored = _phases.push();
            stored.start = ph.start;
            stored.end = ph.end;
            stored.maxPerWallet = ph.maxPerWallet;
            stored.merkleRoot = ph.merkleRoot;
            stored.supplyCap = ph.supplyCap;
            for (uint256 j; j < ph.prices.length; ++j) {
                stored.prices.push(ph.prices[j]);
            }
        }
        emit PhasesSet(newPhases);
    }
}
