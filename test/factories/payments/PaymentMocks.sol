// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ClaimMode } from "../../../src/interfaces/IAlignmentVault.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { TokenPrice } from "../../../src/factories/interfaces/TokenPrice.sol";
import { ICreateX, CREATEX } from "../../../src/shared/CreateXConstants.sol";
import { CREATEX_BYTECODE } from "createx-forge/script/CreateX.d.sol";

/// @dev Plain ERC-20 with configurable decimals (USDC 6, cbBTC/WBTC 8, IMD/INFER/imdUSD 18).
/// @dev INFER and IMD at their mainnet addresses (the vault's fee tokens on mainnet).
address constant MOCK_INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
address constant MOCK_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev USDC / WBTC style: an admin blocklist; any transfer to or from a blocklisted address reverts.
contract BlocklistToken is MockToken {
    mapping(address => bool) public blocked;

    constructor(string memory n, string memory s, uint8 d) MockToken(n, s, d) { }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "blocklisted");
        super._move(from, to, amount);
    }
}

/// @dev Burns 1% of every transfer: the collections' balance-delta check must refuse it.
contract FeeOnTransferToken is MockToken {
    constructor() MockToken("Fee", "FEE", 18) { }

    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @dev Stand-in for MiyaRegistry with the calls collections and factories make.
contract MockPaymentRegistry {
    address public treasury;
    address public conversionKeeper;
    uint16 public protocolFeeBps = 100;
    uint16 public minAlignmentBps = 1000;
    mapping(address => bool) public isVault;
    mapping(address => address) public vaultOf;
    mapping(address => bool) internal _paymentToken;
    mapping(address => bool) public isApprovedComponent;

    error InvalidAlignment();

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function setVault(address v, bool ok) external {
        isVault[v] = ok;
    }

    function setPaymentToken(address token, bool ok) external {
        _paymentToken[token] = ok;
    }

    function setComponent(address c, bool ok) external {
        isApprovedComponent[c] = ok;
    }

    function isPaymentToken(address token) external view returns (bool) {
        return token == address(0) || _paymentToken[token];
    }

    function checkAlignmentBps(uint16 a) external view {
        if (a < minAlignmentBps || uint256(a) + protocolFeeBps > 10_000) revert InvalidAlignment();
    }

    function registerInstance(address instance, address vault, address) external {
        vaultOf[instance] = vault;
    }
}

/// @dev Vault v2 stand-in: books contributions per token (pulling ERC-20s with transferFrom, as the real vault
///      does), can refuse everything or anything under a per-token minimum, and pays configured INFER / IMD / ETH
///      on claimFees.
contract MockVaultV2 {
    /// @dev The fee tokens it pays (PaymentLib reads these, as from the real vault).
    address public infer = MOCK_INFER;
    address public imd = MOCK_IMD;
    bool public rejecting;
    mapping(address token => uint256) public minContribution;
    mapping(address token => uint256) public received;
    mapping(address benefactor => mapping(address token => uint256)) public credited;

    uint256 public inferToPay;
    uint256 public imdToPay;
    uint256 public ethToPay;
    ClaimMode public lastMode;
    uint256 public lastMinEthOut;
    uint256 public claims;

    function setFeeTokens(address i, address m) external {
        (infer, imd) = (i, m);
    }

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function setMinContribution(address token, uint256 m) external {
        minContribution[token] = m;
    }

    function setFees(uint256 infer, uint256 imd, uint256 eth) external {
        inferToPay = infer;
        imdToPay = imd;
        ethToPay = eth;
    }

    function receiveContribution(Currency currency, uint256 amount, address benefactor) external payable {
        require(!rejecting, "rejecting");
        address token = Currency.unwrap(currency);
        require(amount >= minContribution[token], "below minimum");
        if (token == address(0)) {
            require(msg.value == amount, "value");
        } else {
            require(msg.value == 0, "value");
            MockToken(token).transferFrom(msg.sender, address(this), amount);
        }
        received[token] += amount;
        credited[benefactor][token] += amount;
    }

    function claimFees(ClaimMode mode, uint256 minEthOut)
        external
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        lastMode = mode;
        lastMinEthOut = minEthOut;
        ++claims;
        if (mode == ClaimMode.REINVEST) {
            inferToPay = 0;
            imdToPay = 0;
            return (0, 0, 0);
        }
        if (mode == ClaimMode.ETH) {
            ethOut = ethToPay;
            require(ethOut >= minEthOut, "minEthOut");
        } else {
            inferOut = inferToPay;
            imdOut = imdToPay;
            ethOut = ethToPay;
        }
        inferToPay = 0;
        imdToPay = 0;
        ethToPay = 0;
        if (inferOut != 0) MockToken(infer).transfer(msg.sender, inferOut);
        if (imdOut != 0) MockToken(imd).transfer(msg.sender, imdOut);
        if (ethOut != 0) {
            (bool ok,) = msg.sender.call{ value: ethOut }("");
            require(ok, "eth");
        }
    }

    receive() external payable { }
}

/// @dev Shared setup: the seven payment tokens as mocks (INFER and IMD at their mainnet addresses, which
///      claimVaultFees forwards), a registry allowlisting them, a v2 vault, CreateX.
abstract contract PaymentTestBase is Test {
    address constant ETH = address(0);

    MockPaymentRegistry registry;
    MockVaultV2 vault;
    BlocklistToken usdc; // 6 decimals, blocklist
    BlocklistToken wbtc; // 8 decimals, blocklist
    MockToken cbbtc; // 8 decimals
    MockToken imdUsd; // 18 decimals
    MockToken infer; // 18 decimals, at MOCK_INFER
    MockToken imd; // 18 decimals, at MOCK_IMD
    FeeOnTransferToken feeToken; // allowlisted on purpose: the balance check must still refuse it

    address treasury = makeAddr("treasury");
    address artist = makeAddr("artist");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _setUpPayments() internal {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        registry = new MockPaymentRegistry(treasury);
        vault = new MockVaultV2();
        registry.setVault(address(vault), true);

        usdc = new BlocklistToken("USD Coin", "USDC", 6);
        wbtc = new BlocklistToken("Wrapped BTC", "WBTC", 8);
        cbbtc = new MockToken("Coinbase BTC", "cbBTC", 8);
        imdUsd = new MockToken("imdUSD", "imdUSD", 18);
        deployCodeTo("PaymentMocks.sol:MockToken", abi.encode("INFER", "INFER", uint8(18)), MOCK_INFER);
        deployCodeTo("PaymentMocks.sol:MockToken", abi.encode("IMD", "IMD", uint8(18)), MOCK_IMD);
        infer = MockToken(MOCK_INFER);
        imd = MockToken(MOCK_IMD);
        feeToken = new FeeOnTransferToken();

        address[7] memory all =
            [address(usdc), address(wbtc), address(cbbtc), address(imdUsd), address(infer), address(imd), address(feeToken)];
        for (uint256 i; i < all.length; ++i) {
            registry.setPaymentToken(all[i], true);
        }

        vm.warp(1_000_000);
        address[3] memory buyers = [alice, bob, carol];
        for (uint256 i; i < buyers.length; ++i) {
            vm.deal(buyers[i], 1000 ether);
            usdc.mint(buyers[i], 1_000_000e6);
            wbtc.mint(buyers[i], 100e8);
            cbbtc.mint(buyers[i], 100e8);
            imdUsd.mint(buyers[i], 1_000_000e18);
            imd.mint(buyers[i], 1_000_000e18);
            infer.mint(buyers[i], 1_000_000e18);
            feeToken.mint(buyers[i], 1_000_000e18);
        }
        vm.deal(artist, 100 ether);
        usdc.mint(artist, 1_000_000e6);
        cbbtc.mint(artist, 100e8);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : MockToken(token).balanceOf(who);
    }

    function _approve(address who, address token, address spender) internal {
        if (token == ETH) return;
        vm.prank(who);
        MockToken(token).approve(spender, type(uint256).max);
    }

    function _one(address token, uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(token, price);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    function _list(address a, address b, address c, address d) internal pure returns (address[] memory l) {
        l = new address[](4);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        l[3] = d;
    }

    /// @dev The vault pays the collection's claim: fund it with INFER, IMD and ETH.
    function _fundVaultFees(uint256 inferAmt, uint256 imdAmt, uint256 ethAmt) internal {
        infer.mint(address(vault), inferAmt);
        imd.mint(address(vault), imdAmt);
        vm.deal(address(vault), address(vault).balance + ethAmt);
        vault.setFees(inferAmt, imdAmt, ethAmt);
    }
}
