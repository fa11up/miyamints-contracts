// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {ERC1155Factory} from "../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance, InsufficientBalance} from "../../src/factories/erc1155/ERC1155Instance.sol";
import {ERC721AuctionFactory} from "../../src/factories/erc721/ERC721AuctionFactory.sol";
import {ERC721AuctionInstance} from "../../src/factories/erc721/ERC721AuctionInstance.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {FreeMintParams} from "../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../src/gating/IGatingModule.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";

/// @notice End-to-end launch flow against a real MiyaRegistry: DAO adds a target, the vault factory deploys and
///         registers a vault, artists launch collections choosing an alignment share, and revenue splits
///         1% protocol → treasury, alignment share → vault, remainder → artist, frozen at launch.
contract MiyaLaunchTest is Test {
    MiyaRegistry registry;
    UniAlignmentVaultFactory vaultFactory;
    ERC1155Factory factory1155;
    ERC721AuctionFactory factory721;
    MockEXECToken token;
    address vault;

    address dao = makeAddr("dao");
    address treasury = makeAddr("treasury");
    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");
    address weth = makeAddr("weth");

    uint16 constant PROTOCOL_BPS = 100;
    uint16 constant MIN_ALIGNMENT_BPS = 1000;
    uint256 constant TARGET_ID = 0;

    uint256 internal _salt;

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        token = new MockEXECToken(1_000_000e18);

        registry = new MiyaRegistry(dao, treasury, PROTOCOL_BPS, MIN_ALIGNMENT_BPS);

        vaultFactory = new UniAlignmentVaultFactory(
            weth,
            makeAddr("poolManager"),
            address(new MockZRouter()),
            3000,
            60,
            IVaultPriceValidator(address(new MockVaultPriceValidator())),
            IMiyaRegistry(address(registry))
        );
        factory1155 = new ERC1155Factory(IMiyaRegistry(address(registry)), weth);
        factory721 = new ERC721AuctionFactory(IMiyaRegistry(address(registry)), weth);

        vm.startPrank(dao);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        assertEq(registry.addTarget("Remilia", tokens), TARGET_ID);
        registry.setVaultFactory(address(vaultFactory), true);
        registry.setFactory(address(factory1155), true);
        registry.setFactory(address(factory721), true);
        vm.stopPrank();

        vault = vaultFactory.deployVault(_vaultSalt(), address(token), TARGET_ID, IVaultPriceValidator(address(0)));

        vm.deal(artist, 100 ether);
        vm.deal(buyer, 100_000 ether);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _vaultSalt() internal returns (bytes32) {
        _salt++;
        return bytes32(abi.encodePacked(address(vaultFactory), uint8(0x00), bytes11(uint88(_salt))));
    }

    function _salt1155() internal returns (bytes32) {
        _salt++;
        return bytes32(abi.encodePacked(address(factory1155), uint8(0x00), bytes11(uint88(_salt))));
    }

    function _salt721() internal returns (bytes32) {
        _salt++;
        return bytes32(abi.encodePacked(address(factory721), uint8(0x00), bytes11(uint88(_salt))));
    }

    function _params1155(address v, uint16 alignmentBps) internal view returns (ERC1155Factory.CreateParams memory) {
        return ERC1155Factory.CreateParams({
            name: "Editions",
            metadataURI: "ipfs://meta",
            creator: artist,
            vault: v,
            alignmentBps: alignmentBps,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        });
    }

    function _params721(address v, uint16 alignmentBps) internal view returns (ERC721AuctionFactory.CreateParams memory) {
        return ERC721AuctionFactory.CreateParams({
            name: "OneOfOnes",
            metadataURI: "ipfs://meta",
            creator: artist,
            vault: v,
            alignmentBps: alignmentBps,
            symbol: "ONE",
            lines: 1,
            baseDuration: 1 hours,
            timeBuffer: 5 minutes,
            bidIncrement: 0.01 ether
        });
    }

    function _launch1155(uint16 alignmentBps) internal returns (ERC1155Instance inst) {
        vm.prank(artist);
        inst = ERC1155Instance(payable(factory1155.createInstance(_salt1155(), _params1155(vault, alignmentBps))));
        vm.prank(artist);
        inst.addEdition("Piece", 1 ether, 0, "ipfs://piece", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
    }

    function _launch721(uint16 alignmentBps) internal returns (ERC721AuctionInstance inst) {
        vm.prank(artist);
        inst = ERC721AuctionInstance(payable(factory721.createInstance(_salt721(), _params721(vault, alignmentBps))));
    }

    /// @dev Mint `price` worth on edition 1 and withdraw it all; returns (treasury, vault, artist) deltas.
    function _sell1155(ERC1155Instance inst, uint256 amount, address treasuryAddr)
        internal
        returns (uint256 toTreasury, uint256 toVault, uint256 toArtist)
    {
        vm.prank(buyer);
        inst.mint{value: amount * 1 ether}(1, amount, bytes32(0), "", 0);

        uint256 t0 = treasuryAddr.balance;
        uint256 v0 = vault.balance;
        uint256 a0 = artist.balance;
        vm.prank(artist);
        inst.withdraw(amount * 1 ether);
        return (treasuryAddr.balance - t0, vault.balance - v0, artist.balance - a0);
    }

    /// @dev Queue a piece, win it with `bid`, settle; returns (treasury, vault, artist-net-of-deposit) deltas.
    function _sell721(ERC721AuctionInstance inst, uint256 bid, address treasuryAddr)
        internal
        returns (uint256 toTreasury, uint256 toVault, uint256 toArtist)
    {
        uint256 deposit = 0.01 ether;
        vm.prank(artist);
        inst.queuePiece{value: deposit}("ipfs://piece");
        uint24 tokenId = inst.nextTokenId() - 1;
        vm.prank(buyer);
        inst.createBid{value: bid}(tokenId, "");
        vm.warp(inst.getAuction(tokenId).endTime);

        uint256 t0 = treasuryAddr.balance;
        uint256 v0 = vault.balance;
        uint256 a0 = artist.balance;
        inst.settleAuction(tokenId);
        return (treasuryAddr.balance - t0, vault.balance - v0, artist.balance - a0 - deposit);
    }

    // ── wiring ──────────────────────────────────────────────────────────────

    function test_vaultFactoryRegistersVault() public view {
        assertTrue(registry.isVault(vault));
        assertEq(UniAlignmentVault(payable(vault)).alignmentToken(), address(token));
        assertEq(address(UniAlignmentVault(payable(vault)).registry()), address(registry));
    }

    function test_deployVault_revertsForDeactivatedTarget() public {
        vm.prank(dao);
        registry.setTargetActive(TARGET_ID, false);
        bytes32 salt = _vaultSalt();
        vm.expectRevert(UniAlignmentVault.TargetNotActive.selector);
        vaultFactory.deployVault(salt, address(token), TARGET_ID, IVaultPriceValidator(address(0)));
    }

    function test_launch_registersInstanceAndSnapshotsTerms() public {
        ERC1155Instance e = _launch1155(2500);
        ERC721AuctionInstance a = _launch721(1000);

        assertEq(registry.vaultOf(address(e)), vault);
        assertEq(registry.factoryOf(address(e)), address(factory1155));
        assertEq(registry.vaultOf(address(a)), vault);
        assertEq(registry.factoryOf(address(a)), address(factory721));
        assertEq(registry.instanceCount(), 2);

        assertEq(e.protocolTreasury(), treasury);
        assertEq(e.protocolFeeBps(), PROTOCOL_BPS);
        assertEq(e.alignmentBps(), 2500);
        assertEq(a.protocolTreasury(), treasury);
        assertEq(a.protocolFeeBps(), PROTOCOL_BPS);
        assertEq(a.alignmentBps(), 1000);
    }

    function test_launch_creationFeeGoesToRegistryTreasury() public {
        vm.prank(artist);
        factory1155.createInstance{value: 0.05 ether}(_salt1155(), _params1155(vault, 1000));
        vm.prank(artist);
        factory721.createInstance{value: 0.02 ether}(_salt721(), _params721(vault, 1000));
        assertEq(treasury.balance, 0.07 ether);

        // a treasury change applies to subsequent launches
        address t2 = makeAddr("t2");
        vm.prank(dao);
        registry.setTreasury(t2);
        vm.prank(artist);
        factory1155.createInstance{value: 0.01 ether}(_salt1155(), _params1155(vault, 1000));
        assertEq(t2.balance, 0.01 ether);
        assertEq(address(factory1155).balance, 0);
        assertEq(address(factory721).balance, 0);
    }

    function test_launch_revertsBelowMinimumAlignment() public {
        bytes32 s1 = _salt1155();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        factory1155.createInstance(s1, _params1155(vault, 999));

        bytes32 s2 = _salt721();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        factory721.createInstance(s2, _params721(vault, 0));
    }

    function test_launch_revertsWhenProtocolPlusAlignmentExceedsBps() public {
        bytes32 s1 = _salt1155();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        factory1155.createInstance(s1, _params1155(vault, 9901));

        bytes32 s2 = _salt721();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        factory721.createInstance(s2, _params721(vault, 9901));

        // exactly 100%: 1% protocol + 99% vault, artist gets nothing
        vm.prank(artist);
        factory1155.createInstance(_salt1155(), _params1155(vault, 9900));
    }

    function test_launch_revertsForUnregisteredVault() public {
        // A contract that is not a registered vault (e.g. a creator-controlled sink)
        address fakeVault = address(new MockZRouter());

        bytes32 s1 = _salt1155();
        vm.prank(artist);
        vm.expectRevert(ERC1155Factory.InvalidVault.selector);
        factory1155.createInstance(s1, _params1155(fakeVault, 1000));

        bytes32 s2 = _salt721();
        vm.prank(artist);
        vm.expectRevert(ERC721AuctionFactory.InvalidVault.selector);
        factory721.createInstance(s2, _params721(fakeVault, 1000));

        // an EOA is rejected too
        bytes32 s3 = _salt1155();
        vm.prank(artist);
        vm.expectRevert(ERC1155Factory.InvalidVault.selector);
        factory1155.createInstance(s3, _params1155(buyer, 1000));
    }

    function test_launch_revertsForUnregisteredFactory() public {
        vm.prank(dao);
        registry.setFactory(address(factory1155), false);
        bytes32 s1 = _salt1155();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.NotFactory.selector);
        factory1155.createInstance(s1, _params1155(vault, 1000));

        vm.prank(dao);
        registry.setFactory(address(factory721), false);
        bytes32 s2 = _salt721();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.NotFactory.selector);
        factory721.createInstance(s2, _params721(vault, 1000));
    }

    function test_launch_revertsWhenCallerIsNotCreator() public {
        bytes32 s1 = _salt1155();
        vm.prank(buyer);
        vm.expectRevert(ERC1155Factory.NotCreator.selector);
        factory1155.createInstance(s1, _params1155(vault, 1000));

        bytes32 s2 = _salt721();
        vm.prank(buyer);
        vm.expectRevert(ERC721AuctionFactory.NotCreator.selector);
        factory721.createInstance(s2, _params721(vault, 1000));
    }

    // ── fee splits: ERC1155 ─────────────────────────────────────────────────

    function test_1155_split_minimumAlignment() public {
        ERC1155Instance inst = _launch1155(1000);
        (uint256 t, uint256 v, uint256 a) = _sell1155(inst, 10, treasury);
        assertEq(t, 0.1 ether, "1% to treasury");
        assertEq(v, 1 ether, "10% to vault");
        assertEq(a, 8.9 ether, "89% to artist");
        assertEq(UniAlignmentVault(payable(vault)).pendingETH(address(inst)), 1 ether, "instance is benefactor");
    }

    function testFuzz_1155_split(uint16 alignmentBps, uint8 amountRaw) public {
        alignmentBps = uint16(bound(alignmentBps, MIN_ALIGNMENT_BPS, 10_000 - PROTOCOL_BPS));
        uint256 amount = bound(amountRaw, 1, 50);
        ERC1155Instance inst = _launch1155(alignmentBps);
        (uint256 t, uint256 v, uint256 a) = _sell1155(inst, amount, treasury);
        uint256 gross = amount * 1 ether;
        assertEq(t, gross * PROTOCOL_BPS / 10_000, "protocol cut");
        assertEq(v, gross * alignmentBps / 10_000, "vault cut");
        assertEq(a, gross - t - v, "artist remainder");
    }

    function test_1155_registryChangesDoNotAffectExistingCollection() public {
        ERC1155Instance inst = _launch1155(2000);

        address t2 = makeAddr("t2");
        vm.startPrank(dao);
        registry.setFees(500, 3000);
        registry.setTreasury(t2);
        vm.stopPrank();

        // existing collection keeps 1% → old treasury, 20% → vault, 79% → artist
        assertEq(inst.protocolFeeBps(), PROTOCOL_BPS);
        assertEq(inst.alignmentBps(), 2000);
        (uint256 t, uint256 v, uint256 a) = _sell1155(inst, 10, treasury);
        assertEq(t, 0.1 ether);
        assertEq(v, 2 ether);
        assertEq(a, 7.9 ether);
        assertEq(t2.balance, 0, "new treasury gets nothing from old collection");

        // its old alignment share is no longer allowed for new launches
        bytes32 s = _salt1155();
        vm.prank(artist);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        factory1155.createInstance(s, _params1155(vault, 2000));

        // a new collection snapshots the new terms
        ERC1155Instance inst2 = _launch1155(3000);
        assertEq(inst2.protocolTreasury(), t2);
        (t, v, a) = _sell1155(inst2, 10, t2);
        assertEq(t, 0.5 ether);
        assertEq(v, 3 ether);
        assertEq(a, 6.5 ether);
    }

    // ── fee splits: ERC721 auctions ─────────────────────────────────────────

    function test_721_split_minimumAlignment() public {
        ERC721AuctionInstance inst = _launch721(1000);
        (uint256 t, uint256 v, uint256 a) = _sell721(inst, 10 ether, treasury);
        assertEq(t, 0.1 ether, "1% to treasury");
        assertEq(v, 1 ether, "10% to vault");
        assertEq(a, 8.9 ether, "89% to artist");
    }

    function testFuzz_721_split(uint16 alignmentBps, uint256 bid) public {
        alignmentBps = uint16(bound(alignmentBps, MIN_ALIGNMENT_BPS, 10_000 - PROTOCOL_BPS));
        bid = bound(bid, 0.01 ether, 10_000 ether);
        ERC721AuctionInstance inst = _launch721(alignmentBps);
        (uint256 t, uint256 v, uint256 a) = _sell721(inst, bid, treasury);
        assertEq(t, bid * PROTOCOL_BPS / 10_000, "protocol cut");
        assertEq(v, bid * alignmentBps / 10_000, "vault cut");
        assertEq(a, bid - t - v, "artist remainder");
    }

    function test_721_registryChangesDoNotAffectExistingCollection() public {
        ERC721AuctionInstance inst = _launch721(1500);

        address t2 = makeAddr("t2");
        vm.startPrank(dao);
        registry.setFees(500, 3000);
        registry.setTreasury(t2);
        vm.stopPrank();

        (uint256 t, uint256 v, uint256 a) = _sell721(inst, 10 ether, treasury);
        assertEq(t, 0.1 ether);
        assertEq(v, 1.5 ether);
        assertEq(a, 8.4 ether);
        assertEq(t2.balance, 0);

        ERC721AuctionInstance inst2 = _launch721(3000);
        assertEq(inst2.protocolTreasury(), t2);
        assertEq(inst2.protocolFeeBps(), 500);
        (t, v, a) = _sell721(inst2, 10 ether, t2);
        assertEq(t, 0.5 ether);
        assertEq(v, 3 ether);
        assertEq(a, 6.5 ether);
    }

    function test_721_unsoldDepositGoesToSnapshotTreasury() public {
        ERC721AuctionInstance inst = _launch721(1000);
        vm.prank(dao);
        registry.setTreasury(makeAddr("t2"));

        vm.prank(artist);
        inst.queuePiece{value: 0.2 ether}("ipfs://unsold");
        vm.warp(inst.getAuction(1).endTime);
        uint256 t0 = treasury.balance;
        vm.prank(artist);
        inst.reclaimUnsold(1);
        assertEq(treasury.balance - t0, 0.2 ether);
    }
}

/// @notice ERC1155Instance must be able to receive vault fee payouts (UniAlignmentVault.claimFees pays the
///         benefactor with a plain call) and forward them to the owner without disturbing mint accounting.
contract ERC1155VaultFeeClaimTest is Test {
    MiyaRegistry registry;
    ERC1155Factory factory;
    TestableUniAlignmentVault vault;
    MockEXECToken token;

    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        token = new MockEXECToken(1_000_000e18);
        registry = new MiyaRegistry(address(this), treasury, 100, 1000);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        registry.addTarget("Remilia", tokens);

        MockZRouter zRouter = new MockZRouter();
        vm.deal(address(zRouter), 100 ether);
        token.transfer(address(zRouter), 100_000e18);

        // Testable vault (mock LP) owned by this test, registered with this test acting as the vault factory.
        vault = TestableUniAlignmentVault(payable(LibClone.clone(address(new TestableUniAlignmentVault()))));
        vault.initialize(
            address(this),
            makeAddr("weth"),
            makeAddr("poolManager"),
            address(token),
            address(zRouter),
            3000,
            60,
            IVaultPriceValidator(address(new MockVaultPriceValidator())),
            IMiyaRegistry(address(registry)),
            0
        );
        vault.setV4PoolKey(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(token)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            })
        );
        registry.setVaultFactory(address(this), true);
        registry.registerVault(address(vault));

        factory = new ERC1155Factory(IMiyaRegistry(address(registry)), makeAddr("weth"));
        registry.setFactory(address(factory), true);

        vm.deal(buyer, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _launchAndSell() internal returns (ERC1155Instance inst) {
        vm.prank(artist);
        inst = ERC1155Instance(
            payable(
                factory.createInstance(
                    bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(1)))),
                    ERC1155Factory.CreateParams({
                        name: "Editions",
                        metadataURI: "ipfs://meta",
                        creator: artist,
                        vault: address(vault),
                        alignmentBps: 2000,
                        styleUri: "",
                        gatingModule: address(0),
                        freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
                    })
                )
            )
        );
        vm.prank(artist);
        inst.addEdition("Piece", 1 ether, 0, "ipfs://piece", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.prank(buyer);
        inst.mint{value: 2 ether}(1, 2, bytes32(0), "gm", 0);

        // withdraw half: 0.2 ETH (20%) becomes the instance's vault contribution
        vm.prank(artist);
        inst.withdraw(1 ether);

        // contribution converts into benefactor shares for the instance, then the vault earns fees
        vm.prank(keeper);
        vault.convertAndAddLiquidity(1);
        assertGt(vault.benefactorShares(address(inst)), 0);
        vault.depositFees{value: 3 ether}();
    }

    function test_claimVaultFees_forwardsVaultPayoutToOwner() public {
        ERC1155Instance inst = _launchAndSell();

        uint256 artistBefore = artist.balance;
        uint256 instBefore = address(inst).balance;
        vm.prank(artist);
        uint256 claimed = inst.claimVaultFees();

        assertGt(claimed, 0);
        assertApproxEqAbs(claimed, 3 ether, 1, "sole benefactor gets all fees");
        assertEq(artist.balance - artistBefore, claimed, "owner receives claimed fees");
        assertEq(address(inst).balance, instBefore, "nothing stranded in the instance");

        // mint accounting is untouched: the remaining 1 ETH of proceeds is still exactly withdrawable
        assertEq(inst.totalProceeds() - inst.totalWithdrawn(), 1 ether);
        assertEq(inst.pendingVaultCut(), 0);
        vm.prank(artist);
        vm.expectRevert(InsufficientBalance.selector);
        inst.withdraw(1 ether + 1);
        vm.prank(artist);
        inst.withdraw(1 ether);
    }

    function test_claimAllFees_forwardsVaultPayoutToOwner() public {
        ERC1155Instance inst = _launchAndSell();
        uint256 artistBefore = artist.balance;
        vm.prank(artist);
        inst.claimAllFees();
        assertApproxEqAbs(artist.balance - artistBefore, 3 ether, 1);
    }

    function test_receivedEthIsNotWithdrawableAsProceeds() public {
        ERC1155Instance inst = _launchAndSell();
        // plain ETH sent to the instance (e.g. a vault payout) never counts as mint proceeds
        (bool ok,) = address(inst).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(inst.totalProceeds() - inst.totalWithdrawn(), 1 ether);
        assertEq(inst.pendingVaultCut(), 0);
        vm.prank(artist);
        vm.expectRevert(InsufficientBalance.selector);
        inst.withdraw(2 ether);
    }

    function test_claimVaultFees_onlyOwner() public {
        ERC1155Instance inst = _launchAndSell();
        vm.prank(buyer);
        vm.expectRevert();
        inst.claimVaultFees();
    }

    receive() external payable {}
}
