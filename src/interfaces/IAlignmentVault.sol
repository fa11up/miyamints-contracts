// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title IAlignmentVault
 * @notice Standard interface for alignment vaults compatible with ms2fun ecosystem
 * @dev All vaults must implement this interface to be approved by governance
 *
 * Design Philosophy:
 * - Vaults receive alignment taxes from project instances
 * - Vaults track contributors as "benefactors" and issue proportional shares
 * - Benefactors can claim accumulated fees based on their share percentage
 * - Vaults are responsible for yield generation strategy (V4 LP, Aave, Curve, etc.)
 * - Instances remain vault-agnostic and interact only via this interface
 *
 * Compliance Requirements:
 * 1. Must accept ETH via receiveContribution() and receive()
 * 2. Must track benefactor contributions and issue shares
 * 3. Must allow benefactors to claim proportional fees
 * 4. Must emit standard events for transparency
 * 5. Must declare vaultType() for governance classification
 */
interface IAlignmentVault {
    // ========== Events ==========

    /**
     * @notice Emitted when a benefactor contributes ETH to the vault
     * @param benefactor Address credited for the contribution
     * @param amount ETH amount received
     */
    event ContributionReceived(address indexed benefactor, uint256 amount);

    /**
     * @notice Emitted when a benefactor claims accumulated fees
     * @param benefactor Address that claimed fees
     * @param ethAmount ETH amount transferred to benefactor
     */
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);

    /**
     * @notice Emitted when vault accumulates new fees from yield generation
     * @param amount New fees added to vault's accumulated total
     */
    event FeesAccumulated(uint256 amount);

    // ========== Fee Reception ==========

    /**
     * @notice Receive alignment contributions from project instances, hooks, or other vaults
     * @dev Called by any registered contributor routing fees to this vault.
     *      - V4 hooks call this after collecting swap taxes
     *      - ERC1155 instances call this during creator withdrawals
     *      - Meta-vaults call this when routing their alignment cut
     *      - Must track 'benefactor' as the contributor (not msg.sender)
     *      - Must emit ContributionReceived event
     *
     * @param currency Currency of the contribution (native ETH = address(0), or ERC20)
     * @param amount Amount received (in wei or token units)
     * @param benefactor Address to credit for this contribution
     */
    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable;

    /**
     * @notice Receive native ETH contributions via fallback
     * @dev Must track msg.sender as benefactor when ETH sent directly
     *      Implementation should call _trackBenefactorContribution(msg.sender, msg.value)
     *      Used when instances send ETH without calling receiveContribution()
     */
    receive() external payable;

    // ========== Fee Claiming ==========

    /**
     * @notice Claim accumulated fees for caller
     * @dev Must pay the caller's pro-rata share of fees earned WHILE they held shares.
     *      Recommended accounting (MasterChef-style): accFeePerShare grows by fees ÷ totalShares on every
     *      fee distribution; each benefactor tracks rewardDebt = shares × accFeePerShare and pending fees
     *      are settled before ANY change to their shares, so new shares neither dilute nor erase fees
     *      earned earlier.
     *
     * @return ethClaimed Amount of ETH transferred to caller
     */
    function claimFees() external returns (uint256 ethClaimed);

    /**
     * @notice Calculate claimable amount for benefactor without claiming
     * @dev Read-only version of claimFees() for UI/integration queries
     *      Returns what claimFees() would pay now from fees already collected
     *
     * @param benefactor Address to query
     * @return Amount of ETH currently claimable by this benefactor
     */
    function calculateClaimableAmount(address benefactor) external view returns (uint256);

    // ========== Share Queries ==========

    /**
     * @notice Get benefactor's total historical contribution
     * @dev Used for leaderboards and "bragging rights"
     *      This is cumulative lifetime contribution, never decreases
     *
     * @param benefactor Address to query
     * @return Total ETH contributed by this benefactor (all-time)
     */
    function getBenefactorContribution(address benefactor) external view returns (uint256);

    /**
     * @notice Get benefactor's current share balance
     * @dev Shares represent proportional ownership of vault fees
     *      Share units are vault-specific (not standardized)
     *      Used for pro-rata fee accounting (see claimFees)
     *
     * @param benefactor Address to query
     * @return Share balance in vault-specific units
     */
    function getBenefactorShares(address benefactor) external view returns (uint256);

    // ========== Vault Info ==========

    /**
     * @notice Get vault implementation type identifier
     * @dev Used by governance for classification and risk assessment
     *      Examples: "UniswapV4LP", "AaveYield", "CurveStable", "UniswapV5LP"
     *      Must be non-empty string
     *
     * @return Vault type identifier (human-readable string)
     */
    function vaultType() external view returns (string memory);

    /**
     * @notice Get vault description for frontend display
     * @dev Human-readable description of vault strategy and purpose
     *      Examples:
     *      - "Full-range liquidity provision on Uniswap V4 with auto-compounding"
     *      - "Low-risk stable yield via Aave ETH lending"
     *      - "Curve stablecoin pools with minimal impermanent loss"
     *
     * @return Vault description (1-2 sentences)
     */
    function description() external view returns (string memory);

    /**
     * @notice Get total accumulated fees in vault
     * @dev Lifetime ETH fees distributed to benefactors (monotonic)
     *      Increases when yield is distributed; claims do not reduce it
     *
     * @return Total ETH fees accumulated (in wei)
     */
    function accumulatedFees() external view returns (uint256);

    /**
     * @notice Get total shares issued across all benefactors
     * @dev Used in proportional calculations: benefactorShare ÷ totalShares
     *      Increases when new shares issued during conversions
     *      May increase when dust is distributed
     *
     * @return Total shares across all benefactors (vault-specific units)
     */
    function totalShares() external view returns (uint256);

    // ========== Capability Discovery ==========

    /**
     * @notice Check if this vault supports a specific capability
     * @dev Standard capability identifiers (use keccak256 of these strings):
     *      - "YIELD_GENERATION"       : Vault generates yield from deposits (LP fees, lending, etc.)
     *      - "GOVERNANCE"             : Vault provides governance/voting functionality
     *      - "STAKING_ENFORCEMENT"    : Vault requires/enforces staking on instances
     *      - "SHARE_TRANSFER"         : Vault supports transferring shares between addresses
     *      - "MULTI_ASSET"            : Vault accepts multiple asset types (not just ETH)
     *      - "BENEFACTOR_DELEGATION"  : Vault supports benefactor fee delegation
     *
     * @param capability keccak256 hash of the capability string
     * @return True if this vault supports the capability
     */
    function supportsCapability(bytes32 capability) external view returns (bool);

    // ========== Policy & Compliance ==========

    /**
     * @notice Get vault's current policy requirements
     * @dev Returns encoded policy data specific to vault type.
     *      Empty bytes means no requirements (permissive vault).
     *      Frontends decode this for display; instances use validateCompliance() instead.
     *
     *      Example policies by vault type:
     *      - UniswapV4LP: empty bytes (no requirements)
     *      - Staking vault: abi.encode(minStakeRatio, lockDuration)
     *      - DAO vault: abi.encode(minVotingPower, quorumThreshold)
     *
     * @return Encoded policy data (vault-specific format)
     */
    function currentPolicy() external view returns (bytes memory);

    /**
     * @notice Check if an instance meets this vault's requirements
     * @dev Generic compliance check — replaces vault-type-specific validation.
     *      Vaults with no requirements should always return true.
     *      Called by instances before claiming fees or performing restricted actions.
     *
     * @param instance Address of the project instance to validate
     * @return True if the instance is compliant with vault requirements
     */
    function validateCompliance(address instance) external view returns (bool);

    /**
     * @notice Emitted when vault policy parameters change
     * @param key Policy parameter identifier (e.g., keccak256("MIN_STAKE_RATIO"))
     * @param value New value for the parameter (encoded, vault-specific)
     */
    event VaultPolicyUpdated(bytes32 indexed key, bytes value);

    // ========== Benefactor Delegation ==========

    /**
     * @notice Set a delegate to receive claimed fees on behalf of this benefactor
     * @dev Only callable by the benefactor itself (the instance contract).
     *      Setting delegate to address(0) removes delegation (fees go to caller).
     *      The delegate is a fee-routing target, not a share transfer.
     *
     * @param delegate Address to receive fees on behalf of caller
     */
    function delegateBenefactor(address delegate) external;

    /**
     * @notice Get the delegate for a benefactor
     * @dev Returns the benefactor's own address if no delegation is set.
     *
     * @param benefactor Address to query
     * @return Delegate address (or benefactor itself if no delegation)
     */
    function getBenefactorDelegate(address benefactor) external view returns (address);

    /**
     * @notice Batch claim fees for multiple benefactors as their delegate
     * @dev Caller must be the registered delegate for every benefactor in the array.
     *      Processes claims for each benefactor and sends one lump-sum ETH transfer
     *      to the caller (delegate) at the end.
     *
     * @param benefactors Array of benefactor addresses to claim for
     * @return totalClaimed Total ETH claimed across all benefactors
     */
    function claimFeesAsDelegate(address[] calldata benefactors) external returns (uint256 totalClaimed);
}
