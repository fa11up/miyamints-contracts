// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {SwapCall, IzRouter} from "../../src/vaults/uni/IVaultConfig.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Swaps exact input in one v4 pool straight through PoolManager (works for the hooked INFER/IMD pool).
contract PoolSwapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (PoolKey memory key, bool z, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: z,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        Currency cin = z ? key.currency0 : key.currency1;
        Currency cout = z ? key.currency1 : key.currency0;
        uint256 owe = uint256(uint128(-(z ? d.amount0() : d.amount1())));
        uint256 got = uint256(uint128(z ? d.amount1() : d.amount0()));
        pm.sync(cin);
        IERC20F(Currency.unwrap(cin)).transfer(address(pm), owe);
        pm.settle();
        pm.take(cout, address(this), got);
        return abi.encode(got);
    }
}

interface IAllowanceHolder {
    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory result);

    function transferFrom(address token, address owner, address recipient, uint256 amount) external returns (bool);
}

/// @notice A 0x Settler stand-in for the AllowanceHolder flow on the fork: as operator and target of the vault's
///         AllowanceHolder.exec, it pulls the input through AllowanceHolder.transferFrom (the vault's exact approval and the
///         ephemeral allowance), swaps it on zRouter, and pays the output to the vault. 0x quotes can't be fetched inside
///         forge; this exercises the real AllowanceHolder with the vault as taker.
contract MiniSettler {
    IAllowanceHolder constant AH = IAllowanceHolder(0x0000000000001fF3684f28c67538d4D072C22734);
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    receive() external payable {}

    /// @dev Sell `amount` of `token` (ETH = all of msg.value) on zRouter's v4 pool (`fee`, `ts`) for `tokenOut`, to the
    ///      AllowanceHolder caller (ERC-2771 style: the last 20 bytes of calldata).
    function sellV4(address token, uint256 amount, address tokenOut, uint24 fee, int24 ts) external payable {
        require(msg.sender == address(AH), "only via AllowanceHolder");
        address taker = address(bytes20(msg.data[msg.data.length - 20:]));
        if (token != address(0)) {
            AH.transferFrom(token, taker, address(this), amount);
            IERC20F(token).approve(ZROUTER, amount);
        }
        IzRouter(ZROUTER).swapV4{value: msg.value}(
            taker, false, fee, ts, token, tokenOut, token == address(0) ? 0 : amount, 0, block.timestamp
        );
    }
}

/// @notice Vault v2 against the REAL mainnet pools, zRouter and PoolManager: every payment token converting a batch
///         through zRouter calldata built here (the keeper's fallback path; 0x quotes can't be fetched inside forge), the
///         0x AllowanceHolder flow with a Settler stand-in, a mixed batch from several benefactors split by realized
///         value, order independence, a subset batch, real swaps generating fees, each claim mode, reinvest share
///         pricing, and the keeper's quote-then-floor flow.
///         RPC: MAINNET_RPC_URL (default https://ethereum-rpc.publicnode.com); FORK_BLOCK pins a block.
///         Skipped (not failed) when the RPC is unreachable or SKIP_FORK_TESTS=true; REQUIRE_FORK_TESTS=true fails instead.
contract UniAlignmentVaultForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant ETH = address(0);
    address constant INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant IMDUSD = 0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant HOOK = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    bool forked;
    MiyaRegistry registry;
    UniAlignmentVaultFactory factory;
    UniAlignmentVault vault;
    PoolSwapper swapper;
    PoolKey alignKey;

    address keeper = makeAddr("miyamaker.vaultfork.keeper");
    address alice = makeAddr("miyamaker.vaultfork.alice");
    address bob = makeAddr("miyamaker.vaultfork.bob");
    address carol = makeAddr("miyamaker.vaultfork.carol");
    address dan = makeAddr("miyamaker.vaultfork.dan");
    address erin = makeAddr("miyamaker.vaultfork.erin");
    address fay = makeAddr("miyamaker.vaultfork.fay");
    address gus = makeAddr("miyamaker.vaultfork.gus");

    function setUp() public {
        if (vm.envOr("SKIP_FORK_TESTS", false)) return;
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) {
            try vm.createSelectFork(rpc) {
                forked = true;
            } catch {}
        } else {
            try vm.createSelectFork(rpc, blockNo) {
                forked = true;
            } catch {}
        }
        if (!forked || block.chainid != 1) {
            forked = false;
            require(!vm.envOr("REQUIRE_FORK_TESTS", false), "fork tests required but no mainnet fork");
            return;
        }

        registry = new MiyaRegistry(address(this), TREASURY, 100, 1000);
        address[] memory t = new address[](2);
        (t[0], t[1]) = (INFER, IMD);
        registry.addTarget("INFER/IMD", t);
        registry.setConversionKeeper(keeper);
        address[6] memory pay = [INFER, IMD, USDC, IMDUSD, CBBTC, WBTC];
        for (uint256 i; i < 6; ++i) registry.setPaymentToken(pay[i], true);

        alignKey = PoolKey(Currency.wrap(INFER), Currency.wrap(IMD), 12500, 60, IHooks(HOOK));
        factory = new UniAlignmentVaultFactory(IMiyaRegistry(address(registry)), PM, ZROUTER, INFER, IMD, alignKey);
        registry.setVaultFactory(address(factory), true);
        factory.setSwapTarget(ZROUTER, true);
        factory.setSwapTarget(ALLOWANCE_HOLDER, true);
        bytes32 salt = bytes32(abi.encodePacked(address(factory), bytes1(0x00), bytes11(keccak256("forkVault"))));
        vault = UniAlignmentVault(payable(factory.deployVault(salt, 0)));
        swapper = new PoolSwapper(PM);

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(PM, alignKey.toId());
        require(sqrtP != 0, "INFER/IMD pool not initialized at this block");
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    /// @dev The keeper's zRouter fallback for `token`, on the spec's pools (docs/IMD-INFER-VAULT.md): exactly `amount`
    ///      to the vault, floor 1 (amount 0 = all of msg.value, the ETH leg). USDC, WBTC -> ETH (v4 500/10), cbBTC ->
    ///      ETH (v3 cbBTC/WETH 0.3%, zRouter unwraps), imdUSD -> IMD (v4 3000/60), ETH -> IMD (v4 10000/200).
    function _zSwap(address token, uint256 amount) internal view returns (SwapCall memory c) {
        address to = address(vault);
        c.target = ZROUTER;
        c.minOut = 1;
        if (token == ETH) {
            c.tokenOut = IMD;
            c.data = abi.encodeCall(IzRouter.swapV4, (to, false, 10000, 200, ETH, IMD, amount, 0, block.timestamp));
        } else if (token == CBBTC) {
            c.tokenOut = ETH;
            c.data = abi.encodeCall(IzRouter.swapV3, (to, false, 3000, CBBTC, ETH, amount, 0, block.timestamp));
        } else if (token == IMDUSD) {
            c.tokenOut = IMD;
            c.data = abi.encodeCall(IzRouter.swapV4, (to, false, 3000, 60, IMDUSD, IMD, amount, 0, block.timestamp));
        } else {
            c.tokenOut = ETH;
            c.data = abi.encodeCall(IzRouter.swapV4, (to, false, 500, 10, token, ETH, amount, 0, block.timestamp));
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _give(address who, address token, uint256 amount) internal {
        if (token == ETH) {
            vm.deal(who, amount);
            vm.prank(who);
            vault.receiveContribution{value: amount}(Currency.wrap(ETH), amount, who);
        } else {
            deal(token, who, amount);
            vm.startPrank(who);
            IERC20F(token).approve(address(vault), amount);
            vault.receiveContribution(Currency.wrap(token), amount, who);
            vm.stopPrank();
        }
    }

    /// @dev Everything pending, in openBatchTokens() order, floors of 1.
    function _loose() internal view returns (UniAlignmentVault.ConvertParams memory p) {
        address[] memory toks = vault.openBatchTokens();
        uint256[] memory amts = new uint256[](toks.length);
        for (uint256 i; i < toks.length; ++i) amts[i] = vault.pendingByToken(toks[i]);
        return _looseFor(toks, amts);
    }

    /// @dev Exactly `amts` of `toks`, floors of 1.
    function _looseFor(address[] memory toks, uint256[] memory amts)
        internal
        view
        returns (UniAlignmentVault.ConvertParams memory p)
    {
        p.tokens = toks;
        p.amounts = amts;
        p.swaps = new SwapCall[](toks.length);
        for (uint256 i; i < toks.length; ++i) {
            if (toks[i] == INFER || toks[i] == IMD || toks[i] == ETH) continue;
            p.swaps[i] = _zSwap(toks[i], amts[i]);
        }
        p.ethLeg = _zSwap(ETH, 0);
        p.minSplitOut = 1;
        p.deadline = block.timestamp;
    }

    function _quoted(uint256 slipBps) internal returns (UniAlignmentVault.ConvertParams memory) {
        return _quotedFrom(_loose(), slipBps);
    }

    /// @dev The keeper's flow: simulate with loose floors, read each swap's output, the ETH leg's and the split's
    ///      from the logs, then set floors at (100 - slipBps/100)% of them. A swap to ETH gets its ETH out back from its
    ///      share of the leg (rounded down, so a 0 slip floor still holds).
    function _quotedFrom(UniAlignmentVault.ConvertParams memory p, uint256 slipBps)
        internal
        returns (UniAlignmentVault.ConvertParams memory)
    {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(keeper);
        vault.convertAndAddLiquidity(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.revertToState(snap);
        (uint256 ethIn, uint256 imdOut) = _leg(logs);
        if (imdOut != 0) p.ethLeg.minOut = imdOut * (10_000 - slipBps) / 10_000;
        bytes32 tc = keccak256("TokenConverted(uint256,address,uint256,uint256)");
        bytes32 ss = keccak256("SplitSwap(bool,uint256,uint256)");
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(vault)) continue;
            if (logs[j].topics[0] == tc) {
                address tok = address(uint160(uint256(logs[j].topics[2])));
                (, uint256 value) = abi.decode(logs[j].data, (uint256, uint256));
                for (uint256 i; i < p.tokens.length; ++i) {
                    if (p.tokens[i] != tok || p.swaps[i].target == address(0)) continue;
                    if (p.swaps[i].tokenOut == ETH) value = value * ethIn / imdOut;
                    p.swaps[i].minOut = value * (10_000 - slipBps) / 10_000;
                }
            } else if (logs[j].topics[0] == ss) {
                (,, uint256 out) = abi.decode(logs[j].data, (bool, uint256, uint256));
                p.minSplitOut = out * (10_000 - slipBps) / 10_000;
            }
        }
        return p;
    }

    function _leg(Vm.Log[] memory logs) internal view returns (uint256 ethIn, uint256 imdOut) {
        bytes32 el = keccak256("EthLegSwapped(uint256,uint256,uint256)");
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter == address(vault) && logs[j].topics[0] == el) {
                (ethIn, imdOut) = abi.decode(logs[j].data, (uint256, uint256));
            }
        }
    }

    function _convertQuoted() internal returns (uint256 shares) {
        UniAlignmentVault.ConvertParams memory p = _quoted(100); // 1% under the live quote
        vm.prank(keeper);
        shares = vault.convertAndAddLiquidity(p);
    }

    function _positionLiquidity() internal view returns (uint128) {
        bytes32 posId = Position.calculatePositionKey(address(vault), vault.tickLower(), vault.tickUpper(), bytes32(0));
        return StateLibrary.getPositionLiquidity(PM, alignKey.toId(), posId);
    }

    function _assertSolvent() internal view {
        address[3] memory t = [INFER, IMD, ETH];
        for (uint256 i; i < 3; ++i) {
            (, uint256 dist, uint256 claimed, uint256 prot) = vault.feeStats(t[i]);
            uint256 bal = t[i] == ETH ? address(vault).balance : IERC20F(t[i]).balanceOf(address(vault));
            assertGe(bal, dist - claimed + prot + vault.pendingByToken(t[i]), "solvent");
        }
    }

    /// @dev Real trades in the INFER/IMD pool both ways, so the vault's position earns fees in both tokens.
    function _tradeAlignmentPool(uint256 rounds, uint256 imdPerTrade) internal {
        deal(IMD, address(swapper), imdPerTrade * rounds * 2);
        for (uint256 r; r < rounds; ++r) {
            uint256 inferOut = swapper.swap(alignKey, false, imdPerTrade); // IMD -> INFER
            swapper.swap(alignKey, true, inferOut); // INFER -> IMD
        }
    }

    /// @dev About 0.2 ETH of `token` at the pool's own rates (sizes the single-route tests like a real keeper batch).
    function _amount(address token) internal pure returns (uint256) {
        if (token == ETH) return 0.2 ether;
        if (token == USDC) return 600e6;
        if (token == WBTC || token == CBBTC) return 0.006e8;
        return 0; // IMD / INFER / imdUSD sized from live prices below
    }

    /// @dev IMD worth ~`eth` ETH via the ETH route, and INFER worth that IMD in the alignment pool (spot).
    function _imdFor(uint256 eth) internal view returns (uint256) {
        PoolKey memory k = PoolKey(Currency.wrap(ETH), Currency.wrap(IMD), 10000, 200, IHooks(address(0)));
        (uint160 s,,,) = StateLibrary.getSlot0(PM, k.toId());
        return eth * uint256(s) / (1 << 96) * uint256(s) / (1 << 96); // IMD per ETH = P (IMD is currency1)
    }

    function _inferFor(uint256 imdAmount) internal view returns (uint256) {
        (uint160 s,,,) = StateLibrary.getSlot0(PM, alignKey.toId());
        return imdAmount * (1 << 96) / uint256(s) * (1 << 96) / uint256(s); // INFER = IMD / P
    }

    function _imdUsdFor(uint256 imdAmount) internal view returns (uint256) {
        PoolKey memory k = PoolKey(Currency.wrap(IMDUSD), Currency.wrap(IMD), 3000, 60, IHooks(address(0)));
        (uint160 s,,,) = StateLibrary.getSlot0(PM, k.toId());
        bool imdUsdIs0 = IMDUSD < IMD;
        // P = currency1 per currency0
        return imdUsdIs0
            ? imdAmount * (1 << 96) / uint256(s) * (1 << 96) / uint256(s)
            : imdAmount * uint256(s) / (1 << 96) * uint256(s) / (1 << 96);
    }

    // ── every payment token, through zRouter calldata ───────────────────────

    function _singleRoute(address token, uint256 amount) internal {
        _give(alice, token, amount);
        uint128 before = _positionLiquidity();
        uint256 shares = _convertQuoted();
        assertGt(shares, 0, "shares");
        assertApproxEqAbs(vault.benefactorShares(alice), shares, shares / 1e15 + 1, "sole benefactor (ledger rounding)");
        assertEq(uint256(_positionLiquidity() - before), shares, "1 share = 1 unit of the vault's real position");
        assertEq(vault.totalLPUnits(), uint256(_positionLiquidity()));
        if (token != ETH && token != INFER && token != IMD) {
            assertEq(IERC20F(token).balanceOf(address(vault)), 0, "the swap spent the token");
        }
        assertEq(vault.pendingByToken(token), 0);
        _assertSolvent();
        console2.log("token", token, "shares", shares);
    }

    function test_fork_route_eth() public onFork {
        _singleRoute(ETH, _amount(ETH));
        assertEq(keeper.balance, 0.0012 ether, "keeper reward from the batch ETH");
    }

    function test_fork_route_usdc() public onFork {
        _singleRoute(USDC, _amount(USDC));
    }

    function test_fork_route_wbtc() public onFork {
        _singleRoute(WBTC, _amount(WBTC));
    }

    function test_fork_route_cbBtc_v3() public onFork {
        _singleRoute(CBBTC, _amount(CBBTC));
    }

    function test_fork_route_imdUsd() public onFork {
        _singleRoute(IMDUSD, _imdUsdFor(_imdFor(0.2 ether)));
    }

    function test_fork_route_imd() public onFork {
        _singleRoute(IMD, _imdFor(0.2 ether));
    }

    function test_fork_route_infer() public onFork {
        _singleRoute(INFER, _inferFor(_imdFor(0.2 ether)));
    }

    // ── a mixed batch from several benefactors ─────────────────────────────

    function test_fork_mixedBatch_splitByRealizedValue() public onFork {
        uint256 imd02 = _imdFor(0.2 ether);
        address[7] memory who = [alice, bob, carol, dan, erin, fay, gus];
        address[7] memory tok = [ETH, USDC, WBTC, CBBTC, IMDUSD, IMD, INFER];
        uint256[7] memory amt = [
            _amount(ETH), _amount(USDC), _amount(WBTC), _amount(CBBTC), _imdUsdFor(imd02), imd02, _inferFor(imd02)
        ];
        for (uint256 i; i < 7; ++i) _give(who[i], tok[i], amt[i]);
        assertEq(vault.openBatchTokens().length, 7);

        UniAlignmentVault.ConvertParams memory p = _quoted(100);
        vm.recordLogs();
        vm.prank(keeper);
        uint256 shares = vault.convertAndAddLiquidity(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256[7] memory value;
        uint256 total;
        bytes32 tc = keccak256("TokenConverted(uint256,address,uint256,uint256)");
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(vault) || logs[j].topics[0] != tc) continue;
            address t = address(uint160(uint256(logs[j].topics[2])));
            (, uint256 v) = abi.decode(logs[j].data, (uint256, uint256));
            for (uint256 i; i < 7; ++i) if (tok[i] == t) value[i] = v;
            total += v;
        }
        uint256 sum;
        for (uint256 i; i < 7; ++i) {
            uint256 s = vault.benefactorShares(who[i]);
            assertGt(s, 0);
            assertApproxEqRel(s, shares * value[i] / total, 1e12, "shares in proportion to realized IMD value");
            sum += s;
            console2.log("token", tok[i], "imd value", value[i]);
        }
        assertLe(sum, shares);
        assertApproxEqAbs(sum, shares, shares / 1e15);
        assertEq(uint256(_positionLiquidity()), shares);
        _assertSolvent();
    }

    /// @dev Converts `toks` (everything pending) in the given order; returns each benefactor's shares and each token's
    ///      realized IMD value.
    function _convertInOrder(address[4] memory toks, address[4] memory who)
        internal
        returns (uint256[4] memory shares, uint256[4] memory value, uint256 ethIn, uint256 imdOut)
    {
        address[] memory t = new address[](4);
        uint256[] memory a = new uint256[](4);
        for (uint256 i; i < 4; ++i) (t[i], a[i]) = (toks[i], vault.pendingByToken(toks[i]));
        UniAlignmentVault.ConvertParams memory p = _looseFor(t, a);
        vm.recordLogs();
        vm.prank(keeper);
        vault.convertAndAddLiquidity(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (ethIn, imdOut) = _leg(logs);
        bytes32 tc = keccak256("TokenConverted(uint256,address,uint256,uint256)");
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(vault) || logs[j].topics[0] != tc) continue;
            address tk = address(uint160(uint256(logs[j].topics[2])));
            (, uint256 v) = abi.decode(logs[j].data, (uint256, uint256));
            for (uint256 i; i < 4; ++i) if (toks[i] == tk) value[i] = v;
        }
        for (uint256 i; i < 4; ++i) shares[i] = vault.benefactorShares(who[i]);
    }

    /// @dev ETH, USDC, WBTC and cbBTC (~0.2 ETH each) all reach IMD through the ETH -> IMD pool. They now meet in one
    ///      swap, so the order of `tokens` changes nothing and every token gets the same IMD per ETH. (Before: each ran
    ///      its own ETH -> IMD swap in turn; at block 26,371,711 cbBTC realized 0.40% less IMD going last than first,
    ///      ETH 0.41% more going first than last.)
    function test_fork_mixedBatch_orderIndependent() public onFork {
        address[4] memory who = [alice, bob, carol, dan];
        address[4] memory fwd = [ETH, USDC, WBTC, CBBTC];
        address[4] memory rev = [CBBTC, WBTC, USDC, ETH];
        for (uint256 i; i < 4; ++i) _give(who[i], fwd[i], _amount(fwd[i]));

        uint256 snap = vm.snapshotState();
        (uint256[4] memory sF, uint256[4] memory vF, uint256 ethIn, uint256 imdOut) = _convertInOrder(fwd, who);
        vm.revertToState(snap);
        (uint256[4] memory sR, uint256[4] memory vR,,) = _convertInOrder(rev, who);
        for (uint256 i; i < 4; ++i) {
            assertEq(sF[i], sR[i], "same shares in either order");
            assertEq(vF[i], vR[3 - i], "same IMD value in either order");
        }
        // Every token realized the leg's one rate: value / ETH in is the same for all (ETH in recovered from value).
        uint256 rate = imdOut * 1e18 / ethIn;
        for (uint256 i; i < 4; ++i) {
            uint256 tokEth = vF[i] * ethIn / imdOut;
            assertApproxEqRel(vF[i] * 1e18 / tokEth, rate, 1e12, "one IMD-per-ETH rate for every token");
            console2.log("token", fwd[i], "imd value", vF[i]);
            console2.log("  fwd/rev ppm", vF[i] * 1e6 / vR[3 - i]);
        }
        console2.log("leg: ETH in", ethIn, "IMD out", imdOut);
        console2.log("block", block.number);
        _assertSolvent();
    }

    /// @dev A subset on real pools: some tokens skipped entirely, USDC half converted; then the rest.
    function test_fork_subsetBatch() public onFork {
        uint256 imd02 = _imdFor(0.2 ether);
        _give(alice, ETH, _amount(ETH));
        _give(bob, USDC, _amount(USDC));
        _give(carol, USDC, _amount(USDC));
        _give(dan, CBBTC, _amount(CBBTC));
        _give(erin, IMDUSD, _imdUsdFor(imd02));
        _give(fay, IMD, imd02);
        _give(gus, INFER, _inferFor(imd02));
        uint256 imdHeld = IERC20F(IMD).balanceOf(address(vault));

        address[] memory t = new address[](3);
        uint256[] memory a = new uint256[](3);
        (t[0], a[0]) = (USDC, _amount(USDC)); // half of the 2 x 600 USDC
        (t[1], a[1]) = (CBBTC, _amount(CBBTC));
        (t[2], a[2]) = (INFER, vault.pendingByToken(INFER));
        UniAlignmentVault.ConvertParams memory p = _quotedFrom(_looseFor(t, a), 100);
        vm.prank(keeper);
        uint256 shares = vault.convertAndAddLiquidity(p);
        assertGt(shares, 0);
        assertEq(uint256(_positionLiquidity()), shares);
        assertEq(keeper.balance, 0, "no ETH converted, no reward");
        // Skipped tokens untouched; USDC holders half converted, pro rata.
        assertEq(vault.pendingOf(alice, ETH), _amount(ETH));
        assertEq(vault.pendingOf(erin, IMDUSD), _imdUsdFor(imd02));
        assertEq(vault.pendingOf(fay, IMD), imd02);
        assertEq(vault.pendingOf(bob, USDC), _amount(USDC) / 2);
        assertEq(vault.pendingOf(carol, USDC), _amount(USDC) / 2);
        assertEq(vault.pendingOf(dan, CBBTC) + vault.pendingOf(gus, INFER), 0);
        assertEq(address(vault).balance, _amount(ETH));
        assertGe(IERC20F(IMD).balanceOf(address(vault)), imd02, "pending IMD not spent");
        assertGe(imdHeld, imd02);
        assertEq(IERC20F(USDC).balanceOf(address(vault)), _amount(USDC));
        assertApproxEqAbs(vault.benefactorShares(bob), vault.benefactorShares(carol), 1);
        assertGt(vault.benefactorShares(dan), 0);
        assertGt(vault.benefactorShares(gus), 0);
        assertEq(vault.benefactorShares(alice) + vault.benefactorShares(fay), 0);
        _assertSolvent();

        uint256 bobBefore = vault.benefactorShares(bob);
        _convertQuoted(); // the rest
        assertGt(vault.benefactorShares(bob), bobBefore);
        assertApproxEqAbs(vault.benefactorShares(bob), vault.benefactorShares(carol), 2);
        assertGt(vault.benefactorShares(alice), 0);
        assertGt(vault.benefactorShares(erin), 0);
        assertGt(vault.benefactorShares(fay), 0);
        assertEq(vault.openBatchTokens().length, 0);
        assertEq(uint256(_positionLiquidity()), vault.totalLPUnits());
        _assertSolvent();
    }

    function test_fork_keeperFloors() public onFork {
        _give(alice, USDC, _amount(USDC));
        _give(bob, ETH, _amount(ETH));
        UniAlignmentVault.ConvertParams memory tight = _quoted(0);
        // A floor 0.1% above the live quote fails; the quote itself passes.
        UniAlignmentVault.ConvertParams memory over = _quoted(0);
        over.swaps[0].minOut = over.swaps[0].minOut * 1001 / 1000; // USDC's swap (ETH out)
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(over);
        over = _quoted(0);
        over.ethLeg.minOut = over.ethLeg.minOut * 1001 / 1000; // the batch's ETH -> IMD swap
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(over);
        over = _quoted(0);
        over.minSplitOut = over.minSplitOut * 1001 / 1000;
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(over);
        vm.prank(keeper);
        vault.convertAndAddLiquidity(tight);
        assertGt(vault.benefactorShares(alice), 0);
    }

    // ── fees from real swaps, each claim mode ──────────────────────────────

    function _seedAndTrade() internal {
        _give(alice, ETH, 1 ether);
        _give(bob, USDC, 3 * _amount(USDC)); // ~0.6 ETH
        _convertQuoted();
        _tradeAlignmentPool(5, _imdFor(1 ether));
        vault.collectFees();
    }

    function test_fork_fees_realSwapsEarnBothTokens() public onFork {
        _seedAndTrade();
        (uint256 ia, uint256 ma,) = vault.claimable(alice);
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        assertGt(ia, 0, "INFER fees");
        assertGt(ma, 0, "IMD fees");
        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        assertApproxEqRel(ia * 1e18 / ib, sa * 1e18 / sb, 1e12);
        assertApproxEqRel(ma * 1e18 / mb, sa * 1e18 / sb, 1e12);
        (,,, uint256 pInfer) = vault.feeStats(INFER);
        (,,, uint256 pImd) = vault.feeStats(IMD);
        assertApproxEqRel(pInfer * 99, ia + ib, 0.001e18, "1% INFER cut");
        assertApproxEqRel(pImd * 99, ma + mb, 0.001e18, "1% IMD cut");
        vault.withdrawProtocolFees(INFER);
        vault.withdrawProtocolFees(IMD);
        _assertSolvent();
    }

    function test_fork_claim_tokens() public onFork {
        _seedAndTrade();
        (uint256 ci, uint256 cm,) = vault.claimable(alice);
        vm.prank(alice);
        (uint256 io, uint256 mo,) = vault.claimFees(ClaimMode.TOKENS, 0);
        assertEq(io, ci);
        assertEq(mo, cm);
        assertEq(IERC20F(INFER).balanceOf(alice), ci);
        assertEq(IERC20F(IMD).balanceOf(alice), cm);
        _assertSolvent();
    }

    function test_fork_claim_eth() public onFork {
        _seedAndTrade();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        (,, uint256 quoted) = vault.claimFees(ClaimMode.ETH, 1);
        vm.revertToState(snap);
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.claimFees(ClaimMode.ETH, quoted + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        (,, uint256 eo) = vault.claimFees(ClaimMode.ETH, quoted * 99 / 100);
        assertEq(eo, quoted);
        assertEq(alice.balance - before, eo);
        assertGt(eo, 0);
        assertEq(IERC20F(INFER).balanceOf(alice) + IERC20F(IMD).balanceOf(alice), 0);
        console2.log("ETH claim", eo);
        _assertSolvent();
    }

    function test_fork_claim_reinvest_sharePricing() public onFork {
        _seedAndTrade();
        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        uint256 total = vault.totalShares();
        (uint256 ib0, uint256 mb0,) = vault.claimable(bob);
        uint128 posBefore = _positionLiquidity();
        (uint256 ci, uint256 cm,) = vault.claimable(alice);

        vm.prank(alice);
        (uint256 ui, uint256 um,) = vault.claimFees(ClaimMode.REINVEST, 1);
        uint256 minted = vault.benefactorShares(alice) - sa;
        assertGt(minted, 0);
        assertEq(uint256(_positionLiquidity() - posBefore), minted, "minted = liquidity added to the real position");
        assertEq(vault.totalShares(), total + minted);
        assertEq(vault.benefactorShares(bob), sb, "other holders keep their shares");
        (uint256 ib1, uint256 mb1,) = vault.claimable(bob);
        // Bob's claim can only have grown (the reinvest's own swap fee accrues to the position, booked at the add).
        assertGe(ib1, ib0);
        assertGe(mb1, mb0);
        (uint256 li, uint256 lm,) = vault.claimable(alice);
        console2.log("claim", ci, cm);
        console2.log("used", ui, um);
        console2.log("left", li, lm);
        // Only a small part of the claim is left over (rounding, and the swap's price impact).
        assertLt(li * 100, ci + 1);
        assertLt(lm * 100, cm + 1);
        assertGt(um, 0);
        _assertSolvent();

        // Fees after the reinvest split by the new share counts.
        _tradeAlignmentPool(3, _imdFor(1 ether));
        vault.collectFees();
        (uint256 ia2,,) = vault.claimable(alice);
        (uint256 ib2,,) = vault.claimable(bob);
        assertApproxEqRel((ia2 - li) * 1e18 / (ib2 - ib1), vault.benefactorShares(alice) * 1e18 / sb, 1e12);
    }

    function test_fork_secondBatch_doesNotTakeEarlierFees() public onFork {
        _give(alice, ETH, 1 ether);
        _convertQuoted();
        _tradeAlignmentPool(3, _imdFor(1 ether));
        // Bob's batch converts after the trades; the conversion books alice's yield before bob's shares exist.
        _give(bob, ETH, 1 ether);
        _convertQuoted();
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        (uint256 ia, uint256 ma,) = vault.claimable(alice);
        assertGt(ia + ma, 0);
        // Bob only has what his own conversion's balancing swap paid the position after it was booked: nothing.
        assertEq(ib + mb, 0);
        _assertSolvent();
    }

    // ── 0x AllowanceHolder: the keeper's main path, with a Settler stand-in ─

    function _ahCall(MiniSettler settler, address token, uint256 amount, address tokenOut, uint24 fee, int24 ts)
        internal
        pure
        returns (SwapCall memory)
    {
        bytes memory inner = abi.encodeCall(MiniSettler.sellV4, (token, amount, tokenOut, fee, ts));
        return SwapCall(
            ALLOWANCE_HOLDER,
            tokenOut,
            abi.encodeCall(IAllowanceHolder.exec, (address(settler), token, amount, payable(address(settler)), inner)),
            1
        );
    }

    function test_fork_allowanceHolder_erc20AndEthLeg() public onFork {
        MiniSettler settler = new MiniSettler();
        _give(alice, USDC, _amount(USDC));
        _give(bob, ETH, _amount(ETH));
        UniAlignmentVault.ConvertParams memory p = _loose();
        assertEq(p.tokens[0], USDC);
        // Both swaps through the real AllowanceHolder: USDC -> ETH (ephemeral allowance, pulled by the operator), and
        // the leg ETH -> IMD (value forwarded).
        p.swaps[0] = _ahCall(settler, USDC, _amount(USDC), ETH, 500, 10);
        p.ethLeg = _ahCall(settler, ETH, 0, IMD, 10000, 200);

        UniAlignmentVault.ConvertParams memory z = _loose();
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 viaZRouter = vault.convertAndAddLiquidity(z);
        vm.revertToState(snap);

        vm.prank(keeper);
        uint256 shares = vault.convertAndAddLiquidity(p);
        assertGt(shares, 0);
        assertApproxEqRel(shares, viaZRouter, 1e12, "same pools, same result as the zRouter path");
        assertGt(vault.benefactorShares(alice), 0);
        assertGt(vault.benefactorShares(bob), 0);
        assertEq(IERC20F(USDC).balanceOf(address(vault)), 0);
        assertEq(IAllowance(USDC).allowance(address(vault), ALLOWANCE_HOLDER), 0, "approval reset");
        assertEq(IERC20F(USDC).balanceOf(address(settler)), 0);
        _assertSolvent();
    }

    function test_fork_allowanceHolder_operatorCannotTakeMoreThanTheAmount() public onFork {
        MiniSettler settler = new MiniSettler();
        _give(alice, USDC, 2 * _amount(USDC)); // the vault holds twice the swap's amount
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        (t[0], a[0]) = (USDC, _amount(USDC));
        UniAlignmentVault.ConvertParams memory p = _looseFor(t, a);
        // The calldata asks AllowanceHolder for an ephemeral allowance of twice the amount; the vault approved only the
        // amount, so the operator's pull fails in USDC itself.
        bytes memory inner = abi.encodeCall(MiniSettler.sellV4, (USDC, 2 * _amount(USDC), ETH, 500, 10));
        p.swaps[0] = SwapCall(
            ALLOWANCE_HOLDER,
            ETH,
            abi.encodeCall(IAllowanceHolder.exec, (address(settler), USDC, 2 * _amount(USDC), payable(address(settler)), inner)),
            1
        );
        vm.prank(keeper);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance"));
        vault.convertAndAddLiquidity(p);
    }
}

interface IAllowance {
    function allowance(address owner, address spender) external view returns (uint256);
}
