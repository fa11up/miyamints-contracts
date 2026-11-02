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
import { UniswapVaultPriceValidator } from "../src/peripherals/UniswapVaultPriceValidator.sol";
import { IVaultPriceValidator } from "../src/interfaces/IVaultPriceValidator.sol";
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
 *         Order: [test token] → MiyaRegistry → UniswapVaultPriceValidator → UniAlignmentVaultFactory →
 *         ERC721DropFactory → ERC721AuctionFactory → ERC1155Factory → DynamicPricingModule → [gating module] →
 *         MiyaPoolFactory → registry wiring → default alignment target + vault → ownership handoff → checks → JSON.
 *
 *         Addressing: contracts that take their owner as an argument or have none (registry, price validator,
 *         drop factory, pool factory) are deployed with CreateX CREATE3 and a deployer-permissioned salt, so the
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
        address zRouter;
        uint24 zRouterFee;
        int24 zRouterTickSpacing;
        address v2Factory;
        address v3Factory;
        address createX;
        uint16 protocolFeeBps;
        uint16 minAlignmentBps;
        uint256 maxPriceDeviationBps;
        uint32 twapSeconds;
        string alignmentTargetName;
        address alignmentToken;
        bool deployMockAlignmentToken;
        bool deployGatingModule;
        bool allowMissingPool;
        string saltNamespace;
    }

    struct Deployment {
        address deployer;
        address registry;
        address priceValidator;
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
        c.zRouterFee = uint24(vm.parseJsonUint(json, ".zRouterFee"));
        c.zRouterTickSpacing = int24(vm.parseJsonInt(json, ".zRouterTickSpacing"));
        c.v2Factory = vm.parseJsonAddress(json, ".v2Factory");
        c.v3Factory = vm.parseJsonAddress(json, ".v3Factory");
        c.createX = vm.parseJsonAddress(json, ".createX");
        c.protocolFeeBps = uint16(vm.envOr("PROTOCOL_FEE_BPS", vm.parseJsonUint(json, ".protocolFeeBps")));
        c.minAlignmentBps = uint16(vm.envOr("MIN_ALIGNMENT_BPS", vm.parseJsonUint(json, ".minAlignmentBps")));
        c.maxPriceDeviationBps = vm.parseJsonUint(json, ".maxPriceDeviationBps");
        c.twapSeconds = uint32(vm.parseJsonUint(json, ".twapSeconds"));
        c.alignmentTargetName = vm.envOr("ALIGNMENT_TARGET_NAME", vm.parseJsonString(json, ".alignmentTargetName"));
        c.alignmentToken = vm.envOr("ALIGNMENT_TOKEN", vm.parseJsonAddress(json, ".alignmentToken"));
        c.deployMockAlignmentToken = vm.parseJsonBool(json, ".deployMockAlignmentToken");
        c.deployGatingModule = vm.envOr("DEPLOY_GATING_MODULE", vm.parseJsonBool(json, ".deployGatingModule"));
        c.allowMissingPool = vm.envOr("ALLOW_MISSING_POOL", c.deployMockAlignmentToken);
        c.saltNamespace = vm.envOr("SALT_NAMESPACE", string("miyamints.v1"));

        if (c.createX != CREATEX) revert ConfigError("createX must be the canonical CreateX the factories hardcode");
        if (c.protocolFeeBps > 500) revert ConfigError("protocolFeeBps > MAX_PROTOCOL_FEE_BPS (500)");
        // External dependencies must exist on this chain.
        _requireCode(c.weth, "weth");
        _requireCode(c.poolManager, "poolManager");
        _requireCode(c.zRouter, "zRouter");
        _requireCode(c.createX, "createX");
        if (c.v3Factory != address(0)) _requireCode(c.v3Factory, "v3Factory");
        if (c.v2Factory != address(0)) _requireCode(c.v2Factory, "v2Factory");
        if (c.alignmentToken != address(0)) _requireCode(c.alignmentToken, "alignmentToken");
        if (c.alignmentToken == address(0) && !c.deployMockAlignmentToken) {
            revert ConfigError("alignmentToken unset: set ALIGNMENT_TOKEN");
        }
        if (c.treasury == address(0) && !c.deployMockAlignmentToken) {
            revert ConfigError("treasury unset for this chain: set TREASURY (a Safe/treasury you control here)");
        }
    }

    // ── deployment ──────────────────────────────────────────────────────────

    function _deployAll(Config memory c, address deployer) internal returns (Deployment memory d) {
        d.deployer = deployer;
        if (c.owner == address(0)) c.owner = deployer;
        if (c.treasury == address(0)) c.treasury = deployer; // testnet only (loadConfig enforces)

        // 0. Testnet alignment token.
        d.alignmentToken = c.alignmentToken;
        if (d.alignmentToken == address(0)) {
            d.alignmentToken = address(new TestAlignmentToken(deployer, 1_000_000_000e18));
            c.alignmentToken = d.alignmentToken;
        }
        if (!c.allowMissingPool) _requirePool(c);

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

        // 2. Price validator (ownerless).
        d.priceValidator = _create3(
            deployer,
            c.saltNamespace,
            "UniswapVaultPriceValidator",
            abi.encodePacked(
                type(UniswapVaultPriceValidator).creationCode,
                abi.encode(c.weth, c.v2Factory, c.v3Factory, c.poolManager, c.maxPriceDeviationBps, c.twapSeconds)
            )
        );

        // 3. Vault factory (Ownable(msg.sender) → CREATE). Deploys its own vault implementation.
        UniAlignmentVaultFactory vaultFactory = new UniAlignmentVaultFactory(
            c.weth,
            c.poolManager,
            c.zRouter,
            c.zRouterFee,
            c.zRouterTickSpacing,
            IVaultPriceValidator(d.priceValidator),
            IMiyaRegistry(d.registry)
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
        registry.setVaultFactory(d.vaultFactory, true);
        registry.setFactory(d.dropFactory, true);
        registry.setFactory(d.auctionFactory, true);
        registry.setFactory(d.erc1155Factory, true);
        registry.setComponent(d.dynamicPricingModule, true);
        if (d.gatingModule != address(0)) registry.setComponent(d.gatingModule, true);
        erc1155Factory.setDynamicPricingModule(d.dynamicPricingModule);

        // 10. Default alignment target + vault (VITE_MUSIC_VAULT_<chainId>).
        address[] memory tokens = new address[](1);
        tokens[0] = d.alignmentToken;
        d.alignmentTargetId = registry.addTarget(c.alignmentTargetName, tokens);
        bytes32 vaultSalt = bytes32(
            abi.encodePacked(
                d.vaultFactory, bytes1(0x00), bytes11(keccak256(abi.encodePacked(c.saltNamespace, "defaultVault")))
            )
        );
        d.defaultVault =
            vaultFactory.deployVault(vaultSalt, d.alignmentToken, d.alignmentTargetId, IVaultPriceValidator(address(0)));

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

        UniswapVaultPriceValidator pv = UniswapVaultPriceValidator(d.priceValidator);
        _eq(pv.weth(), c.weth, "validator.weth");
        _eq(pv.poolManager(), c.poolManager, "validator.poolManager");
        _eq(pv.v3Factory(), c.v3Factory, "validator.v3Factory");
        _t(pv.maxPriceDeviationBps() == c.maxPriceDeviationBps, "validator.maxPriceDeviationBps");

        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);
        _eq(vf.owner(), c.owner, "vaultFactory.owner");
        _eq(address(vf.registry()), d.registry, "vaultFactory.registry");
        _eq(vf.weth(), c.weth, "vaultFactory.weth");
        _eq(vf.poolManager(), c.poolManager, "vaultFactory.poolManager");
        _eq(vf.zRouter(), c.zRouter, "vaultFactory.zRouter");
        _t(vf.zRouterFee() == c.zRouterFee && vf.zRouterTickSpacing() == c.zRouterTickSpacing, "vaultFactory fee tier");
        _eq(address(vf.defaultPriceValidator()), d.priceValidator, "vaultFactory.validator");

        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        _eq(v.owner(), d.vaultFactory, "vault.owner");
        _eq(v.alignmentToken(), d.alignmentToken, "vault.alignmentToken");
        _eq(address(v.registry()), d.registry, "vault.registry");
        _eq(v.protocolTreasury(), c.treasury, "vault.protocolTreasury");
        _eq(address(v.priceValidator()), d.priceValidator, "vault.priceValidator");
        (Currency c0, Currency c1, uint24 fee, int24 ts, IHooks hooks) = v.v4PoolKey();
        _t(Currency.unwrap(c0) == address(0) && Currency.unwrap(c1) == d.alignmentToken, "vault pool currencies");
        _t(fee == c.zRouterFee && ts == c.zRouterTickSpacing && address(hooks) == address(0), "vault pool tier");
        v.validateCurrentPoolKey();

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
    }

    // ── output ──────────────────────────────────────────────────────────────

    function _finish(Config memory c, Deployment memory d) internal {
        if (c.owner == address(0)) c.owner = d.deployer;
        if (c.treasury == address(0)) c.treasury = d.deployer;
        string memory id = block.chainid.toString();

        console2.log("== miyamints deployed on %s (chain %s) ==", c.name, id);
        console2.log("MiyaRegistry              ", d.registry);
        console2.log("UniswapVaultPriceValidator", d.priceValidator);
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
        vm.serializeAddress(k, "priceValidator", d.priceValidator);
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
        vm.serializeUint(k, "zRouterFee", c.zRouterFee);
        vm.serializeString(k, "saltNamespace", c.saltNamespace);
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

    function _requirePool(Config memory c) internal view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(c.alignmentToken),
            fee: c.zRouterFee,
            tickSpacing: c.zRouterTickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(c.poolManager).getSlot0(id);
        if (sqrtPriceX96 == 0) revert ConfigError("no hookless native-ETH v4 pool for alignmentToken at zRouterFee");
        if (IPoolManager(c.poolManager).getLiquidity(id) == 0) {
            revert ConfigError("alignmentToken v4 pool at zRouterFee has zero in-range liquidity");
        }
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
