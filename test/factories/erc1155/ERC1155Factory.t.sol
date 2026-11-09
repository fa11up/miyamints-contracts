// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, console2} from "forge-std/Test.sol";
import {ERC1155Factory} from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance, ExceedsSupply, EditionNotOpen, GatingCheckFailed, NoDynamicPricingModule} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {DynamicPricingModule} from "../../../src/factories/erc1155/DynamicPricingModule.sol";
import {MockVaultV2} from "../payments/PaymentMocks.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {PaymentLib} from "../../../src/libraries/PaymentLib.sol";
import {TokenPrice} from "../../../src/factories/interfaces/TokenPrice.sol";
import {MiyaRegistry} from "../../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {PasswordTierGatingModule} from "../../../src/gating/PasswordTierGatingModule.sol";

contract MockRejectGatingModule {
    function canMint(address, uint256, bytes calldata) external pure returns (bool allowed, bool permanent) {
        allowed = false;
        permanent = false;
    }
    function onMint(address, uint256) external {}
}

contract MockAllowGatingModule {
    function canMint(address, uint256, bytes calldata) external pure returns (bool allowed, bool permanent) {
        allowed = true;
        permanent = false;
    }
    function onMint(address, uint256) external {}
}

/**
 * @title ERC1155FactoryTest
 * @notice Comprehensive test suite for ERC1155 Factory
 */
contract ERC1155FactoryTest is Test {
    ERC1155Factory public factory;
    MockVaultV2 public vault;
    MockEXECToken public token;
    MiyaRegistry public registry;
    DynamicPricingModule public dynamicPricingModule;

    uint256 internal _saltCounter;

    uint256 constant TARGET_ID = 0;
    uint16 constant ALIGNMENT_BPS = 1900; // 1% protocol / 19% vault / 80% artist
    address constant TREASURY = address(0xFEE7);

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public minter1 = address(0x3);
    address public minter2 = address(0x4);
    address public artist = address(0x5);
    address public registryOwner = address(0x6);

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    /// @dev Default CreateParams with no gating and no free mint
    function _params(
        string memory _name,
        address _creator,
        address _vault
    ) internal pure returns (ERC1155Factory.CreateParams memory) {
        return ERC1155Factory.CreateParams({
            name: _name,
            metadataURI: "ipfs://test",
            creator: _creator,
            vault: _vault,
            alignmentBps: ALIGNMENT_BPS,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
            acceptedTokens: _ethOnly()
        });
    }

    function _ethOnly() internal pure returns (address[] memory t) {
        t = new address[](1); // ETH
    }

    function _eth(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

    function setUp() public {
        vm.startPrank(owner);
        vm.etch(CREATEX, CREATEX_BYTECODE);

        // Deploy mock token for vault
        token = new MockEXECToken(1000000e18);

        // Deploy the protocol registry (1% protocol fee, 10% minimum alignment)
        registry = new MiyaRegistry(registryOwner, TREASURY, 100, 1000);
        vm.stopPrank();
        vm.startPrank(registryOwner);
        {
            address[] memory targetTokens = new address[](1);
            targetTokens[0] = address(token);
            registry.addTarget("Test target", targetTokens);
        }
        vm.stopPrank();
        vm.startPrank(owner);

        // Vault v2 stand-in (collections only send it their cut); the real vault keeps a 0.001 ETH minimum.
        vault = new MockVaultV2();
        vault.setMinContribution(address(0), 0.001 ether);

        // Deploy factory
        factory = new ERC1155Factory(IMiyaRegistry(address(registry)), address(0xBEEF));
        dynamicPricingModule = new DynamicPricingModule();
        vm.stopPrank();

        // Registry owner: register factory, register the vault (this test acts as its vault factory),
        // approve the dynamic pricing module
        vm.startPrank(registryOwner);
        registry.setFactory(address(factory), true);
        registry.setVaultFactory(registryOwner, true);
        registry.registerVault(address(vault));
        registry.setComponent(address(dynamicPricingModule), true);
        vm.stopPrank();

        vm.prank(owner);
        factory.setDynamicPricingModule(address(dynamicPricingModule));
    }

    function test_FactoryCreation() public view {
        // Factory should have been created and linked to the mock registry
        assertEq(address(factory.registry()), address(registry));
        assertEq(factory.weth(), address(0xBEEF));
    }

    function test_computeInstanceAddress() public {
        bytes32 salt = _nextSalt();
        address predicted = factory.computeInstanceAddress(salt, creator);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address actual = factory.createInstance{value: 0}(
            salt, _params("PredictTest", creator, address(vault))
        );
        assertEq(actual, predicted, "Instance should deploy at predicted CREATE3 address");
    }

    function test_CreateInstance() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0.01 ether}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "Test Collection",
                metadataURI: "ipfs://test",
                creator: creator,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: address(0),
                freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
                acceptedTokens: _ethOnly()
            })
        );

        assertTrue(instance != address(0));

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        assertEq(instanceContract.name(), "Test Collection");
        assertEq(instanceContract.creator(), creator);
        assertEq(address(instanceContract.vault()), address(vault));

        vm.stopPrank();
    }

    function test_CreateInstance_NoFeeRequired() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        assertTrue(instance != address(0));

        vm.stopPrank();
    }

    function test_CreateInstance_FeeGoesDirectlyToTreasury() public {
        address treasury = registry.treasury();
        uint256 fee = 0.01 ether;
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        factory.createInstance{value: fee}(
            _nextSalt(), _params("Fee Collection", creator, address(vault))
        );
        vm.stopPrank();

        // Fee goes directly to treasury — factory holds no ETH
        assertEq(treasury.balance, fee, "Treasury should receive fee directly");
        assertEq(address(factory).balance, 0, "Factory must hold no ETH");
    }

    function test_AddEdition_Unlimited() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );

        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            0, // Unlimited
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(edition.id, 1);
        assertEq(edition.pieceTitle, "Piece 1");
        assertEq(edition.prices[0].price, 0.1 ether);
        assertEq(edition.supply, 0);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.UNLIMITED));

        vm.stopPrank();
    }

    function test_AddEdition_LimitedFixed() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );

        ERC1155Instance(payable(instance)).addEdition(
            "Piece 2",
            _eth(0.2 ether),
            100, // Limited
            "ipfs://piece2",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(edition.supply, 100);

        vm.stopPrank();
    }

    function test_AddEdition_LimitedDynamic() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );

        ERC1155Instance(payable(instance)).addEdition(
            "Piece 3",
            _eth(0.1 ether),
            50, // Limited
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100, // 1% increase per mint
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_DYNAMIC));
        assertEq(edition.priceIncreaseRate, 100);

        vm.stopPrank();
    }

    function test_Mint_Unlimited() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            0, // Unlimited
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        // Mint 5 tokens
        instanceContract.mint{value: 0.5 ether}(1, 5, bytes32(0), "", address(0), 0);

        assertEq(instanceContract.balanceOf(minter1, 1), 5);
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(edition.minted, 5);

        vm.stopPrank();
    }

    function test_Mint_LimitedFixed() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 2",
            _eth(0.2 ether),
            10, // Limited to 10
            "ipfs://piece2",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        // Mint 5 tokens
        instanceContract.mint{value: 1 ether}(1, 5, bytes32(0), "", address(0), 0);
        assertEq(instanceContract.balanceOf(minter1, 1), 5);
        ERC1155Instance.Edition memory edition1 = instanceContract.getEdition(1);
        assertEq(edition1.minted, 5);

        // Try to mint 6 more (would exceed supply)
        vm.expectRevert(ExceedsSupply.selector);
        instanceContract.mint{value: 1.2 ether}(1, 6, bytes32(0), "", address(0), 0);

        // Mint remaining 5
        instanceContract.mint{value: 1 ether}(1, 5, bytes32(0), "", address(0), 0);
        ERC1155Instance.Edition memory edition2 = instanceContract.getEdition(1);
        assertEq(edition2.minted, 10);

        vm.stopPrank();
    }

    function test_Mint_LimitedDynamic() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 3",
            _eth(0.1 ether),
            10, // Limited to 10
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100, // 1% increase per mint
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        // Get current price (should be base price for first mint)
        uint256 price1 = instanceContract.getCurrentPrice(1, address(0));
        assertEq(price1, 0.1 ether);

        // Mint 1 token
        instanceContract.mint{value: 0.2 ether}(1, 1, bytes32(0), "", address(0), 0);

        // Price should increase for next mint
        uint256 price2 = instanceContract.getCurrentPrice(1, address(0));
        assertGt(price2, price1);

        vm.stopPrank();
    }

    function test_MintWithMessage() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        vm.expectEmit(true, true, false, true, instance);
        emit ERC1155Instance.MintMessage(minter1, 1, "Hello from minter!");
        instanceContract.mint{value: 0.1 ether}(
            1,
            1,
            bytes32(0), "Hello from minter!", address(0),
            0
        );

        vm.stopPrank();
    }

    /// Audit round 1: anyone can split proceeds, so the cuts never wait on the artist. The artist still gets their share.
    function test_Withdraw_AnyoneCanSplit() public {
        vm.deal(minter1, 10 ether);
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Anyone", creator, address(vault))
        );
        ERC1155Instance inst = ERC1155Instance(payable(instance));
        inst.addEdition("P", _eth(1 ether), 0, "ipfs://p", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.stopPrank();
        vm.prank(minter1);
        inst.mint{value: 1 ether}(1, 1, bytes32(0), "", address(0), 1 ether);

        uint256 before = creator.balance;
        vm.prank(makeAddr("stranger"));
        inst.distribute(address(0));
        assertEq(inst.unsplitProceeds(address(0)), 0);
        assertEq(inst.ownerBalance(address(0)), 0.8 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        inst.withdraw(address(0));
        vm.prank(creator);
        inst.withdraw(address(0));
        assertEq(creator.balance - before, 0.8 ether);
    }

    function test_Withdraw_Tax() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(1 ether),
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        instanceContract.mint{value: 1 ether}(1, 1, bytes32(0), "", address(0), 0);
        vm.stopPrank();

        vm.startPrank(creator);
        // Withdraw the ETH proceeds (split first)
        instanceContract.withdraw(address(0));
        vm.stopPrank();
    }

    function test_UpdateEditionMetadata() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        vm.expectEmit(address(instanceContract));
        emit URI("ipfs://piece1-updated", 1);
        instanceContract.updateEditionMetadata(1, "ipfs://piece1-updated");

        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(edition.metadataURI, "ipfs://piece1-updated");

        vm.stopPrank();
    }

    event URI(string value, uint256 indexed id);

    function test_CalculateMintCost_Dynamic() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 3",
            _eth(0.1 ether),
            10,
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100, // 1% increase
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        // Calculate cost for minting 3 tokens
        uint256 cost = instanceContract.calculateMintCost(1, 3, address(0));
        assertGt(cost, 0.3 ether); // Should be more than base price * 3 due to increases

        vm.stopPrank();
    }

    function test_GetEditionMetadata() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Test Piece",
            _eth(0.1 ether),
            100,
            "ipfs://test-piece",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        ERC1155Instance.Edition memory ed = instanceContract.getEdition(1);
        uint256 currentPrice = instanceContract.getCurrentPrice(1, address(0));

        assertEq(ed.id, 1);
        assertEq(ed.pieceTitle, "Test Piece");
        assertEq(ed.prices[0].price, 0.1 ether);
        assertEq(currentPrice, 0.1 ether);
        assertEq(ed.supply, 100);
        assertEq(ed.minted, 0);
        assertEq(ed.metadataURI, "ipfs://test-piece");
        assertEq(uint256(ed.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(ed.priceIncreaseRate, 0);

        vm.stopPrank();
    }

    function test_GetAllEditionIds() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition("Piece 1", _eth(0.1 ether), 0, "ipfs://1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        ERC1155Instance(payable(instance)).addEdition("Piece 2", _eth(0.2 ether), 100, "ipfs://2", ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0);
        ERC1155Instance(payable(instance)).addEdition("Piece 3", _eth(0.3 ether), 50, "ipfs://3", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 100, 0);

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        uint256[] memory editionIds = instanceContract.getAllEditionIds();
        assertEq(editionIds.length, 3);
        assertEq(editionIds[0], 1);
        assertEq(editionIds[1], 2);
        assertEq(editionIds[2], 3);

        assertEq(instanceContract.getEditionCount(), 3);

        vm.stopPrank();
    }

    function test_GetEditionsBatch() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition("Piece 1", _eth(0.1 ether), 0, "ipfs://1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        ERC1155Instance(payable(instance)).addEdition("Piece 2", _eth(0.2 ether), 100, "ipfs://2", ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0);

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        ERC1155Instance.Edition memory ed1 = instanceContract.getEdition(1);
        ERC1155Instance.Edition memory ed2 = instanceContract.getEdition(2);

        assertEq(ed1.id, 1);
        assertEq(ed1.pieceTitle, "Piece 1");
        assertEq(ed1.prices[0].price, 0.1 ether);
        assertEq(ed2.id, 2);
        assertEq(ed2.pieceTitle, "Piece 2");
        assertEq(ed2.prices[0].price, 0.2 ether);

        vm.stopPrank();
    }

    function test_GetInstanceMetadata() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        assertEq(instanceContract.name(), "Test Collection");
        assertEq(instanceContract.creator(), creator);
        assertEq(instanceContract.factory(), address(factory));
        assertEq(address(instanceContract.vault()), address(vault));
        assertEq(instanceContract.getEditionCount(), 0);
        assertEq(instanceContract.totalProceeds(address(0)), 0);

        vm.stopPrank();
    }

    function test_GetPricingInfo() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            100,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        ERC1155Instance.Edition memory ed = instanceContract.getEdition(1);
        uint256 currentPrice = instanceContract.getCurrentPrice(1, address(0));
        uint256 available = ed.supply > ed.minted ? ed.supply - ed.minted : 0;

        assertEq(ed.prices[0].price, 0.1 ether);
        assertEq(currentPrice, 0.1 ether);
        assertEq(uint256(ed.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(ed.supply, 100);
        assertEq(ed.minted, 0);
        assertEq(available, 100);

        vm.stopPrank();
    }

    function test_GetMintStats() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            10,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );
        vm.stopPrank();

        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        instanceContract.mint{value: 0.5 ether}(1, 5, bytes32(0), "", address(0), 0);
        vm.stopPrank();

        ERC1155Instance.Edition memory ed = instanceContract.getEdition(1);
        uint256 available = ed.supply > ed.minted ? ed.supply - ed.minted : 0;
        bool isSoldOut = ed.minted >= ed.supply;

        assertEq(ed.minted, 5);
        assertEq(ed.supply, 10);
        assertEq(available, 5);
        assertFalse(isSoldOut);
    }

    // ========================
    // Protocol Treasury Tests
    // ========================

    function test_InstanceSnapshotsTreasuryAndFees() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Treasury Test", creator, address(vault))
        );
        vm.stopPrank();

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));
        assertEq(instanceContract.protocolTreasury(), TREASURY);
        assertEq(instanceContract.protocolFeeBps(), 100);
        assertEq(instanceContract.alignmentBps(), ALIGNMENT_BPS);
        assertEq(registry.vaultOf(instance), address(vault));
        assertEq(registry.factoryOf(instance), address(factory));
    }

    // ========================

    function test_EditionExists() public {
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Test Collection", creator, address(vault))
        );
        ERC1155Instance(payable(instance)).addEdition(
            "Piece 1",
            _eth(0.1 ether),
            100,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0 // openTime
        );

        ERC1155Instance instanceContract = ERC1155Instance(payable(instance));

        assertTrue(1 < instanceContract.nextEditionId());    // edition 1 was added
        assertFalse(999 < instanceContract.nextEditionId()); // edition 999 was never added

        vm.stopPrank();
    }

    function test_createInstance_standardTier() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);

        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Standard Collection", creator, address(vault))
        );

        assertTrue(instance != address(0), "Should create instance");

        vm.stopPrank();
    }

    // ── ERC1155Instance gating and openTime ───────────────────────────────────

    function _deployGatedInstance(address gatingModuleAddr) internal returns (address instance) {
        // Register the gating module in the registry before creating instance
        if (gatingModuleAddr != address(0)) {
            vm.prank(registryOwner);
            registry.setComponent(gatingModuleAddr, true);
        }

        vm.deal(artist, 1 ether);
        vm.prank(artist);
        instance = factory.createInstance{value: 0}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "GatedProject",
                metadataURI: "ipfs://Qm",
                creator: artist,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: gatingModuleAddr,
                freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
                acceptedTokens: _ethOnly()
            })
        );
    }

    function test_instance_openTime_blocksMintBeforeOpen() public {
        address instance = _deployGatedInstance(address(0));
        ERC1155Instance inst = ERC1155Instance(payable(instance));

        // Add edition with openTime 1 hour from now
        uint256 openTime = block.timestamp + 1 hours;
        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, openTime);
        uint256 editionId = inst.nextEditionId() - 1;

        // Attempt to mint before openTime
        vm.expectRevert(EditionNotOpen.selector);
        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
    }

    function test_instance_openTime_allowsMintAfterOpen() public {
        address instance = _deployGatedInstance(address(0));
        ERC1155Instance inst = ERC1155Instance(payable(instance));

        uint256 openTime = block.timestamp + 1 hours;
        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, openTime);
        uint256 editionId = inst.nextEditionId() - 1;

        // Warp past openTime
        vm.warp(block.timestamp + 2 hours);

        // Mint should succeed
        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    function test_instance_openTime_zeroMeansAlwaysOpen() public {
        address instance = _deployGatedInstance(address(0));
        ERC1155Instance inst = ERC1155Instance(payable(instance));

        // openTime = 0 → no time gate
        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        uint256 editionId = inst.nextEditionId() - 1;

        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    function test_instance_gating_blocksMintOnFailedCheck() public {
        MockRejectGatingModule mockModule = new MockRejectGatingModule();

        address instance = _deployGatedInstance(address(mockModule));
        ERC1155Instance inst = ERC1155Instance(payable(instance));

        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        uint256 editionId = inst.nextEditionId() - 1;

        vm.expectRevert(GatingCheckFailed.selector);
        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
    }

    function test_instance_gating_allowsMintOnPassingCheck() public {
        MockAllowGatingModule mockModule = new MockAllowGatingModule();

        address instance = _deployGatedInstance(address(mockModule));
        ERC1155Instance inst = ERC1155Instance(payable(instance));

        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        uint256 editionId = inst.nextEditionId() - 1;

        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    // ── gatingScope ───────────────────────────────────────────────────────────

    function _deployScoped(address gatingModuleAddr, GatingScope scope) internal returns (ERC1155Instance inst) {
        vm.prank(registryOwner);
        registry.setComponent(gatingModuleAddr, true);
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        inst = ERC1155Instance(payable(factory.createInstance{value: 0}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "ScopedProject",
                metadataURI: "ipfs://Qm",
                creator: artist,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: gatingModuleAddr,
                freeMint: FreeMintParams({allocation: 5, scope: scope}),
                acceptedTokens: _ethOnly()
            })
        )));
    }

    function _scopedEdition(ERC1155Instance inst) internal returns (uint256) {
        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        return inst.nextEditionId() - 1;
    }

    function test_gatingScope_freeMintOnly_paidMintIsOpenFreeMintIsGated() public {
        ERC1155Instance inst = _deployScoped(address(new MockRejectGatingModule()), GatingScope.FREE_MINT_ONLY);
        uint256 editionId = _scopedEdition(inst);

        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
        assertEq(inst.balanceOf(address(this), editionId), 1);

        vm.expectRevert(GatingCheckFailed.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_gatingScope_paidOnly_paidMintIsGatedFreeMintIsOpen() public {
        ERC1155Instance inst = _deployScoped(address(new MockRejectGatingModule()), GatingScope.PAID_ONLY);
        uint256 editionId = _scopedEdition(inst);

        vm.expectRevert(GatingCheckFailed.selector);
        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);

        inst.claimFreeMint(editionId, "");
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    function test_gatingScope_both_gatesEach() public {
        ERC1155Instance inst = _deployScoped(address(new MockRejectGatingModule()), GatingScope.BOTH);
        uint256 editionId = _scopedEdition(inst);

        vm.expectRevert(GatingCheckFailed.selector);
        inst.mint{value: 0.01 ether}(editionId, 1, bytes32(0), "", address(0), 0);
        vm.expectRevert(GatingCheckFailed.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_claimFreeMint_callerCannotChooseOpenTimeToSkipTierLock() public {
        PasswordTierGatingModule module = new PasswordTierGatingModule(address(registry));
        ERC1155Instance inst = _deployScoped(address(module), GatingScope.BOTH);
        uint256 openAt = block.timestamp + 1 hours;
        vm.prank(artist);
        inst.addEdition("Art 1", _eth(0.01 ether), 0, "ipfs://art1", ERC1155Instance.PricingModel.UNLIMITED, 0, openAt);
        uint256 editionId = inst.nextEditionId() - 1;

        bytes32 hash = keccak256("tier1");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = hash;
        uint256[] memory unlocks = new uint256[](1);
        unlocks[0] = 1 days;
        vm.prank(address(factory));
        module.configureFor(address(inst), PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.TIME_BASED,
            passwordHashes: hashes,
            volumeCaps: new uint256[](0),
            tierUnlockTimes: unlocks
        }));
        vm.warp(openAt);

        // Encoding openTime = 0 used to put the unlock far in the past.
        vm.expectRevert(PasswordTierGatingModule.TierTimeLocked.selector);
        inst.claimFreeMint(editionId, abi.encode(hash, uint256(0)));
        vm.expectRevert(PasswordTierGatingModule.TierTimeLocked.selector);
        inst.claimFreeMint(editionId, abi.encode(hash));

        vm.warp(openAt + 1 days);
        inst.claimFreeMint(editionId, abi.encode(hash));
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    function test_claimFreeMint_emptyDataIsOpenTierLikeMint() public {
        PasswordTierGatingModule module = new PasswordTierGatingModule(address(registry));
        ERC1155Instance inst = _deployScoped(address(module), GatingScope.BOTH);
        uint256 editionId = _scopedEdition(inst);
        inst.claimFreeMint(editionId, "");
        assertEq(inst.balanceOf(address(this), editionId), 1);
    }

    // ── ERC1155Factory gating wiring ──────────────────────────────────────────

    function test_factory_createInstanceWithGating_revertsOnUnapprovedModule() public {
        address unapprovedModule = address(0xBAD);

        vm.deal(artist, 1 ether);
        vm.prank(artist);
        vm.expectRevert(ERC1155Factory.UnapprovedComponent.selector);
        factory.createInstance{value: 0}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "TestProject",
                metadataURI: "ipfs://Qm",
                creator: artist,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: unapprovedModule,
                freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
                acceptedTokens: _ethOnly()
            })
        );
    }

    function test_factory_createInstanceWithGating_succeedsWithApprovedModule() public {
        address mockModule = address(new MockAllowGatingModule());

        vm.prank(registryOwner);
        registry.setComponent(mockModule, true);

        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "GatedProject",
                metadataURI: "ipfs://Qm",
                creator: artist,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: mockModule,
                freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
                acceptedTokens: _ethOnly()
            })
        );

        assertTrue(instance != address(0));
        assertEq(address(ERC1155Instance(payable(instance)).gatingModule()), mockModule);
    }

    function test_factory_createInstance_noGating() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("OpenProject", artist, address(vault))
        );
        assertTrue(instance != address(0));
        assertEq(address(ERC1155Instance(payable(instance)).gatingModule()), address(0));
    }

    function test_factory_addEdition_withOpenTime() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Project", artist, address(vault))
        );

        uint256 futureOpen = block.timestamp + 1 days;
        vm.prank(artist);
        ERC1155Instance(payable(instance)).addEdition(
            "Art 1",
            _eth(0.01 ether),
            0,
            "ipfs://art1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            futureOpen
        );

        // Verify openTime stored on edition
        ERC1155Instance.Edition memory ed = ERC1155Instance(payable(instance)).getEdition(1);
        assertEq(ed.openTime, futureOpen);
    }

    function test_addEdition_limitedDynamic_revertsWithoutModule() public {
        // Deploy a fresh factory with no dynamic pricing module set
        ERC1155Factory bareFactory = new ERC1155Factory(IMiyaRegistry(address(registry)), address(0xBEEF));
        vm.prank(registryOwner);
        registry.setFactory(address(bareFactory), true);
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        address instance = bareFactory.createInstance{value: 0}(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "Test",
                metadataURI: "ipfs://test",
                creator: creator,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                styleUri: "",
                gatingModule: address(0),
                freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH}),
                acceptedTokens: _ethOnly()
            })
        );

        vm.expectRevert(NoDynamicPricingModule.selector);
        ERC1155Instance(payable(instance)).addEdition(
            "Dynamic Piece", _eth(0.1 ether), 100, "ipfs://piece",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 100, 0
        );
        vm.stopPrank();
    }

    function test_setDynamicPricingModule_revertsUnapproved() public {
        address unapproved = address(0xDEAD);
        vm.startPrank(owner);
        vm.expectRevert(ERC1155Factory.UnapprovedComponent.selector);
        factory.setDynamicPricingModule(unapproved);
        vm.stopPrank();
    }

    function test_setDynamicPricingModule_acceptsZeroAddress() public {
        vm.startPrank(owner);
        factory.setDynamicPricingModule(address(0));
        assertEq(factory.dynamicPricingModule(), address(0));
        vm.stopPrank();
    }

    // ── parked vault cuts ─────────────────────────────────────────────────────

    /// @dev Sells 0.005 ETH and withdraws it: a 19% cut of 0.00095 ETH, under the vault's 0.001 minimum, so it parks.
    ///      With nothing left to sell, no later withdraw would carry it.
    function _instanceWithDustParked() internal returns (ERC1155Instance inst) {
        vm.startPrank(creator);
        inst = ERC1155Instance(payable(factory.createInstance(_nextSalt(), _params("Dust", creator, address(vault)))));
        inst.addEdition("P", _eth(0.005 ether), 1, "ipfs://p", ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0);
        vm.stopPrank();
        vm.deal(minter1, 1 ether);
        vm.prank(minter1);
        inst.mint{value: 0.005 ether}(1, 1, bytes32(0), "", address(0), 0);
        inst.distribute(address(0));
        assertEq(inst.pendingVaultCut(address(0)), 0.00095 ether);
        assertEq(address(inst).balance, 0.00095 ether + inst.ownerBalance(address(0)));
    }

    function test_RetryVaultContribution_DustCanBeToppedUpToReachTheVault() public {
        ERC1155Instance inst = _instanceWithDustParked();

        vm.expectRevert(bytes("below minimum"));
        inst.flushPendingVaultCut(address(0), 0);

        // not enough: reverts, so the helper keeps its ETH and the cut stays parked
        vm.deal(minter2, 1 ether);
        vm.prank(minter2);
        vm.expectRevert(bytes("below minimum"));
        inst.flushPendingVaultCut{value: 0.00004 ether}(address(0), 0.00004 ether);
        assertEq(minter2.balance, 1 ether);
        assertEq(inst.pendingVaultCut(address(0)), 0.00095 ether);

        uint256 vaultBefore = address(vault).balance;
        vm.expectEmit(address(inst));
        emit PaymentLib.VaultContributionRetried(address(0), 0.001 ether);
        vm.prank(minter2);
        inst.flushPendingVaultCut{value: 0.00005 ether}(address(0), 0.00005 ether);
        assertEq(inst.pendingVaultCut(address(0)), 0);
        assertEq(address(inst).balance, inst.ownerBalance(address(0)));
        assertEq(address(vault).balance - vaultBefore, 0.001 ether);
        // credited to the collection, not to whoever topped it up
        assertEq(vault.credited(address(inst), address(0)), 0.001 ether);
        assertEq(vault.credited(minter2, address(0)), 0);
    }

    function test_RetryVaultContribution_ToppingUpNothingParkedReverts() public {
        vm.prank(creator);
        ERC1155Instance inst =
            ERC1155Instance(payable(factory.createInstance(_nextSalt(), _params("None", creator, address(vault)))));
        vm.deal(minter1, 1 ether);
        vm.prank(minter1);
        vm.expectRevert(PaymentLib.NothingParked.selector);
        inst.flushPendingVaultCut{value: 0.01 ether}(address(0), 0.01 ether);
    }
}
