// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "solady/tokens/ERC721.sol";
import { ERC2981 } from "solady/tokens/ERC2981.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { LibString } from "solady/utils/LibString.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import { SmartTransferLib } from "../../libraries/SmartTransferLib.sol";
import { RevenueSplitLib } from "../../shared/libraries/RevenueSplitLib.sol";

/**
 * @title ERC721DropInstance
 * @notice Fixed-price PFP drop: sequential ids from 1 to `maxSupply`, up to 8 mint phases (each with a window,
 *         price, optional Merkle allowlist and per-wallet cap), owner reserve mints, delayed reveal and a one-way
 *         metadata lock.
 *
 *         Mint proceeds stay here until anyone calls `withdraw()`, which splits them with the terms snapshotted at
 *         launch: `protocolBps` to the treasury, `alignmentBps` to the collection's alignment vault, the rest to
 *         the owner. If the vault rejects a contribution, its cut is parked in `pendingVaultCut` and can be
 *         retried with `flushPendingVaultCut()`; it is never redirected to the owner.
 */
contract ERC721DropInstance is ERC721, ERC2981, Ownable, ReentrancyGuard {
    using LibString for uint256;

    struct Phase {
        uint64 start; // unix seconds, inclusive
        uint64 end; // unix seconds, exclusive; 0 = no end
        uint128 price; // wei per token
        uint32 maxPerWallet; // 0 = unlimited
        bytes32 merkleRoot; // 0 = public; else leaf = keccak256(bytes.concat(keccak256(abi.encode(minter))))
        uint32 supplyCap; // most this phase can sell in total; 0 = no cap beyond maxSupply
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
        Phase[] phases;
    }

    uint256 public constant MAX_PHASES = 8;

    address public immutable treasury;
    IAlignmentVault public immutable vault;
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

    Phase[] internal _phases;
    /// @dev Bumped by every setPhases so per-wallet counters never carry over to a different phase list.
    uint256 public phasesEpoch;
    mapping(uint256 epoch => mapping(uint256 phaseId => mapping(address minter => uint256))) internal _minted;

    /// @dev Total sold per phase, scoped to the phase list like `_minted`.
    mapping(uint256 epoch => mapping(uint256 phaseId => uint256)) internal _phaseMinted;
    uint256 public totalSupply;
    uint256 public ownerMinted;
    uint256 public pendingVaultCut;

    event PhasesSet(Phase[] phases);
    event Minted(address indexed to, uint256 indexed phaseId, uint256 firstId, uint256 quantity, uint256 paid);
    event MetadataUpdated(string baseURI, string unrevealedURI, string contractURI);
    event MetadataLocked();
    /// @dev EIP-4906: tells marketplaces to refresh every token's metadata.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event RoyaltyLocked();
    event Withdrawn(uint256 toOwner, uint256 toVault, uint256 toProtocol);
    event VaultContributionFailed(uint256 amount);

    error InvalidParams();
    error PhaseNotActive();
    error NotAllowlisted();
    error WalletLimit();
    error SoldOut();
    error PhaseSoldOut();
    error ReserveExceeded();
    error WrongPayment();
    error Locked();
    error NothingToWithdraw();
    error RenounceDisabled();

    constructor(
        InitParams memory p,
        address owner_,
        address treasury_,
        address vault_,
        address weth_,
        uint16 protocolBps_,
        uint16 alignmentBps_
    ) {
        if (p.maxSupply == 0 || bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidParams();
        if (owner_ == address(0) || treasury_ == address(0) || vault_ == address(0)) revert InvalidParams();
        if (uint256(protocolBps_) + alignmentBps_ > RevenueSplitLib.BPS) revert InvalidParams();
        if (p.ownerReserve > p.maxSupply) revert InvalidParams();
        _initializeOwner(owner_);
        treasury = treasury_;
        vault = IAlignmentVault(payable(vault_));
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
        if (p.royaltyReceiver != address(0)) _setDefaultRoyalty(p.royaltyReceiver, p.royaltyBps);
        _setPhases(p.phases);
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
        Phase memory ph = _phases[phaseId];
        return block.timestamp >= ph.start && (ph.end == 0 || block.timestamp < ph.end);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return ERC721.supportsInterface(id) || ERC2981.supportsInterface(id) || id == 0x49064906; // EIP-4906
    }

    // ┌─────────────────────────┐
    // │         Minting         │
    // └─────────────────────────┘

    function mint(uint256 phaseId, uint256 quantity, bytes32[] calldata proof) external payable nonReentrant {
        _mintInPhase(msg.sender, phaseId, quantity, proof);
    }

    /// @notice Mint to another wallet. The allowlist and per-wallet limit apply to the payer, not `to`.
    function mintTo(address to, uint256 phaseId, uint256 quantity, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        _mintInPhase(to, phaseId, quantity, proof);
    }

    function _mintInPhase(address to, uint256 phaseId, uint256 quantity, bytes32[] calldata proof) internal {
        if (!isPhaseActive(phaseId)) revert PhaseNotActive();
        Phase memory ph = _phases[phaseId];
        if (ph.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
            if (!MerkleProofLib.verifyCalldata(proof, ph.merkleRoot, leaf)) revert NotAllowlisted();
        }
        uint256 already = _minted[phasesEpoch][phaseId][msg.sender];
        if (ph.maxPerWallet != 0 && already + quantity > ph.maxPerWallet) revert WalletLimit();
        if (msg.value != uint256(ph.price) * quantity) revert WrongPayment();
        uint256 sold = _phaseMinted[phasesEpoch][phaseId] + quantity;
        if (ph.supplyCap != 0 && sold > ph.supplyCap) revert PhaseSoldOut();
        _phaseMinted[phasesEpoch][phaseId] = sold;
        _minted[phasesEpoch][phaseId][msg.sender] = already + quantity;
        uint256 first = _mintBatch(to, quantity);
        emit Minted(to, phaseId, first, quantity, msg.value);
    }

    /// @notice Free mints for the team, giveaways or migrations. They count toward `maxSupply`.
    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        if (ownerMinted + quantity > ownerReserve) revert ReserveExceeded();
        ownerMinted += quantity;
        uint256 first = _mintBatch(to, quantity);
        emit Minted(to, type(uint256).max, first, quantity, 0);
    }

    // ┌─────────────────────────┐
    // │        Proceeds         │
    // └─────────────────────────┘

    /// @notice Split the mint proceeds held here. Callable by anyone, so neither cut can be withheld.
    function withdraw() external nonReentrant {
        uint256 amount = address(this).balance - pendingVaultCut;
        if (amount == 0) revert NothingToWithdraw();
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount, protocolBps, alignmentBps);
        if (s.protocolCut != 0) SafeTransferLib.safeTransferETH(treasury, s.protocolCut);
        uint256 sentToVault;
        if (s.vaultCut != 0) {
            try vault.receiveContribution{ value: s.vaultCut }(Currency.wrap(address(0)), s.vaultCut, address(this)) {
                sentToVault = s.vaultCut;
            } catch {
                pendingVaultCut += s.vaultCut;
                emit VaultContributionFailed(s.vaultCut);
            }
        }
        if (s.remainder != 0) SmartTransferLib.smartTransferETH(owner(), s.remainder, weth);
        emit Withdrawn(s.remainder, sentToVault, s.protocolCut);
    }

    /// @notice Retry delivering vault cuts the vault previously rejected.
    function flushPendingVaultCut() external nonReentrant {
        uint256 pending = pendingVaultCut;
        if (pending == 0) revert NothingToWithdraw();
        pendingVaultCut = 0;
        vault.receiveContribution{ value: pending }(Currency.wrap(address(0)), pending, address(this));
    }

    /// @notice Claim this collection's share of vault LP fees and send it to the owner.
    function claimVaultFees() external onlyOwner nonReentrant returns (uint256 claimed) {
        claimed = vault.claimFees();
        if (claimed == 0) revert NothingToWithdraw();
        SmartTransferLib.smartTransferETH(owner(), claimed, weth);
    }

    // ┌─────────────────────────┐
    // │      Owner settings     │
    // └─────────────────────────┘

    function setPhases(Phase[] calldata newPhases) external onlyOwner {
        _setPhases(newPhases);
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
        _setDefaultRoyalty(receiver, bps);
    }

    function lockRoyalty() external onlyOwner {
        royaltyLocked = true;
        emit RoyaltyLocked();
    }

    /// @notice Disabled: mint proceeds are sent to owner() by the permissionless withdraw(), so renouncing would
    ///         let anyone burn the artist's share.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev Accepts vault fee payouts (forwarded in `claimVaultFees`) and secondary royalties. Anything that
    ///      stays here is split by the next `withdraw()`.
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
            _phases.push(ph);
        }
        emit PhasesSet(newPhases);
    }
}
