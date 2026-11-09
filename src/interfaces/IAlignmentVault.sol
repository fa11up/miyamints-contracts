// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "v4-core/types/Currency.sol";

/// @notice How a benefactor takes its vault fees (docs/IMD-INFER-VAULT.md). TOKENS is the default.
/// @dev TOKENS: INFER + IMD (+ any ETH dust) as is. ETH: INFER -> IMD -> ETH, checked against `minEthOut`.
///      REINVEST: the claim's INFER + IMD go back into the vault's position as new shares for the benefactor.
enum ClaimMode {
    TOKENS,
    ETH,
    REINVEST
}

/**
 * @title IAlignmentVault (v2)
 * @notice Alignment vault interface: collections send it their vault share in the token paid (ETH or an ERC-20 on the
 *         registry's payment-token allowlist); the vault turns everything into liquidity in its alignment pool and pays
 *         the position's fees to benefactors pro rata to shares.
 * @dev Shares are permanent: they are never redeemable for liquidity, only for fees.
 */
interface IAlignmentVault {
    // ========== Events ==========

    /// @notice A contribution was booked for `benefactor` (token address(0) = ETH).
    event ContributionReceived(address indexed benefactor, address indexed token, uint256 amount);

    /// @notice A benefactor's fees were paid (to it or its delegate) in `mode`.
    event FeesClaimed(address indexed benefactor, ClaimMode mode, uint256 inferOut, uint256 imdOut, uint256 ethOut);

    /// @notice Fees in `token` (address(0) = ETH dust) were credited to current shareholders.
    event FeesAccumulated(address indexed token, uint256 amount);

    event VaultPolicyUpdated(bytes32 indexed key, bytes value);

    // ========== Contributions ==========

    /**
     * @notice Book a contribution for `benefactor`.
     * @dev ETH (`currency` = address(0)): `msg.value == amount`. ERC-20: `msg.value == 0`, the token must be on the
     *      registry allowlist, and the vault pulls exactly `amount` from msg.sender with `transferFrom` (the caller
     *      approves the vault first) and checks the balance it received. Anything else reverts.
     */
    function receiveContribution(Currency currency, uint256 amount, address benefactor) external payable;

    /// @notice Direct ETH contributions, credited to msg.sender.
    receive() external payable;

    // ========== Fee claims ==========

    /**
     * @notice Claim the caller's fees, paid to the caller or its delegate.
     * @param mode TOKENS, ETH or REINVEST (see ClaimMode)
     * @param minEthOut ETH mode: the least ETH to receive (non-zero). REINVEST: the least shares to mint. TOKENS: ignored.
     */
    function claimFees(ClaimMode mode, uint256 minEthOut)
        external
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut);

    /// @notice Fees `benefactor` could claim now from fees already collected from the position.
    function claimable(address benefactor) external view returns (uint256 infer, uint256 imd, uint256 eth);

    /// @notice `benefactor`'s contribution in `token` still waiting to be converted (0 once all converted; a partial
    ///         conversion of the token converts the same fraction of every benefactor's balance in it).
    function pendingOf(address benefactor, address token) external view returns (uint256);

    // ========== Shares ==========

    function getBenefactorShares(address benefactor) external view returns (uint256);

    function totalShares() external view returns (uint256);

    // ========== Vault info ==========

    function vaultType() external view returns (string memory);

    function description() external view returns (string memory);

    function supportsCapability(bytes32 capability) external view returns (bool);

    function currentPolicy() external view returns (bytes memory);

    function validateCompliance(address instance) external view returns (bool);

    // ========== Delegation ==========

    /// @notice Route the caller's fee claims to `delegate` (address(0) removes it). Shares stay with the caller.
    function delegateBenefactor(address delegate) external;

    function getBenefactorDelegate(address benefactor) external view returns (address);

    /// @notice Claim for several benefactors that delegate to the caller; one payout to the caller. TOKENS or ETH only.
    function claimFeesAsDelegate(address[] calldata benefactors, ClaimMode mode, uint256 minEthOut)
        external
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut);
}
