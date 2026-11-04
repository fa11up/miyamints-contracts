// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

interface IERC721Pool {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external;
}

interface IERC1155Pool {
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}

/**
 * @title MiyaPool
 * @notice Zero-fee NFT pool in the style of NFTX v2. Each NFT (or ERC1155 unit) held by the pool
 *         backs exactly 1e18 pool tokens, so the accounting invariant is
 *
 *             totalSupply() + UNIT * pendingUnits == UNIT * heldUnits()
 *
 *         There are no fees, no admin, no pause and no upgrade path. The redeem mode is fixed at creation:
 *         - TARGETED: holders burn 1e18 tokens to withdraw a token id of their choice.
 *         - RANDOM (ERC721 only): holders burn tokens now and receive pseudo-random ids later, chosen with the
 *           hash of a block mined after the commit. Anyone can reveal, oldest commit first.
 *
 * @dev RANDOM-mode limitations (documented for the audit):
 *      - Randomness is a future block hash; block producers (the sequencer on L2s) can influence it.
 *      - If a commit is not revealed within the block-hash window (256 blocks via BLOCKHASH, 8191 via the
 *        EIP-2935 history contract) it is re-armed to a new future block. A committer who waits out the window
 *        therefore gets a re-roll; the long EIP-2935 window makes this slow but not impossible.
 *      - Each commit draws only from ids deposited before it, and reveals run in commit order, so once a target
 *        block is mined the pick is fixed: later deposits and the choice of reveal order cannot move it.
 *      - Because reveals are ordered, a commit must never block the ones after it: the recipient cannot be zero,
 *        a commit is capped at MAX_COMMIT_UNITS, and an id the collection refuses to transfer is escrowed.
 *      NFTs sent with plain `transferFrom` (no receiver hook) are not tracked and cannot be recovered.
 */
contract MiyaPool is ERC20, ReentrancyGuard {
    using EnumerableSetLib for EnumerableSetLib.Uint256Set;

    enum Kind {
        ERC721,
        ERC1155
    }

    enum RedeemMode {
        TARGETED,
        RANDOM
    }

    struct Commit {
        address recipient;
        uint64 targetBlock;
        uint32 amount;
        uint32 queueEnd;
    }

    uint256 public constant UNIT = 1e18;
    /// @dev EIP-2935 block-hash history contract, same address on every chain that supports it.
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 internal constant HISTORY_WINDOW = 8191;
    /// @notice Most ids one commit can draw, so a reveal always fits in a block.
    uint256 public constant MAX_COMMIT_UNITS = 50;
    /// @notice Gas each reveal transfer may use: above a standard transfer's cost, and low enough that the largest
    ///         commit fits in one transaction under mainnet's gas cap even if every transfer burns all of it.
    uint256 public constant REVEAL_TRANSFER_GAS = 200_000;

    address public immutable factory;
    address public immutable collection;
    Kind public immutable kind;
    RedeemMode public immutable mode;

    /// @dev ERC721: ids held. ERC1155: ids with a nonzero held balance.
    EnumerableSetLib.Uint256Set internal _ids;
    /// @dev ERC1155 only: units held per id.
    mapping(uint256 id => uint256 units) public unitsOf;
    /// @dev ERC1155 only: total units held.
    uint256 internal _units1155;

    uint256 public pendingUnits;
    uint256 public nextCommitId;
    mapping(uint256 commitId => Commit) public commits;
    /// @notice The only commit that can be revealed now.
    uint256 public nextRevealId;
    /// @notice RANDOM only: ids the collection refused to transfer at reveal, claimable by their recipient.
    mapping(uint256 id => address recipient) public escrowedTo;

    /// @dev RANDOM only: ids in deposit order. Live entries are [_queueHead, _queueTail); a commit draws from
    ///      [_queueHead, queueEnd), which stays exactly the ids it could draw at commit minus those already drawn.
    mapping(uint256 position => uint256 id) internal _queue;
    uint256 internal _queueHead;
    uint256 internal _queueTail;

    event Deposited(address indexed from, address indexed to, uint256[] ids, uint256[] amounts);
    event Redeemed(address indexed by, address indexed to, uint256[] ids, uint256[] amounts);
    event RedeemCommitted(uint256 indexed commitId, address indexed by, address indexed to, uint256 amount, uint256 targetBlock);
    event RedeemRearmed(uint256 indexed commitId, uint256 targetBlock);
    event RedeemRevealed(uint256 indexed commitId, uint256[] ids);
    event RedeemEscrowed(uint256 indexed commitId, address indexed recipient, uint256 id);
    event EscrowClaimed(address indexed recipient, address indexed to, uint256 id);

    error NotCollection();
    error WrongMode();
    error EmptyRequest();
    error LengthMismatch();
    error NotHeld(uint256 id);
    error InsufficientHeld();
    error TooEarly();
    error UnknownCommit();
    error NotNextCommit();
    error CommitTooLarge();
    error InvalidRecipient();
    error NotEscrowed();
    error AlreadyHeld(uint256 id);
    error RevealGasTooLow();
    error TransferNotReceived(uint256 id);

    constructor(address _collection, Kind _kind, RedeemMode _mode) {
        factory = msg.sender;
        collection = _collection;
        kind = _kind;
        mode = _mode;
    }

    // ┌─────────────────────────┐
    // │        Metadata         │
    // └─────────────────────────┘

    function name() public view override returns (string memory) {
        return string.concat("miya pool: ", _collectionString(0x06fdde03, "NFT"));
    }

    function symbol() public view override returns (string memory) {
        return string.concat("m", _collectionString(0x95d89b41, "NFT"));
    }

    /// @notice Units currently backing tokens or pending commits.
    function heldUnits() public view returns (uint256) {
        return kind == Kind.ERC721 ? _ids.length() : _units1155;
    }

    /// @notice Ids currently held (ERC1155: ids with a nonzero balance). Paginate with `heldIdsCount`.
    function heldIds(uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        uint256 len = _ids.length();
        if (start >= len) return ids;
        if (count > len - start) count = len - start;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) ids[i] = _ids.at(start + i);
    }

    function heldIdsCount() external view returns (uint256) {
        return _ids.length();
    }

    function isHeld(uint256 id) external view returns (bool) {
        return _ids.contains(id);
    }

    // ┌─────────────────────────┐
    // │        Deposits         │
    // └─────────────────────────┘

    /// @notice Pull NFTs from the caller (approval required) and mint UNIT tokens per unit to `to`.
    /// @dev Minting happens in the receiver hooks, so direct `safeTransferFrom` deposits work the same way.
    function deposit(uint256[] calldata ids, uint256[] calldata amounts, address to) external nonReentrant {
        if (ids.length == 0) revert EmptyRequest();
        bytes memory data = abi.encode(to);
        if (kind == Kind.ERC721) {
            for (uint256 i; i < ids.length; ++i) {
                IERC721Pool(collection).safeTransferFrom(msg.sender, address(this), ids[i], data);
            }
        } else {
            if (amounts.length != ids.length) revert LengthMismatch();
            IERC1155Pool(collection).safeBatchTransferFrom(msg.sender, address(this), ids, amounts, data);
        }
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata data) external returns (bytes4) {
        if (msg.sender != collection || kind != Kind.ERC721) revert NotCollection();
        if (IERC721Pool(collection).ownerOf(id) != address(this)) revert TransferNotReceived(id);
        if (!_ids.add(id)) revert AlreadyHeld(id);
        if (mode == RedeemMode.RANDOM) _queue[_queueTail++] = id;
        address to = _recipient(from, data);
        _mint(to, UNIT);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = 1;
        emit Deposited(from, to, ids, amounts);
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address from, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (bytes4)
    {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
        _receive1155(from, ids, amounts, data);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bytes4) {
        _receive1155(from, ids, amounts, data);
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC165
            || id == 0x150b7a02 // ERC721Receiver
            || id == 0x4e2312e0; // ERC1155Receiver
    }

    // ┌─────────────────────────┐
    // │    Targeted redeems     │
    // └─────────────────────────┘

    /// @notice Burn UNIT tokens per unit and withdraw the chosen ids to `to`.
    function redeem(uint256[] calldata ids, uint256[] calldata amounts, address to) external nonReentrant {
        if (to == address(this)) revert InvalidRecipient();
        if (mode != RedeemMode.TARGETED) revert WrongMode();
        if (ids.length == 0) revert EmptyRequest();
        if (kind == Kind.ERC721) {
            _burn(msg.sender, UNIT * ids.length);
            for (uint256 i; i < ids.length; ++i) {
                if (!_ids.remove(ids[i])) revert NotHeld(ids[i]);
            }
            uint256[] memory ones = new uint256[](ids.length);
            for (uint256 i; i < ids.length; ++i) {
                ones[i] = 1;
                IERC721Pool(collection).transferFrom(address(this), to, ids[i]);
            }
            emit Redeemed(msg.sender, to, ids, ones);
        } else {
            if (amounts.length != ids.length) revert LengthMismatch();
            uint256 total;
            for (uint256 i; i < ids.length; ++i) {
                uint256 have = unitsOf[ids[i]];
                if (amounts[i] == 0 || have < amounts[i]) revert NotHeld(ids[i]);
                unchecked {
                    unitsOf[ids[i]] = have - amounts[i];
                }
                if (have == amounts[i]) _ids.remove(ids[i]);
                total += amounts[i];
            }
            _units1155 -= total;
            _burn(msg.sender, UNIT * total);
            IERC1155Pool(collection).safeBatchTransferFrom(address(this), to, ids, amounts, "");
            emit Redeemed(msg.sender, to, ids, amounts);
        }
    }

    // ┌─────────────────────────┐
    // │     Random redeems      │
    // └─────────────────────────┘

    /// @notice Burn `amount` * UNIT tokens now; `amount` random ids go to `to` once the commit is revealed.
    function commitRedeem(uint256 amount, address to) external nonReentrant returns (uint256 commitId) {
        if (mode != RedeemMode.RANDOM) revert WrongMode();
        if (amount == 0) revert EmptyRequest();
        if (amount > MAX_COMMIT_UNITS) revert CommitTooLarge();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        uint256 held = _ids.length();
        if (held < pendingUnits + amount) revert InsufficientHeld();
        _burn(msg.sender, UNIT * amount);
        pendingUnits += amount;
        commitId = nextCommitId++;
        uint256 target = block.number + 1;
        commits[commitId] = Commit(to, uint64(target), uint32(amount), uint32(_queueTail));
        emit RedeemCommitted(commitId, msg.sender, to, amount, target);
    }

    /// @notice Settle the oldest unsettled commit. Callable by anyone once its target block is mined.
    function revealRedeem(uint256 commitId) external nonReentrant {
        Commit memory c = commits[commitId];
        if (c.amount == 0) revert UnknownCommit();
        if (commitId != nextRevealId) revert NotNextCommit();
        if (block.number <= c.targetBlock) revert TooEarly();
        bytes32 seed = _blockHash(c.targetBlock);
        if (seed == bytes32(0)) {
            uint256 target = block.number + 1;
            commits[commitId].targetBlock = uint64(target);
            emit RedeemRearmed(commitId, target);
            return;
        }
        delete commits[commitId];
        nextRevealId = commitId + 1;
        pendingUnits -= c.amount;

        uint256[] memory picked = new uint256[](c.amount);
        uint256 head = _queueHead;
        for (uint256 i; i < c.amount; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, address(this), commitId, i)));
            uint256 pos = head + r % (c.queueEnd - head);
            uint256 id = _queue[pos];
            _queue[pos] = _queue[head];
            delete _queue[head];
            ++head;
            _ids.remove(id);
            picked[i] = id;
        }
        _queueHead = head;
        for (uint256 i; i < picked.length; ++i) {
            // Capped so a recipient the collection calls can't burn the gas the rest of the reveal needs. The check
            // stops a revealer sending too little gas to force an id into escrow.
            if (gasleft() < REVEAL_TRANSFER_GAS + REVEAL_TRANSFER_GAS / 32) revert RevealGasTooLow();
            try IERC721Pool(collection).transferFrom{ gas: REVEAL_TRANSFER_GAS }(address(this), c.recipient, picked[i]) {}
            catch {
                escrowedTo[picked[i]] = c.recipient;
                emit RedeemEscrowed(commitId, c.recipient, picked[i]);
            }
        }
        emit RedeemRevealed(commitId, picked);
    }

    /// @notice Take an id the collection refused to send to the caller at reveal, to any address.
    function claimEscrowed(uint256 id, address to) external nonReentrant {
        if (escrowedTo[id] != msg.sender) revert NotEscrowed();
        if (to == address(this)) revert InvalidRecipient();
        delete escrowedTo[id];
        IERC721Pool(collection).transferFrom(address(this), to, id);
        emit EscrowClaimed(msg.sender, to, id);
    }

    // ┌─────────────────────────┐
    // │        Internals        │
    // └─────────────────────────┘

    function _receive1155(address from, uint256[] memory ids, uint256[] memory amounts, bytes calldata data) internal {
        if (msg.sender != collection || kind != Kind.ERC1155) revert NotCollection();
        if (ids.length != amounts.length) revert LengthMismatch();
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            if (amounts[i] == 0) continue;
            unitsOf[ids[i]] += amounts[i];
            _ids.add(ids[i]);
            total += amounts[i];
        }
        _units1155 += total;
        address to = _recipient(from, data);
        if (total != 0) _mint(to, UNIT * total);
        emit Deposited(from, to, ids, amounts);
    }

    function _recipient(address from, bytes calldata data) internal view returns (address to) {
        if (data.length == 32) to = abi.decode(data, (address));
        if (to == address(0)) to = from;
        // address(0): a safe mint straight into the pool. address(this): a transfer from the pool to itself.
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }

    function _blockHash(uint256 n) internal view returns (bytes32 h) {
        if (block.number - n <= 256) return blockhash(n);
        if (block.number - n > HISTORY_WINDOW || HISTORY.code.length == 0) return bytes32(0);
        (bool ok, bytes memory ret) = HISTORY.staticcall(abi.encode(n));
        if (ok && ret.length == 32) h = abi.decode(ret, (bytes32));
    }

    function _collectionString(bytes4 selector, string memory fallback_) internal view returns (string memory) {
        (bool ok, bytes memory ret) = collection.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length < 64) return fallback_;
        return abi.decode(ret, (string));
    }
}
