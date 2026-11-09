// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockToken, MockAggregator} from "./mocks/VaultMocks.sol";
import {VaultTestBase, zSwapCall} from "./VaultTestBase.sol";
import {SwapCall} from "../../src/vaults/uni/IVaultConfig.sol";

contract VaultHandler is Test {
    TestableUniAlignmentVault public vault;
    UniAlignmentVaultFactory public factory;
    address public router;
    address public keeper;
    address[] public actors;
    address[] public tokens; // address(0) = ETH
    address constant INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    // ghosts: monotonicity (a violation flips the flag; the invariant reads it)
    bool public sharesDecreased;
    bool public accDecreased;
    mapping(address => uint256) public lastShares;
    uint256 public lastTotalShares;
    uint256[3] public lastAcc;
    uint256 public conversions;
    bytes4 public unexpected;
    bytes public unexpectedErr;
    uint256 public claims;
    uint256 public partials;
    uint256 public guarded;
    MockAggregator public agg;
    /// @dev Pro-rata model of each benefactor's pending balance, kept independently of the vault's ledger.
    mapping(address => mapping(address => uint256)) public expectedPending;
    mapping(address => uint256) public conversionsOf;

    constructor(
        TestableUniAlignmentVault v,
        UniAlignmentVaultFactory f,
        address router_,
        MockAggregator agg_,
        address keeper_,
        address[] memory actors_,
        address[] memory tokens_
    ) {
        vault = v;
        factory = f;
        router = router_;
        agg = agg_;
        keeper = keeper_;
        actors = actors_;
        tokens = tokens_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function contribute(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        address t = tokens[tokenSeed % tokens.length];
        if (t == address(0)) {
            amount = bound(amount, 0.001 ether, 50 ether);
            vm.deal(who, amount);
            vm.prank(who);
            vault.receiveContribution{value: amount}(Currency.wrap(t), amount, who);
            expectedPending[who][t] += amount;
        } else {
            uint8 dec = MockToken(t).decimals();
            amount = bound(amount, 1, 100_000 * 10 ** dec);
            MockToken(t).mint(who, amount);
            vm.startPrank(who);
            MockToken(t).approve(address(vault), amount);
            vault.receiveContribution(Currency.wrap(t), amount, who);
            vm.stopPrank();
            expectedPending[who][t] += amount;
        }
        _check();
    }

    /// @dev A random non-empty subset of the pending tokens, each converted in full or in part, in a random order.
    function convert(uint256 maskSeed, uint256 fracSeed) external {
        address[] memory open = vault.openBatchTokens();
        uint256 n = open.length;
        if (n == 0) return;
        uint256 mask = bound(maskSeed, 1, (1 << n) - 1);
        uint256 m;
        for (uint256 i; i < n; ++i) if (mask & (1 << i) != 0) ++m;
        UniAlignmentVault.ConvertParams memory p;
        p.tokens = new address[](m);
        p.amounts = new uint256[](m);
        p.swaps = new SwapCall[](m);
        uint256[] memory pend = new uint256[](m);
        uint256 rot = fracSeed % m; // rotate the order
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (mask & (1 << i) == 0) continue;
            uint256 slot = (k + rot) % m;
            address t = open[i];
            uint256 pending = vault.pendingByToken(t);
            uint256 r = uint256(keccak256(abi.encode(fracSeed, i)));
            uint256 amt = r % 3 == 0 ? pending : pending * (1 + (r >> 8) % 10_000) / 10_000;
            if (amt == 0) amt = pending;
            p.tokens[slot] = t;
            p.amounts[slot] = amt;
            pend[slot] = pending;
            if (t != INFER && t != IMD && t != address(0)) p.swaps[slot] = zSwapCall(router, t, amt, address(vault));
            ++k;
        }
        p.ethLeg = zSwapCall(router, address(0), 0, address(vault));
        p.minSplitOut = 1;
        p.deadline = block.timestamp;
        vm.prank(keeper);
        try vault.convertAndAddLiquidity(p) {
            ++conversions;
            for (uint256 j; j < m; ++j) {
                if (p.amounts[j] < pend[j]) ++partials;
                for (uint256 a; a < actors.length; ++a) {
                    uint256 e = expectedPending[actors[a]][p.tokens[j]];
                    expectedPending[actors[a]][p.tokens[j]] = e * (pend[j] - p.amounts[j]) / pend[j];
                }
                ++conversionsOf[p.tokens[j]];
            }
        } catch (bytes memory err) {
            // A batch too small to make liquidity, or a split too small to clear the floor, may fail; nothing else.
            bytes4 sel = bytes4(err);
            if (
                sel != UniAlignmentVault.InsufficientLiquidity.selector
                    && sel != UniAlignmentVault.InsufficientOutput.selector
            ) {
                unexpected = sel;
                unexpectedErr = err;
            }
        }
        _check();
    }

    /// @dev A keeper call whose swap for one ERC-20 goes to a misbehaving (allowlisted) aggregator: it must revert on a
    ///      guard and change nothing.
    function convertBadly(uint256 pick, uint256 modeSeed) external {
        address[] memory open = vault.openBatchTokens();
        address t;
        for (uint256 i; i < open.length; ++i) {
            address c = open[(pick % open.length + i) % open.length];
            if (c != INFER && c != IMD && c != address(0)) {
                t = c;
                break;
            }
        }
        if (t == address(0)) return;
        uint256 amt = vault.pendingByToken(t);
        if (amt < 2) return;
        MockAggregator.Mode[4] memory modes = [
            MockAggregator.Mode.UnderDeliver,
            MockAggregator.Mode.PullLess,
            MockAggregator.Mode.SendElsewhere,
            MockAggregator.Mode.RefundInput
        ];
        agg.setMode(modes[modeSeed % 4]);
        UniAlignmentVault.ConvertParams memory p;
        p.tokens = new address[](1);
        p.amounts = new uint256[](1);
        p.swaps = new SwapCall[](1);
        (p.tokens[0], p.amounts[0]) = (t, amt);
        address out = zSwapCall(router, t, amt, address(vault)).tokenOut;
        uint256 fair = amt * agg.rate(t, out) / 1e18;
        p.swaps[0] = SwapCall(address(agg), out, abi.encodeCall(MockAggregator.swap, (t, amt, out)), fair == 0 ? 1 : fair);
        p.ethLeg = zSwapCall(router, address(0), 0, address(vault));
        p.minSplitOut = 1;
        p.deadline = block.timestamp;
        vm.prank(keeper);
        try vault.convertAndAddLiquidity(p) {
            unexpected = bytes4(0xdeadbeef);
            unexpectedErr = "bad swap converted";
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (
                sel == UniAlignmentVault.InsufficientOutput.selector || sel == UniAlignmentVault.InputMismatch.selector
                    || sel == UniAlignmentVault.InsufficientLiquidity.selector
            ) ++guarded;
            else (unexpected, unexpectedErr) = (sel, err);
        }
        _check();
    }

    function accrue(uint256 f0, uint256 f1, bool collect) external {
        if (vault.totalLPUnits() == 0) return;
        vault.accrueFees(bound(f0, 0, 1_000e18), bound(f1, 0, 1_000e18));
        if (collect) vault.collectFees();
        _check();
    }

    function claim(uint256 actorSeed, uint256 modeSeed) external {
        address who = _actor(actorSeed);
        ClaimMode mode = ClaimMode(modeSeed % 3);
        vm.prank(who);
        try vault.claimFees(mode, 1) {
            ++claims;
        } catch {}
        _check();
    }

    function movePrice(uint256 seed) external {
        // 0.25x .. 4x around 1 IMD per INFER
        uint256 s = bound(seed, (uint256(1) << 96) / 2, (uint256(1) << 96) * 2);
        vault.setMockPool(uint160(s), 1e24);
        _check();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function _check() internal {
        for (uint256 i; i < actors.length; ++i) {
            uint256 s = vault.benefactorShares(actors[i]);
            if (s < lastShares[actors[i]]) sharesDecreased = true;
            lastShares[actors[i]] = s;
        }
        uint256 ts = vault.totalShares();
        if (ts < lastTotalShares) sharesDecreased = true;
        lastTotalShares = ts;
        address[3] memory ft = [INFER, IMD, address(0)];
        for (uint256 i; i < 3; ++i) {
            (uint256 acc,,,) = vault.feeStats(ft[i]);
            if (acc < lastAcc[i]) accDecreased = true;
            lastAcc[i] = acc;
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
contract UniAlignmentVaultInvariantTest is VaultTestBase {
    VaultHandler handler;
    address[] actorList;
    address[] tokenList;

    function setUp() public override {
        super.setUp();
        actorList.push(alice);
        actorList.push(bob);
        actorList.push(carol);
        actorList.push(dan);
        tokenList.push(ETH);
        tokenList.push(USDC_ADDR);
        tokenList.push(WBTC_ADDR);
        tokenList.push(CBBTC_ADDR);
        tokenList.push(IMDUSD_ADDR);
        tokenList.push(IMD_ADDR);
        tokenList.push(INFER_ADDR);
        MockAggregator agg = new MockAggregator();
        vm.deal(address(agg), 1e30);
        agg.setRate(USDC_ADDR, ETH, R_USDC_ETH);
        agg.setRate(WBTC_ADDR, ETH, R_BTC_ETH);
        agg.setRate(CBBTC_ADDR, ETH, R_BTC_ETH);
        agg.setRate(IMDUSD_ADDR, IMD_ADDR, R_IMDUSD_IMD);
        factory.setSwapTarget(address(agg), true);
        handler = new VaultHandler(vault, factory, address(router), agg, keeper, actorList, tokenList);
        targetContract(address(handler));
    }

    /// @dev No balance owed beyond what is held, per token: fees + protocol cut + pending contributions.
    function invariant_solventPerToken() public view {
        _assertSolvent(vault);
        address[4] memory others = [USDC_ADDR, WBTC_ADDR, CBBTC_ADDR, IMDUSD_ADDR];
        for (uint256 i; i < 4; ++i) {
            assertGe(MockToken(others[i]).balanceOf(address(vault)), vault.pendingByToken(others[i]));
        }
    }

    /// @dev What benefactors can claim never exceeds what was distributed and not yet claimed, per fee token.
    function invariant_claimsWithinDistributed() public view {
        uint256[3] memory sum;
        for (uint256 a; a < actorList.length; ++a) {
            (uint256 i, uint256 m, uint256 e) = vault.claimable(actorList[a]);
            sum[0] += i;
            sum[1] += m;
            sum[2] += e;
        }
        address[3] memory ft = [INFER_ADDR, IMD_ADDR, ETH];
        for (uint256 k; k < 3; ++k) {
            (, uint256 dist, uint256 claimed,) = vault.feeStats(ft[k]);
            assertLe(sum[k], dist - claimed);
        }
    }

    function invariant_sharesWithinTotal() public view {
        uint256 sum;
        for (uint256 a; a < actorList.length; ++a) sum += vault.benefactorShares(actorList[a]);
        assertLe(sum, vault.totalShares());
        assertLe(vault.totalShares(), vault.totalLPUnits());
    }

    /// @dev Per token, benefactors' balances add up to what is pending, up to rounding dust (partial conversions round
    ///      each balance down); each balance matches an independent pro-rata model of it.
    function invariant_pendingMatchesBenefactors() public view {
        for (uint256 t; t < tokenList.length; ++t) {
            address tok = tokenList[t];
            uint256 sum;
            uint256 c = handler.conversionsOf(tok);
            for (uint256 a; a < actorList.length; ++a) {
                uint256 got = vault.pendingOf(actorList[a], tok);
                uint256 want = handler.expectedPending(actorList[a], tok);
                // The model rounds once per conversion; the ledger's product rounds at 1 part in 1e9 per conversion.
                assertApproxEqAbs(got, want, c + 1 + want * (c + 1) / 1e8, "pending matches the pro-rata model");
                sum += got;
            }
            uint256 total = vault.pendingByToken(tok);
            assertLe(sum, total, "no more owed than pending");
            assertLe(total - sum, (c + 1) * actorList.length * (2 + total / 1e8), "dust only");
        }
    }

    /// @dev Shares (per benefactor and total) and fees per share never decrease.
    function invariant_monotonic() public view {
        assertFalse(handler.sharesDecreased(), "shares decreased");
        assertFalse(handler.accDecreased(), "fee per share decreased");
        assertEq(handler.unexpectedErr(), "", "unexpected conversion failure");
    }

    function afterInvariant() external view {
        // The campaign must actually exercise conversions and claims.
        assertGt(handler.conversions(), 0, "no conversion ran");
        assertGt(handler.partials(), 0, "no partial conversion ran");
        assertGt(handler.guarded(), 0, "no bad swap was tried");
    }
}
