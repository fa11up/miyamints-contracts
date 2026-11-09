// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { IEligibilityGate } from "./interfaces/IMarkets.sol";

/**
 * @title EligibilityGate
 * @notice Checks short-lived EIP-712 eligibility passes signed by the KYC/geo provider's key. A pass names one
 *         wallet, an issue time and an expiry no more than MAX_TTL later; the EIP-712 domain binds it to this
 *         chain and this contract. Only staking is gated: claims and refunds never consult the gate.
 *
 *         The owner (a multisig) can rotate the signer. The owner or the signer can revoke a wallet, which
 *         refuses every pass issued for it before the revocation (KYC withdrawn, self-exclusion). Neither can
 *         move funds; the worst either can do is stop new stakes.
 */
contract EligibilityGate is Ownable, EIP712, IEligibilityGate {
    bytes32 public constant PASS_TYPEHASH =
        keccak256("EligibilityPass(address wallet,uint64 issuedAt,uint64 expiresAt)");
    /// @dev Longest a pass may live, from issue to expiry.
    uint64 public constant MAX_TTL = 1 days;

    address public signer;
    /// @notice Passes for a wallet issued before this time are refused.
    mapping(address wallet => uint64) public notBefore;

    event SignerSet(address signer);
    event Revoked(address indexed wallet, uint64 notBefore);

    error InvalidAddress();
    error NotAuthorized();
    error WrongWallet();
    error PassExpired();
    error PassNotYetValid();
    error PassTooLong();
    error PassRevoked();
    error InvalidSignature();

    constructor(address owner_, address signer_) {
        _initializeOwner(owner_);
        _setSigner(signer_);
    }

    function setSigner(address signer_) external onlyOwner {
        _setSigner(signer_);
    }

    /// @notice Refuse every pass issued for `wallet` up to now.
    function revoke(address wallet) external {
        if (msg.sender != owner() && msg.sender != signer) revert NotAuthorized();
        notBefore[wallet] = uint64(block.timestamp) + 1;
        emit Revoked(wallet, uint64(block.timestamp) + 1);
    }

    /// @notice The digest the signer signs for `pass`.
    function passDigest(MarketTypes.EligibilityPass calldata pass) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(PASS_TYPEHASH, pass.wallet, pass.issuedAt, pass.expiresAt)));
    }

    /// @inheritdoc IEligibilityGate
    function check(address wallet, MarketTypes.EligibilityPass calldata pass, bytes calldata sig) external view {
        if (pass.wallet != wallet) revert WrongWallet();
        if (block.timestamp > pass.expiresAt) revert PassExpired();
        if (pass.issuedAt > block.timestamp) revert PassNotYetValid();
        if (pass.expiresAt < pass.issuedAt || pass.expiresAt - pass.issuedAt > MAX_TTL) revert PassTooLong();
        if (pass.issuedAt < notBefore[wallet]) revert PassRevoked();
        address recovered = ECDSA.tryRecoverCalldata(passDigest(pass), sig);
        if (recovered == address(0) || recovered != signer) revert InvalidSignature();
    }

    function _setSigner(address signer_) internal {
        if (signer_ == address(0)) revert InvalidAddress();
        signer = signer_;
        emit SignerSet(signer_);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Miya Markets Eligibility", "1");
    }
}
