// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { LibString } from "solady/utils/LibString.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

import { ICreateX, CREATEX } from "../src/shared/CreateXConstants.sol";
import { MiyaRegistry } from "../src/registry/MiyaRegistry.sol";
import { IMiyaRegistry } from "../src/registry/interfaces/IMiyaRegistry.sol";
import { UniAlignmentVault } from "../src/vaults/uni/UniAlignmentVault.sol";
import { UniAlignmentVaultFactory } from "../src/vaults/uni/UniAlignmentVaultFactory.sol";
import { ERC721DropFactory } from "../src/factories/erc721drop/ERC721DropFactory.sol";
import { ERC721AuctionFactory } from "../src/factories/erc721/ERC721AuctionFactory.sol";
import { ERC1155Factory } from "../src/factories/erc1155/ERC1155Factory.sol";
import { DynamicPricingModule } from "../src/factories/erc1155/DynamicPricingModule.sol";
import { PasswordTierGatingModule } from "../src/gating/PasswordTierGatingModule.sol";
import { MiyaPoolFactory } from "../src/pools/MiyaPoolFactory.sol";
import { TestAlignmentToken } from "./mocks/TestAlignmentToken.sol";

/**
 * @title DeployMiyamints
 * @notice One-shot production deployment of the miyamints contract system (everything the app needs, music drops
 *         included) for the chain the RPC points at. Per-chain external addresses come from
 *         script/config/<chainId>.json; a few values can be overridden by env (see DEPLOY.md).
 *
 *         Order: [test token] → MiyaRegistry → UniAlignmentVaultFactory → ERC721DropFactory → ERC721AuctionFactory →
 *         ERC1155Factory → DynamicPricingModule → [gating module] → MiyaPoolFactory → registry wiring → payment tokens,
 *         swap targets, ETH-claim pool and minimums → default alignment target + vault → ownership handoff → checks →
 *         JSON.
 *
 *         Addressing: contracts that take their owner as an argument or have none (registry, drop factory, pool
 *         factory) are deployed with CreateX CREATE3 and a deployer-permissioned salt, so the
 *         same deployer + SALT_NAMESPACE gives the same addresses on every chain (MiyaPoolFactory relies on that
 *         for cross-chain pool addresses). Contracts whose constructor sets `owner = msg.sender` (vault factory,
 *         1155/auction factories, modules) use plain CREATE from the deployer, because under CREATE3 the owner
 *         would be CreateX's throwaway proxy. Collections and vaults are deployed by the factories via CREATE3.
 *
 *         Keys: never read here except `DEPLOYER_PRIVATE_KEY` (optional). Prefer `--account <keystore>` or
 *         `--ledger` with `--sender <addr>`: then vm.startBroadcast() is called without a key.
 */
contract DeployMiyamints is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using LibString for uint256;
    using LibString for address;

    struct Config {
        uint256 chainId;
        string name;
        address treasury;
        address owner; // final owner of the registry and Ownable factories/modules
        address weth;
        address poolManager;
        address zRouter; // ETH-mode claims sell IMD through it; also the keeper's fallback swap target
        address v3Factory;
        address createX;
        uint16 protocolFeeBps;
        uint16 minAlignmentBps;
        string alignmentTargetName;
        address alignmentToken; // INFER: the alignment pool's other side and the registry target token
        address imd; // vault v2 converts every payment token to IMD and pairs it with INFER
        uint24 alignmentPoolFee; // the INFER/IMD v4 pool the vaults provide liquidity to
        int24 alignmentPoolTickSpacing;
        address alignmentPoolHook;
        uint24 ethPoolFee; // the hookless ETH/IMD v4 pool ETH-mode claims swap through (vault factory setEthPool)
        int24 ethPoolTickSpacing;
        address[] swapTargets; // contracts the keeper's conversion calldata may call (0x AllowanceHolder, zRouter)
        address keeper;
        bool deployMockAlignmentToken;
        bool deployGatingModule;
        bool allowMissingPool;
        string saltNamespace;
        string gitCommit; // DEPLOY_GIT_COMMIT, set by script/deploy.sh after it checks the checkout
        string gitRef; // DEPLOY_GIT_REF: "main" or the tag deployed
    }

    struct Deployment {
        address deployer;
        address registry;
        address vaultFactory;
        address vaultImplementation;
        address dropFactory;
        address auctionFactory;
        address erc1155Factory;
        address dynamicPricingModule;
        address gatingModule; // address(0) unless deployGatingModule
        address poolFactory;
        address alignmentToken;
        uint256 alignmentTargetId;
        address defaultVault;
    }

    error ConfigError(string reason);
    error CheckFailed(string what);

    // ── entry points ────────────────────────────────────────────────────────

    /// @notice Broadcast with --account / --ledger / --private-key (or DEPLOYER_PRIVATE_KEY if set).
    function run() external returns (Deployment memory d) {
        Config memory cfg = loadConfig();
        _requireReleaseCheckout(cfg);
        if (vm.envExists("DEPLOYER_PRIVATE_KEY")) {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
        (, address deployer,) = vm.readCallers();
        d = _deployAll(cfg, deployer);
        vm.stopBroadcast();
        _finish(cfg, d);
    }

    /// @notice Same as run() with an explicit broadcaster (fork tests, or `--sig "runAs(address)" <addr>`).
    function runAs(address deployer) external returns (Deployment memory d) {
        return runAs(deployer, address(0));
    }

    /// @notice runAs with an explicit final owner (overrides OWNER when non-zero).
    function runAs(address deployer, address owner) public returns (Deployment memory d) {
        Config memory cfg = loadConfig();
        if (owner != address(0)) cfg.owner = owner;
        _requireReleaseCheckout(cfg);
        vm.startBroadcast(deployer);
        d = _deployAll(cfg, deployer);
        vm.stopBroadcast();
        _finish(cfg, d);
    }

    // ── config ──────────────────────────────────────────────────────────────

    function configPath(uint256 chainId) public view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/config/", chainId.toString(), ".json");
    }

    function loadConfig() public view returns (Config memory c) {
        string memory path = vm.envOr("MIYAMINTS_CONFIG", configPath(block.chainid));
        string memory json = vm.readFile(path);
        c.chainId = vm.parseJsonUint(json, ".chainId");
        if (c.chainId != block.chainid) revert ConfigError("config chainId != connected chain");
        c.name = vm.parseJsonString(json, ".name");
        c.treasury = vm.envOr("TREASURY", vm.parseJsonAddress(json, ".treasury"));
        c.owner = vm.envOr("OWNER", address(0));
        c.weth = vm.parseJsonAddress(json, ".weth");
        c.poolManager = vm.parseJsonAddress(json, ".poolManager");
        c.zRouter = vm.parseJsonAddress(json, ".zRouter");
        c.v3Factory = vm.parseJsonAddress(json, ".v3Factory");
        c.createX = vm.parseJsonAddress(json, ".createX");
        c.protocolFeeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", vm.parseJsonUint(json, ".protocolFeeBps")));
        c.minAlignmentBps = uint16(vm.envOr("MIN_ALIGNMENT_BPS", vm.parseJsonUint(json, ".minAlignmentBps")));
        c.alignmentTargetName = vm.envOr("ALIGNMENT_TARGET_NAME", vm.parseJsonString(json, ".alignmentTargetName"));
        c.alignmentToken = vm.envOr("ALIGNMENT_TOKEN", vm.parseJsonAddress(json, ".alignmentToken"));
        c.imd = vm.keyExistsJson(json, ".imd") ? vm.parseJsonAddress(json, ".imd") : address(0);
        if (vm.keyExistsJson(json, ".alignmentPool")) {
            c.alignmentPoolFee = uint24(vm.parseJsonUint(json, ".alignmentPool.fee"));
            c.alignmentPoolTickSpacing = int24(vm.parseJsonInt(json, ".alignmentPool.tickSpacing"));
            c.alignmentPoolHook = vm.parseJsonAddress(json, ".alignmentPool.hook");
        } else {
            (c.alignmentPoolFee, c.alignmentPoolTickSpacing) = (3000, 60); // test-token chains: hookless 0.3%
        }
        if (vm.keyExistsJson(json, ".ethPool")) {
            c.ethPoolFee = uint24(vm.parseJsonUint(json, ".ethPool.fee"));
            c.ethPoolTickSpacing = int24(vm.parseJsonInt(json, ".ethPool.tickSpacing"));
        } else {
            (c.ethPoolFee, c.ethPoolTickSpacing) = (10000, 200); // the vault factory's default
        }
        if (vm.keyExistsJson(json, ".swapTargets")) c.swapTargets = vm.parseJsonAddressArray(json, ".swapTargets");
        c.keeper = vm.envOr("KEEPER", address(0));
        c.deployMockAlignmentToken = vm.parseJsonBool(json, ".deployMockAlignmentToken");
        c.deployGatingModule = vm.envOr("DEPLOY_GATING_MODULE", vm.parseJsonBool(json, ".deployGatingModule"));
        c.allowMissingPool = vm.envOr("ALLOW_MISSING_POOL", c.deployMockAlignmentToken);
        c.saltNamespace = vm.envOr("SALT_NAMESPACE", string("miyamints.v1"));
        c.gitCommit = vm.envOr("DEPLOY_GIT_COMMIT", string(""));
        c.gitRef = vm.envOr("DEPLOY_GIT_REF", string(""));

        if (c.createX != CREATEX) revert ConfigError("createX must be the canonical CreateX the factories hardcode");
        if (c.protocolFeeBps > 500) revert ConfigError("protocolFeeBps > MAX_PROTOCOL_FEE_BPS (500)");
        // External dependencies must exist on this chain.
        _requireCode(c.weth, "weth");
        _requireCode(c.poolManager, "poolManager");
        _requireCode(c.zRouter, "zRouter");
        _requireCode(c.createX, "createX");
        if (c.v3Factory != address(0)) _requireCode(c.v3Factory, "v3Factory");
        if (c.alignmentToken != address(0)) _requireCode(c.alignmentToken, "alignmentToken");
        if (c.alignmentToken == address(0) && !c.deployMockAlignmentToken) {
            revert ConfigError("alignmentToken unset: set ALIGNMENT_TOKEN");
        }
        if (c.imd != address(0)) _requireCode(c.imd, "imd");
        for (uint256 i; i < c.swapTargets.length; ++i) {
            _requireCode(c.swapTargets[i], string.concat("swapTargets[", i.toString(), "]"));
        }
        if (c.imd == address(0) && !c.deployMockAlignmentToken) {
            revert ConfigError("imd unset: vault v2 needs the INFER/IMD alignment pool config (mainnet only for now)");
        }
        if (c.treasury == address(0) && !c.deployMockAlignmentToken) {
            revert ConfigError("treasury unset for this chain: set TREASURY (a Safe/treasury you control here)");
        }
    }

    /// @dev A broadcast must come from script/deploy.sh, which refuses unless the checkout is a clean main (or an
    ///      explicit tag) and passes the commit it checked, so deployments/<chainId>.json records exactly what was
    ///      deployed. Dry runs and tests are not gated.
    function _requireReleaseCheckout(Config memory c) internal view {
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (!live) return;
        if (bytes(c.gitCommit).length != 40 || bytes(c.gitRef).length == 0) {
            revert ConfigError(
                "broadcast only through script/deploy.sh (clean checkout of main or a release tag; sets DEPLOY_GIT_COMMIT)"
            );
        }
    }

    // ── deployment ──────────────────────────────────────────────────────────

    function _deployAll(Config memory c, address deployer) internal returns (Deployment memory d) {
        d.deployer = deployer;
        if (c.owner == address(0)) c.owner = deployer;
        if (c.treasury == address(0)) c.treasury = deployer; // testnet only (loadConfig enforces)
        // Ownership moves in one step and the treasury is fixed in every collection, so neither can be a dead address.
        if (block.chainid == 1 || block.chainid == 4663) {
            if (c.owner != deployer) _requireCode(c.owner, "OWNER");
            _requireCode(c.treasury, "TREASURY");
        }

        // 0. Testnet alignment token.
        d.alignmentToken = c.alignmentToken;
        if (d.alignmentToken == address(0)) {
            d.alignmentToken = address(new TestAlignmentToken(deployer, 1_000_000_000e18));
            c.alignmentToken = d.alignmentToken;
        }
        if (c.imd == address(0)) c.imd = address(new TestAlignmentToken(deployer, 1_000_000_000e18));
        if (c.allowMissingPool) {
            if (block.chainid == 1 || block.chainid == 4663) {
                console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
                console2.log("!! WARNING: ALLOW_MISSING_POOL=true. The pools were NOT checked: the INFER/IMD alignment");
                console2.log("!! pool (alignmentPool: fee, tickSpacing, hook) and the ETH/IMD pool ETH claims use");
                console2.log("!! (ethPool). Without a live INFER/IMD pool the default vault can never convert; without");
                console2.log("!! the ETH/IMD pool, claims taken as ETH revert (TOKENS claims still work).");
                console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            }
        } else {
            _requirePool(c, _alignmentKey(c), "INFER/IMD alignment pool (alignmentPool)");
            _requirePool(c, _ethPoolKey(c), "ETH/IMD pool for ETH claims (ethPool)");
        }

        // 1. Registry, owned by the deployer until wiring is done.
        d.registry = _create3(
            deployer,
            c.saltNamespace,
            "MiyaRegistry",
            abi.encodePacked(
                type(MiyaRegistry).creationCode, abi.encode(deployer, c.treasury, c.protocolFeeBps, c.minAlignmentBps)
            )
        );
        MiyaRegistry registry = MiyaRegistry(d.registry);

        // 2. Vault factory (Ownable(msg.sender) → CREATE). Deploys its own vault implementation.
        // Payment tokens, swap targets, the ETH-claim pool and per-token minimums come from config (`paymentTokens`,
        // `swapTargets`, `ethPool`, `minContributions`) in step 9b, before the handoff.
        UniAlignmentVaultFactory vaultFactory = new UniAlignmentVaultFactory(
            IMiyaRegistry(d.registry), IPoolManager(c.poolManager), c.zRouter, c.alignmentToken, c.imd, _alignmentKey(c)
        );
        d.vaultFactory = address(vaultFactory);
        d.vaultImplementation = vaultFactory.vaultImplementation();

        // 4-6. Collection factories.
        d.dropFactory = _create3(
            deployer,
            c.saltNamespace,
            "ERC721DropFactory",
            abi.encodePacked(type(ERC721DropFactory).creationCode, abi.encode(d.registry, c.weth))
        );
        d.auctionFactory = address(new ERC721AuctionFactory(IMiyaRegistry(d.registry), c.weth));
        ERC1155Factory erc1155Factory = new ERC1155Factory(IMiyaRegistry(d.registry), c.weth);
        d.erc1155Factory = address(erc1155Factory);

        // 7. Modules.
        d.dynamicPricingModule = address(new DynamicPricingModule());
        if (c.deployGatingModule) d.gatingModule = address(new PasswordTierGatingModule(d.registry));

        // 8. Pool factory (ownerless, CREATE3 → same address on every chain for the same deployer/namespace).
        d.poolFactory = _create3(deployer, c.saltNamespace, "MiyaPoolFactory", type(MiyaPoolFactory).creationCode);

        // 9. Registry wiring.
        // Unset KEEPER leaves vault conversions paused until the owner calls setConversionKeeper.
        registry.setConversionKeeper(c.keeper);
        registry.setVaultFactory(d.vaultFactory, true);
        registry.setFactory(d.dropFactory, true);
        registry.setFactory(d.auctionFactory, true);
        registry.setFactory(d.erc1155Factory, true);
        registry.setComponent(d.dynamicPricingModule, true);
        if (d.gatingModule != address(0)) registry.setComponent(d.gatingModule, true);
        erc1155Factory.setDynamicPricingModule(d.dynamicPricingModule);

        // 9b. Payment-token allowlist (registry); swap targets, the ETH-claim pool and per-token contribution minimums
        //     (vault factory), per docs/IMD-INFER-VAULT.md. ETH is always allowed.
        _wirePayments(c, registry, vaultFactory);

        // 10. Default alignment target + vault (VITE_MUSIC_VAULT_<chainId>).
        address[] memory tokens = new address[](2);
        tokens[0] = d.alignmentToken;
        tokens[1] = c.imd;
        d.alignmentTargetId = registry.addTarget(c.alignmentTargetName, tokens);
        bytes32 vaultSalt = bytes32(
            abi.encodePacked(
                d.vaultFactory, bytes1(0x00), bytes11(keccak256(abi.encodePacked(c.saltNamespace, "defaultVault")))
            )
        );
        d.defaultVault = vaultFactory.deployVault(vaultSalt, d.alignmentTargetId);

        // 11. Ownership handoff (one-step solady transferOwnership; the Safe needs no acceptance tx).
        if (c.owner != deployer) {
            registry.transferOwnership(c.owner);
            vaultFactory.transferOwnership(c.owner);
            Ownable(d.auctionFactory).transferOwnership(c.owner);
            erc1155Factory.transferOwnership(c.owner);
            Ownable(d.dynamicPricingModule).transferOwnership(c.owner);
            if (d.gatingModule != address(0)) Ownable(d.gatingModule).transferOwnership(c.owner);
        }

        _check(c, d);
    }

    // ── post-deploy checks ──────────────────────────────────────────────────

    function _check(Config memory c, Deployment memory d) internal view {
        MiyaRegistry r = MiyaRegistry(d.registry);
        _eq(r.owner(), c.owner, "registry.owner");
        _eq(r.treasury(), c.treasury, "registry.treasury");
        _t(r.protocolFeeBps() == c.protocolFeeBps, "registry.protocolFeeBps");
        _t(r.minAlignmentBps() == c.minAlignmentBps, "registry.minAlignmentBps");
        _t(r.isVaultFactoryRegistered(d.vaultFactory), "vault factory registered");
        _t(r.isFactoryRegistered(d.dropFactory), "drop factory registered");
        _t(r.isFactoryRegistered(d.auctionFactory), "auction factory registered");
        _t(r.isFactoryRegistered(d.erc1155Factory), "1155 factory registered");
        _t(r.isApprovedComponent(d.dynamicPricingModule), "dynamic pricing approved");
        if (d.gatingModule != address(0)) _t(r.isApprovedComponent(d.gatingModule), "gating approved");
        _t(r.isAlignmentTargetActive(d.alignmentTargetId), "target active");
        _t(r.isTokenInTarget(d.alignmentTargetId, d.alignmentToken), "token in target");
        _t(r.isVault(d.defaultVault), "default vault registered");

        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);
        _eq(vf.owner(), c.owner, "vaultFactory.owner");
        _eq(address(vf.registry()), d.registry, "vaultFactory.registry");
        _eq(address(vf.poolManager()), c.poolManager, "vaultFactory.poolManager");
        _eq(vf.zRouter(), c.zRouter, "vaultFactory.zRouter");
        _eq(vf.infer(), d.alignmentToken, "vaultFactory.infer");
        _eq(vf.imd(), c.imd, "vaultFactory.imd");

        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        _eq(v.owner(), d.vaultFactory, "vault.owner");
        _eq(v.infer(), d.alignmentToken, "vault.infer");
        _eq(v.imd(), c.imd, "vault.imd");
        _eq(address(v.registry()), d.registry, "vault.registry");
        _eq(address(v.config()), d.vaultFactory, "vault.config");
        _eq(v.protocolTreasury(), c.treasury, "vault.protocolTreasury");
        PoolKey memory vk = v.alignmentPoolKey();
        PoolKey memory ek = _alignmentKey(c);
        _t(PoolId.unwrap(vk.toId()) == PoolId.unwrap(ek.toId()), "vault alignment pool key");

        ERC1155Factory f1155 = ERC1155Factory(d.erc1155Factory);
        _eq(f1155.owner(), c.owner, "1155.owner");
        _eq(address(f1155.registry()), d.registry, "1155.registry");
        _eq(f1155.weth(), c.weth, "1155.weth");
        _eq(f1155.dynamicPricingModule(), d.dynamicPricingModule, "1155.dynamicPricingModule");

        ERC721AuctionFactory fa = ERC721AuctionFactory(d.auctionFactory);
        _eq(fa.owner(), c.owner, "auction.owner");
        _eq(address(fa.registry()), d.registry, "auction.registry");
        _eq(fa.weth(), c.weth, "auction.weth");

        ERC721DropFactory fd = ERC721DropFactory(d.dropFactory);
        _eq(address(fd.registry()), d.registry, "drop.registry");
        _eq(fd.weth(), c.weth, "drop.weth");

        _eq(Ownable(d.dynamicPricingModule).owner(), c.owner, "dynamicPricing.owner");
        _t(d.poolFactory.code.length > 0, "pool factory code");
        _checkPayments(c, d);
    }

    // ── payment tokens, swap targets, pools ─────────────────────────────────

    /// @dev JSON keys in alphabetical order, as vm.parseJson decodes struct fields.
    struct ConfigMin {
        uint256 amount;
        address token;
    }

    function _configMins(string memory json) internal view returns (ConfigMin[] memory mins) {
        if (!vm.keyExistsJson(json, ".minContributions")) return mins;
        mins = abi.decode(vm.parseJson(json, ".minContributions"), (ConfigMin[]));
    }

    function _configJson() internal view returns (string memory) {
        return vm.readFile(vm.envOr("MIYAMINTS_CONFIG", configPath(block.chainid)));
    }

    function _wirePayments(Config memory c, MiyaRegistry registry, UniAlignmentVaultFactory vaultFactory) internal {
        string memory json = _configJson();
        if (vm.keyExistsJson(json, ".paymentTokens")) {
            address[] memory toks = vm.parseJsonAddressArray(json, ".paymentTokens");
            for (uint256 i; i < toks.length; ++i) registry.setPaymentToken(toks[i], true);
        }
        for (uint256 i; i < c.swapTargets.length; ++i) vaultFactory.setSwapTarget(c.swapTargets[i], true);
        vaultFactory.setEthPool(c.ethPoolFee, c.ethPoolTickSpacing);
        ConfigMin[] memory mins = _configMins(json);
        for (uint256 i; i < mins.length; ++i) vaultFactory.setMinContribution(mins[i].token, mins[i].amount);
    }

    /// @dev Every configured payment token is allowed, every configured swap target is allowed, the ETH-claim pool is
    ///      the configured one, every configured minimum is set (an allowed token without one is flagged: it would take
    ///      dust), and both pools the vault uses are live on the PoolManager (unless ALLOW_MISSING_POOL). Each check
    ///      runs on its own: a missing config key skips only the checks that need it.
    function _checkPayments(Config memory c, Deployment memory d) internal view {
        string memory json = _configJson();
        MiyaRegistry r = MiyaRegistry(d.registry);
        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);
        address[] memory toks;
        if (vm.keyExistsJson(json, ".paymentTokens")) toks = vm.parseJsonAddressArray(json, ".paymentTokens");
        for (uint256 i; i < toks.length; ++i) _t(r.isPaymentToken(toks[i]), "payment token allowed");

        for (uint256 i; i < c.swapTargets.length; ++i) _t(vf.isSwapTarget(c.swapTargets[i]), "swap target allowed");
        if (c.swapTargets.length == 0) _loud("swapTargets is empty: the keeper has no swap target, so only ETH-free IMD/INFER batches can convert");
        (uint24 fee, int24 ts) = vf.ethPool();
        _t(fee == c.ethPoolFee && ts == c.ethPoolTickSpacing, "vault factory ethPool");

        ConfigMin[] memory mins = _configMins(json);
        for (uint256 i; i < mins.length; ++i) {
            _t(vf.minContribution(mins[i].token) == mins[i].amount, "min contribution set");
        }
        if (mins.length != 0) {
            for (uint256 i; i < toks.length; ++i) _t(vf.minContribution(toks[i]) != 0, "payment token has a minimum");
        }

        if (!c.allowMissingPool) {
            _requirePool(c, _alignmentKey(c), "INFER/IMD alignment pool (alignmentPool)");
            _requirePool(c, _ethPoolKey(c), "ETH/IMD pool for ETH claims (ethPool)");
        }
        if (MiyaRegistry(d.registry).conversionKeeper() == address(0)) {
            _loud("KEEPER is unset: conversions are paused until the owner calls registry.setConversionKeeper");
        }
    }

    function _loud(string memory what) internal pure {
        console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        console2.log(string.concat("!! WARNING: ", what));
        console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
    }

    // ── output ──────────────────────────────────────────────────────────────

    function _finish(Config memory c, Deployment memory d) internal {
        if (c.owner == address(0)) c.owner = d.deployer;
        if (c.treasury == address(0)) c.treasury = d.deployer;
        string memory id = block.chainid.toString();

        console2.log("== miyamints deployed on %s (chain %s) ==", c.name, id);
        console2.log("MiyaRegistry              ", d.registry);
        console2.log("UniAlignmentVaultFactory  ", d.vaultFactory);
        console2.log("  vault implementation    ", d.vaultImplementation);
        console2.log("ERC721DropFactory         ", d.dropFactory);
        console2.log("ERC721AuctionFactory      ", d.auctionFactory);
        console2.log("ERC1155Factory (music)    ", d.erc1155Factory);
        console2.log("DynamicPricingModule      ", d.dynamicPricingModule);
        if (d.gatingModule != address(0)) console2.log("PasswordTierGatingModule  ", d.gatingModule);
        console2.log("MiyaPoolFactory           ", d.poolFactory);
        console2.log("default vault             ", d.defaultVault);
        console2.log("  alignment token         ", d.alignmentToken);
        console2.log("  alignment target id     ", d.alignmentTargetId);
        console2.log("treasury                  ", c.treasury);
        console2.log("owner                     ", c.owner);
        console2.log("conversion keeper         ", c.keeper);
        if (c.owner == d.deployer) {
            console2.log("");
            console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            console2.log("!! WARNING: OWNER not set. The DEPLOYER EOA owns MiyaRegistry and every Ownable factory/module.");
            console2.log("!! Hand off to the Safe (DEPLOY.md step 6) before announcing any address.");
            console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        }

        console2.log("");
        console2.log("== app env (app/.env.local or Vercel) ==");
        _env("VITE_MUSIC_FACTORY_", id, d.erc1155Factory);
        _env("VITE_MUSIC_VAULT_", id, d.defaultVault);
        _env("VITE_MIYA_REGISTRY_", id, d.registry);
        _env("VITE_ERC721_DROP_FACTORY_", id, d.dropFactory);
        _env("VITE_ERC721_AUCTION_FACTORY_", id, d.auctionFactory);
        _env("VITE_MIYA_POOL_FACTORY_", id, d.poolFactory);
        _env("VITE_VAULT_FACTORY_", id, d.vaultFactory);

        // Tests never write. A dry run writes a gitignored *.local.json so nobody mistakes simulated addresses for
        // real ones; only a broadcast writes deployments/<chainId>.json (which the app reads).
        if (vm.isContext(VmSafe.ForgeContext.TestGroup)) return;
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", id, live ? ".json" : ".dryrun.local.json"
        );
        vm.writeJson(_json(c, d), path);
        console2.log("");
        console2.log("addresses written to", path);
    }

    function _json(Config memory c, Deployment memory d) internal returns (string memory out) {
        string memory k = "miyamints";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "block", block.number);
        vm.serializeAddress(k, "deployer", d.deployer);
        vm.serializeAddress(k, "owner", c.owner);
        vm.serializeAddress(k, "treasury", c.treasury);
        vm.serializeAddress(k, "registry", d.registry);
        vm.serializeAddress(k, "vaultFactory", d.vaultFactory);
        vm.serializeAddress(k, "vaultImplementation", d.vaultImplementation);
        vm.serializeAddress(k, "erc721DropFactory", d.dropFactory);
        vm.serializeAddress(k, "erc721AuctionFactory", d.auctionFactory);
        vm.serializeAddress(k, "erc1155Factory", d.erc1155Factory);
        vm.serializeAddress(k, "dynamicPricingModule", d.dynamicPricingModule);
        vm.serializeAddress(k, "gatingModule", d.gatingModule);
        vm.serializeAddress(k, "miyaPoolFactory", d.poolFactory);
        vm.serializeAddress(k, "defaultVault", d.defaultVault);
        vm.serializeAddress(k, "alignmentToken", d.alignmentToken);
        vm.serializeUint(k, "alignmentTargetId", d.alignmentTargetId);
        vm.serializeAddress(k, "weth", c.weth);
        vm.serializeAddress(k, "poolManager", c.poolManager);
        vm.serializeAddress(k, "zRouter", c.zRouter);
        vm.serializeString(k, "saltNamespace", c.saltNamespace);
        // What was deployed: the commit script/deploy.sh checked ("" on a dry run outside it).
        vm.serializeString(k, "gitCommit", c.gitCommit);
        vm.serializeString(k, "gitRef", c.gitRef);
        out = vm.serializeUint(k, "protocolFeeBps", c.protocolFeeBps);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// @dev CREATE3 via CreateX with a permissioned salt: deployer (20 bytes) ‖ 0x00 (no cross-chain redeploy
    ///      protection, so the address is the same on every chain) ‖ 11 bytes of keccak(namespace, label).
    function _create3(address deployer, string memory ns, string memory label, bytes memory initCode)
        internal
        returns (address deployed)
    {
        bytes32 salt =
            bytes32(abi.encodePacked(deployer, bytes1(0x00), bytes11(keccak256(abi.encodePacked(ns, ".", label)))));
        bytes32 guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
        address predicted = ICreateX(CREATEX).computeCreate3Address(guarded);
        if (predicted.code.length != 0) {
            revert ConfigError(string.concat(label, " already deployed at this salt: change SALT_NAMESPACE"));
        }
        deployed = ICreateX(CREATEX).deployCreate3(salt, initCode);
        if (deployed != predicted) revert CheckFailed(string.concat(label, " CREATE3 address mismatch"));
    }

    /// @dev The INFER/IMD alignment pool (sorted currencies), as configured.
    function _alignmentKey(Config memory c) internal pure returns (PoolKey memory key) {
        (address a, address b) = c.alignmentToken < c.imd ? (c.alignmentToken, c.imd) : (c.imd, c.alignmentToken);
        key = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: c.alignmentPoolFee,
            tickSpacing: c.alignmentPoolTickSpacing,
            hooks: IHooks(c.alignmentPoolHook)
        });
    }

    /// @dev The hookless native-ETH/IMD pool ETH-mode claims sell IMD into, as configured.
    function _ethPoolKey(Config memory c) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(c.imd),
            fee: c.ethPoolFee,
            tickSpacing: c.ethPoolTickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /// @dev `key` is initialized on the PoolManager with liquidity in range (read through extsload); prints both for a
    ///      human to compare with the market.
    function _requirePool(Config memory c, PoolKey memory key, string memory what) internal view {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(c.poolManager).getSlot0(id);
        if (sqrtPriceX96 == 0) {
            revert ConfigError(
                string.concat(
                    what,
                    " not initialized at fee ",
                    uint256(key.fee).toString(),
                    " / tickSpacing ",
                    uint256(int256(key.tickSpacing)).toString(),
                    ". ALLOW_MISSING_POOL=true to deploy anyway"
                )
            );
        }
        uint128 liquidity = IPoolManager(c.poolManager).getLiquidity(id);
        if (liquidity == 0) revert ConfigError(string.concat(what, " has no liquidity in range"));
        console2.log(string.concat(what, ": in-range liquidity"), uint256(liquidity));
        console2.log(string.concat(what, ": sqrtPriceX96; compare with the market"), uint256(sqrtPriceX96));
    }

    function _requireCode(address a, string memory what) internal view {
        if (a == address(0) || a.code.length == 0) revert ConfigError(string.concat(what, " has no code on this chain"));
    }

    function _env(string memory prefix, string memory id, address a) internal pure {
        console2.log(string.concat(prefix, id, "=", a.toHexStringChecksummed()));
    }

    function _eq(address a, address b, string memory what) internal pure {
        if (a != b) revert CheckFailed(what);
    }

    function _t(bool ok, string memory what) internal pure {
        if (!ok) revert CheckFailed(what);
    }
}
