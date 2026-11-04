// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencySettler} from "../../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IVaultPriceValidator} from "../../interfaces/IVaultPriceValidator.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";

interface IzRouterV4 {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

/// @notice ERC20 interface with decimals (used only for token setup)
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/**
 * @title UniAlignmentVault
 * @notice Share-based vault for collecting and distributing fees from ms2fun ecosystem
 * @dev Clone-compatible (EIP-1167): initialized via initialize() instead of constructor.
 *      Swap and price validation are delegated to peripheral contracts.
 *      Implements IAlignmentVault interface for governance compliance.
 */
contract UniAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback, IAlignmentVault {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ========== Custom Errors ==========

    error InvalidAddress();
    error TargetNotActive();
    error TokenNotInTarget();
    error AmountMustBePositive();
    error NoPendingETH();
    error NoAlignmentTarget();
    error PoolKeyNotSet();
    error InsufficientLiquidity();
    error InvalidPoolKey();
    error InvalidFeeTier();
    error InvalidTickSpacing();
    error AlignmentTokenNotInPool();
    error PoolMustContainETH();
    error InvalidCurrencyOrdering();
    error NoShares();
    error NoFeesToClaim();
    error InsufficientBalance();
    error TransferFailed();
    error NotBenefactor();
    error NotDelegate();
    error TreasuryNotSet();
    error AmountMismatch();
    error ContributionBelowMinimum();
    error TooManyConversionParticipants();
    error PoolKeyAlreadySet();
    error HooksNotAllowed();
    error NotKeeper();

    // ── Anti-DoS constants ────────────────────────────────────────────────
    uint256 public constant MIN_CONTRIBUTION = 0.001 ether;
    uint256 public constant MAX_CONVERSION_PARTICIPANTS = 500;

    // ── Fee accounting ────────────────────────────────────────────────────
    /// @dev Scale for accFeePerShare. Shares are V4 liquidity units, so a high scale keeps per-share
    ///      rounding loss negligible (< totalShares / 1e36 wei per distribution).
    uint256 internal constant ACC_PRECISION = 1e36;

    /// @dev Transient slot set while the vault itself pulls ETH in (PoolManager.take of LP fees, zRouter
    ///      token->ETH swap). receive() must not treat that ETH as a contribution: it would re-enter the
    ///      nonReentrant contribution path and revert the whole collection.
    ///      = keccak256("miyamaker.UniAlignmentVault.collecting")
    uint256 private constant _COLLECTING_SLOT =
        0x9fffd68a8e82dadd8810fe84758545b0fb4c40f84b514ef129e417c2e244d1a1;

    // ========== Data Structures ==========

    /// @notice Callback data for V4 modifyLiquidity operations
    struct ModifyLiquidityCallbackData {
        IPoolManager.ModifyLiquidityParams params;
    }

    // ========== Mappings ==========

    // Track total ETH contributed per benefactor (for bragging rights)
    mapping(address => uint256) public benefactorTotalETH;

    // Track shares issued to benefactors (for fee claims)
    mapping(address => uint256) public benefactorShares;

    // MasterChef-style fee accounting: a benefactor is owed
    //   settledFees[b] + benefactorShares[b] * (accFeePerShare - feeCheckpoint[b]) / ACC_PRECISION
    // Pending fees are settled into settledFees (and the checkpoint advanced) before any change to the
    // benefactor's shares. Checkpointing the per-share index rather than a rounded reward debt means each
    // payout rounds down only once, so sum(payouts) can never exceed fees distributed.
    mapping(address => uint256) public feeCheckpoint;
    mapping(address => uint256) public settledFees;
    mapping(address => uint256) public lastClaimTimestamp;

    // Track pending contributions in current dragnet (reset after each conversion)
    mapping(address => uint256) public pendingETH;

    // Benefactor delegation (fee routing)
    mapping(address => address) public benefactorDelegate;

    // ========== Global State ==========

    uint256 public totalShares;
    uint256 public totalPendingETH;
    /// @notice Lifetime benefactor fees distributed (monotonic; claims do not reduce it)
    uint256 public accumulatedFees;
    /// @notice Lifetime benefactor fees paid out
    uint256 public totalFeesClaimed;
    /// @notice Benefactor fees per share, scaled by ACC_PRECISION
    uint256 public accFeePerShare;
    uint256 public totalLPUnits;
    uint256 public totalEthLocked;
    uint256 public totalUniqueBenefactors;
    uint256 public lastVaultFeeCollectionTime;
    uint256 public vaultFeeCollectionInterval = 1 days;

    // Protocol yield cut (paid to registry.treasury(), see protocolTreasury())
    uint256 public protocolYieldCutBps = 100; // 1% of LP yield
    uint256 public accumulatedProtocolFees;

    // Dust accumulation
    uint256 public accumulatedDustShares;
    uint256 public dustDistributionThreshold = 1e18;

    // Conversion participants tracking (dragnet)
    address[] public conversionParticipants;
    mapping(address => uint256) public lastConversionParticipantIndex;

    // External contracts (storage, not immutable — required for clone pattern)
    address public weth;
    address public poolManager;
    address public alignmentToken;
    uint8 public alignmentTokenDecimals;
    PoolKey public v4PoolKey;

    // zRouter swap config (set once at initialize)
    address public zRouter;
    uint24  public zRouterFee;
    int24   public zRouterTickSpacing;

    // Peripherals (set once at initialize)
    IVaultPriceValidator public priceValidator;

    // Alignment target binding (set once at initialize)
    IMiyaRegistry public registry;
    uint256 public alignmentTargetId;

    // Clone guard
    bool private _initialized;

    // ========== Configuration ==========

    /// @notice Flat reward for calling convertAndAddLiquidity, paid out of the pending ETH being converted
    ///         (never from fee balances) and capped at MAX_CONVERSION_REWARD_BPS of it. No tx.gasprice term,
    ///         so the caller cannot inflate it.
    uint256 public constant CONVERSION_REWARD = 0.0012 ether;
    uint256 public constant MAX_CONVERSION_REWARD_BPS = 100; // 1% of the batch

    uint24 public v3PreferredFee = 3000;
    /// @notice LP fees collected in the alignment token, waiting for a keeper conversion.
    uint256 public pendingFeeTokens;

    // Position tracking
    int24 public lastTickLower;
    int24 public lastTickUpper;

    modifier onlyKeeper() {
        if (msg.sender != registry.conversionKeeper()) revert NotKeeper();
        _;
    }

    // ========== Events ==========

    event LiquidityAdded(
        uint256 ethSwapped,
        uint256 tokenReceived,
        uint256 lpPositionValue,
        uint256 sharesIssued,
        uint256 callerReward
    );
    event DustDistributed(address indexed recipient, uint256 dustShares);

    event ConversionRewardPaid(address indexed caller, uint256 reward);
    /// @dev A rejected reward is distributed to benefactors as fees instead of being stranded.
    event ConversionRewardRejected(address indexed caller, uint256 rewardAmount);

    event ProtocolYieldCollected(uint256 amount);
    event ProtocolFeesWithdrawn(uint256 amount);

    event V4PoolKeyUpdated(bytes32 indexed poolId);
    event BenefactorDelegateSet(address indexed benefactor, address indexed delegate);

    // ========== Initialize (clone pattern) ==========

    /// @notice Initialize the vault clone with all required dependencies
    /// @dev Called once by the factory after EIP-1167 cloning. Sets owner to msg.sender (factory).
    /// @param _weth WETH contract address
    /// @param _poolManager Uniswap V4 PoolManager address
    /// @param _alignmentToken Target community token to buy and LP
    /// @param _zRouter zRouter V4 swap router address
    /// @param _zRouterFee Fee tier for zRouter swaps
    /// @param _zRouterTickSpacing Tick spacing for zRouter swaps
    /// @param _priceValidator Oracle/TWAP price validator for manipulation protection
    /// @param _registry MiyaRegistry that manages approved alignment targets
    /// @param _alignmentTargetId ID of the alignment target this vault serves
    // slither-disable-next-line events-maths
    function initialize(
        address _initialOwner,
        address _weth,
        address _poolManager,
        address _alignmentToken,
        // slither-disable-next-line missing-zero-check
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _priceValidator,
        IMiyaRegistry _registry,
        uint256 _alignmentTargetId
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        _initializeOwner(_initialOwner);

        if (_weth == address(0)) revert InvalidAddress();
        if (_poolManager == address(0)) revert InvalidAddress();
        if (_alignmentToken == address(0)) revert InvalidAddress();
        if (address(_registry) == address(0)) revert InvalidAddress();
        if (!_registry.isAlignmentTargetActive(_alignmentTargetId)) revert TargetNotActive();
        if (!_registry.isTokenInTarget(_alignmentTargetId, _alignmentToken)) revert TokenNotInTarget();

        weth = _weth;
        poolManager = _poolManager;
        alignmentToken = _alignmentToken;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        priceValidator = _priceValidator;
        registry = _registry;
        alignmentTargetId = _alignmentTargetId;

        // Initialize defaults that can't use declaration initializers with clones
        protocolYieldCutBps = 100;
        v3PreferredFee = 3000;
        vaultFeeCollectionInterval = 1 days;
        dustDistributionThreshold = 1e18;

        try IERC20Metadata(_alignmentToken).decimals() returns (uint8 decimals) {
            alignmentTokenDecimals = decimals;
        } catch {
            alignmentTokenDecimals = 18;
        }
    }

    // ========== Fee Reception ==========

    /// @notice Accept direct ETH contributions, crediting msg.sender as the benefactor
    /// @dev ETH arriving while the vault collects its own LP yield (PoolManager.take, zRouter swap output) is
    ///      not a contribution; it is accounted by _collectAndAccumulateVaultFees. Kept cheap (one TLOAD) so
    ///      2300-gas `transfer` senders still work.
    receive() external payable {
        if (_isCollecting()) return;
        _receiveExternalContribution();
    }

    function _isCollecting() private view returns (bool collecting) {
        assembly ("memory-safe") {
            collecting := tload(_COLLECTING_SLOT)
        }
    }

    function _setCollecting(bool collecting) private {
        assembly ("memory-safe") {
            tstore(_COLLECTING_SLOT, collecting)
        }
    }

    function _receiveExternalContribution() private nonReentrant {
        if (msg.value == 0) revert AmountMustBePositive();
        _trackBenefactorContribution(msg.sender, msg.value);
        emit ContributionReceived(msg.sender, msg.value);
    }

    /// @notice Receive an alignment contribution, crediting the specified benefactor
    /// @dev Called by project instances routing their alignment tax to this vault.
    /// @param currency Currency of the contribution (unused — vault only accepts native ETH)
    /// @param amount Contribution amount in wei
    /// @param benefactor Address to credit for this contribution (typically the project instance)
    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable override nonReentrant {
        if (amount == 0) revert AmountMustBePositive();
        if (msg.value != amount) revert AmountMismatch();
        if (benefactor == address(0)) revert InvalidAddress();
        _trackBenefactorContribution(benefactor, amount);
        emit ContributionReceived(benefactor, amount);
    }

    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        if (amount < MIN_CONTRIBUTION) revert ContributionBelowMinimum();
        if(pendingETH[benefactor] == 0){
            if (conversionParticipants.length >= MAX_CONVERSION_PARTICIPANTS) revert TooManyConversionParticipants();
            conversionParticipants.push(benefactor);
        }
        if(benefactorTotalETH[benefactor] == 0){
            totalUniqueBenefactors++;
        }
        benefactorTotalETH[benefactor] += amount;
        pendingETH[benefactor] += amount;
        totalPendingETH += amount;
    }

    // ========== Conversion & Liquidity ==========

    /**
     * @notice Convert accumulated pending ETH to alignment token and add liquidity to V4.
     * @dev Keeper only (registry.conversionKeeper). The pool may have no manipulation-resistant reference price, so
     *      the floors come from the keeper, which submits through a private mempool. The caller earns the reward.
     *      Uses priceValidator for manipulation checks and proportion calculation.
     *      Uses swapRouter for the actual DEX swap.
     * @param minOutTarget Minimum alignment tokens to receive (slippage protection)
     * @param minEthOutForFees Minimum ETH for the pending fee tokens; ignored when none are pending
     * @return lpPositionValue Total value of LP position added (ethSwapped + tokenReceived)
     */
    // ── Internal result structs for convertAndAddLiquidity helpers ──────────────
    struct SwapLPResult {
        uint256 targetTokenReceived;
        uint256 liquidityUnitsAdded;
    }

    // slither-disable-next-line reentrancy-benign,reentrancy-eth
    function convertAndAddLiquidity(
        uint256 minOutTarget,
        uint256 minEthOutForFees
    ) external nonReentrant onlyKeeper returns (uint256 lpPositionValue) {
        if (minOutTarget == 0) revert AmountMustBePositive();
        if (totalPendingETH == 0) revert NoPendingETH();
        if (alignmentToken == address(0)) revert NoAlignmentTarget();
        if (Currency.unwrap(v4PoolKey.currency0) == address(0) && Currency.unwrap(v4PoolKey.currency1) == address(0)) revert PoolKeyNotSet();

        // LP yield accrued so far belongs to the current shareholders: book it before new shares are minted
        // (otherwise the modifyLiquidity below would also net those fees off silently, unaccounted).
        _collectAndAccumulateVaultFees(true);
        _convertPendingFeeTokens(minEthOutForFees);

        int24 tickLower = TickMath.minUsableTick(v4PoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(v4PoolKey.tickSpacing);
        uint256 ethPending = totalPendingETH;
        // Caller reward comes out of this batch, never out of fee balances.
        uint256 callerReward = _conversionReward(ethPending);
        uint256 ethToAdd = ethPending - callerReward;

        priceValidator.validatePrice(alignmentToken, ethToAdd);
        uint256 proportionToSwap = priceValidator.calculateSwapProportion(
            alignmentToken, lastTickLower, lastTickUpper, poolManager,
            bytes32(PoolId.unwrap(v4PoolKey.toId()))
        );
        // An LP add can't use every wei: the amounts rarely match the pool's ratio exactly, and fees earned by the
        // position net off what it pays in. So work from everything the vault holds beyond what it owes, which feeds
        // any leftover from the last conversion into this one and keeps leftovers from building up.
        uint256 owed = callerReward + accumulatedFees - totalFeesClaimed + accumulatedProtocolFees;
        uint256 ethAvailable = address(this).balance - owed;
        // Fee tokens were converted above, so every token held is left over.
        uint256 tokensHeld = SafeTransferLib.balanceOf(alignmentToken, address(this)) - pendingFeeTokens;
        uint256 ethToSwap = _ethToSwap(ethAvailable, tokensHeld, proportionToSwap);

        SwapLPResult memory r = _doSwapAndLP(owed, ethToSwap, minOutTarget, tickLower, tickUpper);

        address[] memory activeBenefactors = _getActiveBenefactors();
        _distributeSharesAndCleanup(ethPending, ethToAdd, r.liquidityUnitsAdded, activeBenefactors);

        lpPositionValue = ethToSwap + r.targetTokenReceived;
        _payCallerReward(callerReward);
        emit LiquidityAdded(ethToSwap, r.targetTokenReceived, lpPositionValue, r.liquidityUnitsAdded, callerReward);
    }

    /// @dev How much ETH to swap so the two sides end up in the right proportion, counting tokens already held.
    function _ethToSwap(uint256 ethAvailable, uint256 tokensHeld, uint256 proportionToSwap)
        private
        view
        returns (uint256)
    {
        uint256 target = (ethAvailable * proportionToSwap) / 1e18; // round down: excess stays as ethForLP
        if (tokensHeld == 0) return target;
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(poolManager), v4PoolKey.toId());
        uint256 tokenValue = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(tokensHeld, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96
        );
        uint256 alreadyHeld = (tokenValue * (1e18 - proportionToSwap)) / 1e18;
        return target > alreadyHeld ? target - alreadyHeld : 0;
    }

    /// @dev Caller reward for converting a pending batch of `ethPending` wei
    function _conversionReward(uint256 ethPending) internal pure returns (uint256) {
        uint256 cap = (ethPending * MAX_CONVERSION_REWARD_BPS) / 10000; // round down: favors benefactors
        return cap < CONVERSION_REWARD ? cap : CONVERSION_REWARD;
    }

    // slither-disable-next-line arbitrary-send-eth,reentrancy-benign,unused-return
    function _doSwapAndLP(
        uint256 owed,
        uint256 ethToSwap,
        uint256 minOutTarget,
        int24 tickLower,
        int24 tickUpper
    ) private returns (SwapLPResult memory r) {
        if (ethToSwap != 0) {
            // zRouter refunds its whole ETH balance to the payer at the end of the swap, so ETH can arrive here.
            _setCollecting(true);
            (, r.targetTokenReceived) = IzRouterV4(zRouter).swapV4{value: ethToSwap}(
                address(this), false, zRouterFee, zRouterTickSpacing,
                address(0), alignmentToken, ethToSwap, minOutTarget, type(uint256).max
            );
            _setCollecting(false);
        }

        uint256 ethRemaining = address(this).balance - owed;
        uint256 tokensForLP = SafeTransferLib.balanceOf(alignmentToken, address(this)) - pendingFeeTokens;
        (uint256 amount0, uint256 amount1) = Currency.unwrap(v4PoolKey.currency0) == alignmentToken
            ? (tokensForLP, ethRemaining)
            : (ethRemaining, tokensForLP);

        r.liquidityUnitsAdded = uint256(_addToLpPosition(amount0, amount1, tickLower, tickUpper));
        totalLPUnits += r.liquidityUnitsAdded;
    }

    // slither-disable-next-line divide-before-multiply
    function _distributeSharesAndCleanup(
        uint256 ethPending,
        uint256 ethAdded,
        uint256 totalSharesIssued,
        address[] memory activeBenefactors
    ) private {
        uint256 totalSharesActuallyIssued = 0;
        address largestContributor = activeBenefactors[0];
        uint256 largestContribution = 0;

        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];
            uint256 contribution = pendingETH[benefactor];

            if (contribution > largestContribution) {
                largestContribution = contribution;
                largestContributor = benefactor;
            }

            uint256 sharePercent = (contribution * 1e18) / ethPending; // round down: dust tracked separately
            uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18; // round down: dust accumulated and redistributed

            // Book fees earned on the existing shares before the share balance changes.
            _settleFees(benefactor);
            benefactorShares[benefactor] += sharesToIssue;
            totalShares += sharesToIssue;
            totalSharesActuallyIssued += sharesToIssue;
            pendingETH[benefactor] = 0;
        }

        uint256 dust = totalSharesIssued - totalSharesActuallyIssued;
        accumulatedDustShares += dust;

        if (accumulatedDustShares >= dustDistributionThreshold) {
            uint256 dustToDistribute = accumulatedDustShares;
            // Already settled in the loop above (it is an active benefactor); accFeePerShare is unchanged.
            benefactorShares[largestContributor] += dustToDistribute;
            totalShares += dustToDistribute;
            accumulatedDustShares = 0;
            emit DustDistributed(largestContributor, dustToDistribute);
        }

        totalEthLocked += ethAdded;
        totalPendingETH = 0;
        _clearConversionParticipants();
    }

    // slither-disable-next-line arbitrary-send-eth
    function _payCallerReward(uint256 callerReward) private {
        if (callerReward == 0) return;
        (bool success, ) = payable(msg.sender).call{value: callerReward}("");
        if (success) {
            emit ConversionRewardPaid(msg.sender, callerReward);
        } else {
            _distributeFees(callerReward);
            emit ConversionRewardRejected(msg.sender, callerReward);
        }
    }

    // ========== Fee Accounting ==========

    /// @dev Credit `amount` of ETH (already held by the vault) to current shareholders pro rata.
    function _distributeFees(uint256 amount) internal {
        if (amount == 0) return;
        if (totalShares == 0) {
            // No one to credit (only reachable for dust before the first conversion): keep it accounted.
            accumulatedProtocolFees += amount;
            emit ProtocolYieldCollected(amount);
            return;
        }
        accFeePerShare += FixedPointMathLib.fullMulDiv(amount, ACC_PRECISION, totalShares); // round down: favors vault
        accumulatedFees += amount;
        emit FeesAccumulated(amount);
    }

    /// @dev Fees earned by the benefactor's current shares since their last checkpoint
    function _feesSinceCheckpoint(address benefactor) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            benefactorShares[benefactor], accFeePerShare - feeCheckpoint[benefactor], ACC_PRECISION
        ); // round down: favors vault
    }

    /// @dev Move fees earned since the last checkpoint into settledFees. Must run before shares change.
    function _settleFees(address benefactor) internal {
        uint256 owed = _feesSinceCheckpoint(benefactor);
        if (owed != 0) settledFees[benefactor] += owed;
        feeCheckpoint[benefactor] = accFeePerShare;
    }

    /// @dev Settle and zero the benefactor's fee balance, returning the amount to pay out.
    function _harvest(address benefactor) internal returns (uint256 amount) {
        _settleFees(benefactor);
        amount = settledFees[benefactor];
        if (amount != 0) {
            settledFees[benefactor] = 0;
            totalFeesClaimed += amount;
            lastClaimTimestamp[benefactor] = block.timestamp;
            emit FeesClaimed(benefactor, amount);
        }
    }

    // ========== Fee Claims ==========

    function _claimVaultFees() internal returns (uint256 ethCollected, uint256 tokenCollected) {
        if (totalLPUnits == 0) {
            return (0, 0);
        }

        if (poolManager.code.length == 0) {
            return (0, 0);
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: lastTickLower,
            tickUpper: lastTickUpper,
            liquidityDelta: 0,
            salt: 0
        });

        ModifyLiquidityCallbackData memory lpData = ModifyLiquidityCallbackData({
            params: params
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(lpData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        bool currency0IsETH = v4PoolKey.currency0.isAddressZero();

        if (currency0IsETH) {
            ethCollected = delta0 > 0 ? uint256(int256(delta0)) : 0;
            tokenCollected = delta1 > 0 ? uint256(int256(delta1)) : 0;
        } else {
            ethCollected = delta1 > 0 ? uint256(int256(delta1)) : 0;
            tokenCollected = delta0 > 0 ? uint256(int256(delta0)) : 0;
        }

        return (ethCollected, tokenCollected);
    }

    /// @dev Swap the fee tokens waiting in the vault for ETH and credit it. Runs only inside keeper calls, before any
    ///      share change, so fees stay with the holders who earned them.
    // slither-disable-next-line unused-return
    function _convertPendingFeeTokens(uint256 minEthOut) internal {
        uint256 tokenAmount = pendingFeeTokens;
        if (tokenAmount == 0) return;
        if (minEthOut == 0) revert AmountMustBePositive();
        pendingFeeTokens = 0;

        SafeTransferLib.safeApproveWithRetry(alignmentToken, zRouter, tokenAmount);
        _setCollecting(true);
        (, uint256 ethReceived) = IzRouterV4(zRouter).swapV4(
            address(this),
            false,
            zRouterFee,
            zRouterTickSpacing,
            alignmentToken,
            address(0),
            tokenAmount,
            minEthOut,
            type(uint256).max
        );
        _setCollecting(false);
        _creditYield(ethReceived);
    }

    /// @dev Protocol cut, then the rest pro rata to current shareholders.
    function _creditYield(uint256 amount) internal {
        if (amount == 0) return;
        uint256 protocolCut = (amount * protocolYieldCutBps) / 10000; // round down: favors benefactors
        _distributeFees(amount - protocolCut);
        accumulatedProtocolFees += protocolCut;
        if (protocolCut > 0) emit ProtocolYieldCollected(protocolCut);
    }

    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth,timestamp
    /// @param force Collect regardless of vaultFeeCollectionInterval (used before share changes)
    function _collectAndAccumulateVaultFees(bool force) internal {
        if (force || block.timestamp >= lastVaultFeeCollectionTime + vaultFeeCollectionInterval
            || lastVaultFeeCollectionTime == 0) {

            _setCollecting(true);
            (uint256 ethCollected, uint256 tokenCollected) = _claimVaultFees();
            _setCollecting(false);

            // Fee tokens wait for the keeper: this path is open to anyone, so it must not swap.
            pendingFeeTokens += tokenCollected;
            _creditYield(ethCollected);
            if (ethCollected + tokenCollected > 0) lastVaultFeeCollectionTime = block.timestamp;
        }
    }

    /// @notice Convert the fee tokens waiting in the vault when there is no pending ETH to convert.
    /// @param minEthOut Minimum ETH to receive (slippage protection)
    function convertFeeTokens(uint256 minEthOut) external nonReentrant onlyKeeper {
        _collectAndAccumulateVaultFees(true);
        _convertPendingFeeTokens(minEthOut);
    }

    /// @notice Claim accumulated LP yield fees for the caller
    /// @dev Triggers vault fee collection first, then pays everything owed to the caller.
    ///      Fees are routed to the benefactor's delegate if one is set.
    /// @return ethClaimed ETH transferred to caller (or their delegate)
    // slither-disable-next-line reentrancy-benign
    function claimFees() external override nonReentrant returns (uint256 ethClaimed) {
        _collectAndAccumulateVaultFees(false);

        address benefactor = msg.sender;

        if (benefactorShares[benefactor] == 0) revert NoShares();

        ethClaimed = _harvest(benefactor);
        if (ethClaimed == 0) revert NoFeesToClaim();

        address recipient = benefactorDelegate[benefactor];
        if (recipient == address(0)) recipient = benefactor;

        if (address(this).balance < ethClaimed) revert InsufficientBalance();
        (bool success, ) = payable(recipient).call{value: ethClaimed}("");
        if (!success) revert TransferFailed();

        return ethClaimed;
    }

    // ========== Internal Helpers ==========

    function _getActiveBenefactors() internal view returns (address[] memory) {
        return conversionParticipants;
    }

    function _clearConversionParticipants() internal {
        while (conversionParticipants.length > 0) {
            conversionParticipants.pop();
        }
    }

    // slither-disable-next-line unused-return
    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal virtual returns (uint128 liquidityUnits) {
        if (amount0 == 0 || amount1 == 0) revert AmountMustBePositive();

        lastTickLower = tickLower;
        lastTickUpper = tickUpper;

        Currency currency0 = v4PoolKey.currency0;
        Currency currency1 = v4PoolKey.currency1;

        if (!currency0.isAddressZero()) {
            SafeTransferLib.safeApproveWithRetry(Currency.unwrap(currency0), address(poolManager), amount0);
        }
        if (!currency1.isAddressZero()) {
            SafeTransferLib.safeApproveWithRetry(Currency.unwrap(currency1), address(poolManager), amount1);
        }

        PoolId poolId = v4PoolKey.toId();
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1
        );
        if (liquidityToAdd == 0) revert InsufficientLiquidity();
        int256 liquidityDelta = int256(uint256(liquidityToAdd));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: 0
        });

        ModifyLiquidityCallbackData memory lpData = ModifyLiquidityCallbackData({
            params: params
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(lpData));

        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        liquidityUnits = liquidityToAdd;

        return liquidityUnits;
    }

    /// @notice Uniswap V4 PoolManager unlock callback for modifyLiquidity operations
    /// @dev Only callable by the PoolManager. Executes the liquidity modification and settles deltas.
    /// @param data ABI-encoded ModifyLiquidityCallbackData
    /// @return ABI-encoded BalanceDelta from the liquidity modification
    // slither-disable-next-line unused-return
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        ModifyLiquidityCallbackData memory lpData = abi.decode(data, (ModifyLiquidityCallbackData));

        (BalanceDelta delta, ) = IPoolManager(poolManager).modifyLiquidity(
            v4PoolKey,
            lpData.params,
            ""
        );

        _settleLPDelta(delta);

        return abi.encode(delta);
    }

    function _settleLPDelta(BalanceDelta delta) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        IPoolManager pm = IPoolManager(poolManager);

        if (delta0 < 0) {
            v4PoolKey.currency0.settle(pm, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            v4PoolKey.currency0.take(pm, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            v4PoolKey.currency1.settle(pm, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            v4PoolKey.currency1.take(pm, address(this), uint128(delta1), false);
        }
    }

    // ========== Pool Validation ==========

    function _validateV4Pool(PoolKey memory poolKey) internal view {
        if (Currency.unwrap(poolKey.currency0) == address(0) && Currency.unwrap(poolKey.currency1) == address(0)) revert InvalidPoolKey();

        // A hook could take a cut of, block, or reprice every vault LP operation and fee collection.
        if (address(poolKey.hooks) != address(0)) revert HooksNotAllowed();

        if (poolKey.fee != 500 && poolKey.fee != 3000 && poolKey.fee != 10000) revert InvalidFeeTier();

        if (poolKey.fee == 500) {
            if (poolKey.tickSpacing != 10) revert InvalidTickSpacing();
        } else if (poolKey.fee == 3000) {
            if (poolKey.tickSpacing != 60) revert InvalidTickSpacing();
        } else if (poolKey.fee == 10000) {
            if (poolKey.tickSpacing != 200) revert InvalidTickSpacing();
        }

        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);

        if (currency0Addr != alignmentToken && currency1Addr != alignmentToken) revert AlignmentTokenNotInPool();

        bool hasNativeETH = currency0Addr == address(0) || currency1Addr == address(0);
        if (!hasNativeETH) revert PoolMustContainETH();

        if (currency0Addr >= currency1Addr) revert InvalidCurrencyOrdering();
    }

    /// @notice Validate the currently configured V4 pool key (reverts if invalid)
    function validateCurrentPoolKey() external view {
        PoolKey memory key = v4PoolKey;
        _validateV4Pool(key);
    }

    // ========== Query Functions ==========

    function getBenefactorContribution(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        return benefactorTotalETH[benefactor];
    }

    function getBenefactorShares(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        return benefactorShares[benefactor];
    }

    /// @notice ETH the benefactor could claim now from fees already collected (excludes uncollected LP yield)
    function calculateClaimableAmount(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        return getUnclaimedFees(benefactor);
    }

    /// @notice Get the fees owed to a benefactor and not yet claimed
    /// @param benefactor Address to query
    /// @return Unclaimed ETH amount
    function getUnclaimedFees(address benefactor)
        public
        view
        returns (uint256)
    {
        return settledFees[benefactor] + _feesSinceCheckpoint(benefactor);
    }

    /// @notice Address that receives the protocol's LP-yield cut: the registry treasury
    function protocolTreasury() public view returns (address) {
        return registry.treasury();
    }

    // ========== Vault Info (IAlignmentVault Interface) ==========

    function vaultType() external pure override returns (string memory) {
        return "UniswapV4LP";
    }

    function description() external pure override returns (string memory) {
        return "Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution";
    }

    function supportsCapability(bytes32 capability) external pure override returns (bool) {
        return capability == keccak256("YIELD_GENERATION")
            || capability == keccak256("BENEFACTOR_DELEGATION");
    }

    function currentPolicy() external pure override returns (bytes memory) {
        return "";
    }

    function validateCompliance(address) external pure override returns (bool) {
        return true;
    }

    // ========== Benefactor Delegation ==========

    /// @notice Set a delegate to receive fee claims on behalf of the caller
    /// @dev Caller must be an existing benefactor. Set to address(0) to remove delegation.
    /// @param delegate Address that will receive fee payouts for the caller
    function delegateBenefactor(address delegate) external override {
        if (benefactorShares[msg.sender] == 0 && benefactorTotalETH[msg.sender] == 0) revert NotBenefactor();
        benefactorDelegate[msg.sender] = delegate;
        emit BenefactorDelegateSet(msg.sender, delegate);
    }

    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address delegate = benefactorDelegate[benefactor];
        return delegate == address(0) ? benefactor : delegate;
    }

    /// @notice Batch claim fees for multiple benefactors as their registered delegate
    /// @dev Caller must be the delegate for every benefactor in the array. Sends one lump-sum payment.
    /// @param benefactors Array of benefactor addresses to claim for
    /// @return totalClaimed Total ETH sent to the caller (delegate)
    // slither-disable-next-line reentrancy-benign
    function claimFeesAsDelegate(address[] calldata benefactors) external override nonReentrant returns (uint256 totalClaimed) {
        _collectAndAccumulateVaultFees(false);

        for (uint256 i = 0; i < benefactors.length; i++) {
            address benefactor = benefactors[i];

            if (benefactorDelegate[benefactor] != msg.sender) revert NotDelegate();
            if (benefactorShares[benefactor] == 0) revert NoShares();

            totalClaimed += _harvest(benefactor);
        }

        if (totalClaimed == 0) revert NoFeesToClaim();
        if (address(this).balance < totalClaimed) revert InsufficientBalance();

        (bool success, ) = payable(msg.sender).call{value: totalClaimed}("");
        if (!success) revert TransferFailed();
    }

    // ========== Configuration ==========
    //
    // The factory owns every vault and exposes no owner passthrough, so tunables are fixed at initialize()
    // and the pool key is set exactly once, by the factory, in the deploy transaction.

    /// @notice Set the Uniswap V4 pool key for liquidity operations. Set-once.
    /// @dev Validates fee tier, tick spacing, currency ordering, alignment token presence and that the pool
    ///      has no hooks. Reverts if a key is already set, so LP can never be repointed to another pool.
    /// @param newPoolKey V4 PoolKey struct identifying the target pool
    function setV4PoolKey(PoolKey calldata newPoolKey) external onlyOwner {
        // A validated key always has the alignment token as currency1 (native ETH sorts first).
        if (Currency.unwrap(v4PoolKey.currency1) != address(0)) revert PoolKeyAlreadySet();
        _validateV4Pool(newPoolKey);
        v4PoolKey = newPoolKey;
        emit V4PoolKeyUpdated(keccak256(abi.encode(newPoolKey)));
    }

    /// @notice Donate ETH to current shareholders as fees (e.g. yield earned outside the V4 position)
    /// @dev Permissionless: the donor only gives away their own ETH. Requires existing shares so the ETH
    ///      cannot be stranded.
    function depositFees() external payable nonReentrant {
        if (msg.value == 0) revert AmountMustBePositive();
        if (totalShares == 0) revert NoShares();
        _distributeFees(msg.value);
    }

    // ========== Protocol Yield Cut ==========

    /// @notice Withdraw accumulated protocol yield cut to the registry treasury
    /// @dev Callable by anyone. Sends accumulatedProtocolFees to protocolTreasury().
    // slither-disable-next-line arbitrary-send-eth,reentrancy-events
    function withdrawProtocolFees() external {
        address treasury = protocolTreasury();
        if (treasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        if (amount == 0) revert NoFeesToClaim();
        accumulatedProtocolFees = 0;
        (bool success, ) = payable(treasury).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit ProtocolFeesWithdrawn(amount);
    }
}
