// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "solady/auth/Ownable.sol";
import "forge-std/Test.sol";
import "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract UniAlignmentVaultFactoryTest is Test {
    UniAlignmentVaultFactory public factory;
    MockEXECToken public alignmentToken;
    MiyaRegistry public registry;

    address public owner;
    address public mockPoolManager;
    address public mockWeth;

    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockPriceValidator;

    uint256 internal _saltCounter;

    uint256 constant TARGET_ID = 0;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        owner = address(this);
        mockPoolManager = makeAddr("poolManager");
        mockWeth = makeAddr("weth");

        alignmentToken = new MockEXECToken(1000000e18);

        mockZRouter = new MockZRouter();
        mockPriceValidator = new MockVaultPriceValidator();
        registry = new MiyaRegistry(address(this), address(0xFEE), 100, 1000);
        address[] memory targetTokens = new address[](1);
        targetTokens[0] = address(alignmentToken);
        registry.addTarget("Test target", targetTokens);

        factory = new UniAlignmentVaultFactory(
            mockWeth,
            mockPoolManager,
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockPriceValidator)),
            IMiyaRegistry(address(registry))
        );
        registry.setVaultFactory(address(factory), true);
    }

    function test_deployVault_ownerOnly() public {
        bytes32 salt = _nextSalt();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.deployVault(salt, address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0)));
    }

    function test_deployVault_setsAlignmentToken() public {
        address vault = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );

        assertEq(UniAlignmentVault(payable(vault)).alignmentToken(), address(alignmentToken));
    }

    function test_deployVault_usesFactoryZRouterConfig() public {
        address vault = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );

        assertEq(UniAlignmentVault(payable(vault)).zRouter(), factory.zRouter(), "Should use factory zRouter");
        assertEq(UniAlignmentVault(payable(vault)).zRouterFee(), factory.zRouterFee(), "Should use factory fee");
        assertEq(UniAlignmentVault(payable(vault)).zRouterTickSpacing(), factory.zRouterTickSpacing(), "Should use factory tickSpacing");
        assertEq(
            address(UniAlignmentVault(payable(vault)).priceValidator()),
            address(factory.defaultPriceValidator()),
            "Should use default price validator"
        );
    }

    function test_deployVault_acceptsCustomPriceValidator() public {
        MockVaultPriceValidator customValidator = new MockVaultPriceValidator();

        address vault = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(customValidator))
        );

        assertEq(
            address(UniAlignmentVault(payable(vault)).priceValidator()),
            address(customValidator),
            "Should use custom price validator"
        );
    }

    function test_deployVault_differentInstancesAreIndependent() public {
        MockEXECToken token2 = new MockEXECToken(1000000e18);
        address[] memory t2 = new address[](1);
        t2[0] = address(token2);
        uint256 target2 = registry.addTarget("Second target", t2);

        address vault1 = factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );

        address vault2 = factory.deployVault(
            _nextSalt(),
            address(token2),
            target2,
            IVaultPriceValidator(address(0))
        );

        assertTrue(vault1 != vault2, "Vaults should be different addresses");
        assertEq(UniAlignmentVault(payable(vault1)).alignmentToken(), address(alignmentToken));
        assertEq(UniAlignmentVault(payable(vault2)).alignmentToken(), address(token2));
    }

    function test_deployVault_emitsVaultDeployed() public {
        vm.expectEmit(false, true, false, false);
        emit VaultDeployed(address(0), address(alignmentToken));

        factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );
    }

    function test_deployVault_revertsWhenTokenNotInTarget() public {
        address rogueToken = address(0xBAD);

        vm.expectRevert(UniAlignmentVault.TokenNotInTarget.selector);
        factory.deployVault(
            _nextSalt(),
            rogueToken,
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );
    }

    function test_deployVault_revertsWhenTargetNotActive() public {
        registry.setTargetActive(TARGET_ID, false);

        vm.expectRevert(UniAlignmentVault.TargetNotActive.selector);
        factory.deployVault(
            _nextSalt(),
            address(alignmentToken),
            TARGET_ID,
            IVaultPriceValidator(address(0))
        );
    }

    function test_constructor_storesAddresses() public view {
        assertEq(factory.weth(), mockWeth);
        assertEq(factory.poolManager(), mockPoolManager);
        assertEq(factory.zRouter(), address(mockZRouter));
        assertEq(factory.zRouterFee(), 3000);
        assertEq(factory.zRouterTickSpacing(), 60);
        assertEq(address(factory.defaultPriceValidator()), address(mockPriceValidator));
        assertEq(address(factory.registry()), address(registry));
        assertTrue(factory.vaultImplementation() != address(0));
    }

    // ── MiyaRegistry vault registration ─────────────────────────────────────

    function test_deployVault_registersVaultInRegistry() public {
        address vault = factory.deployVault(
            _nextSalt(), address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0))
        );
        assertTrue(registry.isVault(vault), "vault should be registered");
        assertFalse(registry.isVault(address(0xdead)));
    }

    function test_deployVault_emitsVaultRegistered() public {
        bytes32 salt = _nextSalt();
        address predicted = factory.computeVaultAddress(salt);
        vm.expectEmit(true, true, false, false, address(registry));
        emit MiyaRegistry.VaultRegistered(predicted, address(factory));
        factory.deployVault(salt, address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0)));
    }

    function test_deployVault_revertsWhenFactoryNotRegistered() public {
        registry.setVaultFactory(address(factory), false);
        bytes32 salt = _nextSalt();
        vm.expectRevert(MiyaRegistry.NotVaultFactory.selector);
        factory.deployVault(salt, address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0)));
    }

    // ── Audit M4: pool key fixed at deploy, hookless, never repointable ──

    function test_deployVault_setsHooklessPoolKeyOnce() public {
        address vault = factory.deployVault(
            _nextSalt(), address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0))
        );
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            UniAlignmentVault(payable(vault)).v4PoolKey();
        assertEq(Currency.unwrap(c0), address(0));
        assertEq(Currency.unwrap(c1), address(alignmentToken));
        assertEq(fee, 3000);
        assertEq(tickSpacing, 60);
        assertEq(address(hooks), address(0));
        UniAlignmentVault(payable(vault)).validateCurrentPoolKey();
    }

    function test_poolKeyCannotBeRepointed() public {
        address vault = factory.deployVault(
            _nextSalt(), address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0))
        );
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        // Factory owner has no passthrough, and calling the vault directly is not the vault owner.
        vm.expectRevert(Ownable.Unauthorized.selector);
        UniAlignmentVault(payable(vault)).setV4PoolKey(other);
        // Even the vault owner (the factory) cannot change it after deploy.
        vm.prank(address(factory));
        vm.expectRevert(UniAlignmentVault.PoolKeyAlreadySet.selector);
        UniAlignmentVault(payable(vault)).setV4PoolKey(other);
    }

    function test_saltNotBoundToFactoryIsRefused() public {
        bytes32 unbound = keccak256("vault-2");
        vm.expectRevert(UniAlignmentVaultFactory.InvalidVaultSalt.selector);
        factory.deployVault(unbound, address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0)));
        vm.expectRevert(UniAlignmentVaultFactory.InvalidVaultSalt.selector);
        factory.computeVaultAddress(unbound);
    }

    function test_saltWithChainFlagIsRefused() public {
        bytes32 flagged = bytes32(abi.encodePacked(address(factory), uint8(0x01), bytes11(uint88(1))));
        vm.expectRevert(UniAlignmentVaultFactory.InvalidVaultSalt.selector);
        factory.computeVaultAddress(flagged);
    }

    function test_previewMatchesDeployment() public {
        bytes32 salt = _nextSalt();
        address preview = factory.computeVaultAddress(salt);
        address vault = factory.deployVault(salt, address(alignmentToken), TARGET_ID, IVaultPriceValidator(address(0)));
        assertEq(vault, preview);
    }

    function test_implementationCannotBeClaimed() public {
        UniAlignmentVault impl = UniAlignmentVault(payable(factory.vaultImplementation()));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        impl.initialize(
            makeAddr("stranger"),
            address(1),
            address(2),
            address(alignmentToken),
            address(3),
            3000,
            60,
            IVaultPriceValidator(address(0)),
            IMiyaRegistry(address(registry)),
            TARGET_ID
        );
    }
}
