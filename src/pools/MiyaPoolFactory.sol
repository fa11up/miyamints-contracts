// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MiyaPool } from "./MiyaPool.sol";

/**
 * @title MiyaPoolFactory
 * @notice Permissionless, ownerless factory for MiyaPool. One pool per (collection, redeem mode), so nobody can
 *         squat a collection with an unwanted mode. Pools deploy with CREATE2; with the factory itself deployed
 *         at the same address on every chain, a collection's pool address is the same everywhere.
 */
contract MiyaPoolFactory {
    bytes4 internal constant ERC721_ID = 0x80ac58cd;
    bytes4 internal constant ERC1155_ID = 0xd9b67a26;

    mapping(address collection => mapping(MiyaPool.RedeemMode mode => address pool)) public poolOf;
    address[] public allPools;

    event PoolCreated(
        address indexed collection, address indexed pool, MiyaPool.Kind kind, MiyaPool.RedeemMode mode, address creator
    );

    error PoolExists(address pool);
    error UnsupportedCollection();
    error RandomRequiresERC721();

    function createPool(address collection, MiyaPool.RedeemMode mode) external returns (address pool) {
        if (poolOf[collection][mode] != address(0)) revert PoolExists(poolOf[collection][mode]);
        MiyaPool.Kind kind = _detectKind(collection);
        if (kind == MiyaPool.Kind.ERC1155 && mode == MiyaPool.RedeemMode.RANDOM) revert RandomRequiresERC721();
        pool = address(new MiyaPool{ salt: _salt(collection, mode) }(collection, kind, mode));
        poolOf[collection][mode] = pool;
        allPools.push(pool);
        emit PoolCreated(collection, pool, kind, mode, msg.sender);
    }

    /// @notice Address the pool for `collection` and `mode` has, or will have once created.
    function predictPool(address collection, MiyaPool.Kind kind, MiyaPool.RedeemMode mode)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(MiyaPool).creationCode, abi.encode(collection, kind, mode)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(collection, mode), initHash))))
        );
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function _salt(address collection, MiyaPool.RedeemMode mode) internal pure returns (bytes32) {
        return keccak256(abi.encode(collection, mode));
    }

    function _detectKind(address collection) internal view returns (MiyaPool.Kind) {
        if (_supports(collection, ERC721_ID)) return MiyaPool.Kind.ERC721;
        if (_supports(collection, ERC1155_ID)) return MiyaPool.Kind.ERC1155;
        revert UnsupportedCollection();
    }

    function _supports(address target, bytes4 id) internal view returns (bool) {
        if (target.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            target.staticcall{ gas: 30_000 }(abi.encodeWithSelector(0x01ffc9a7, id));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }
}
