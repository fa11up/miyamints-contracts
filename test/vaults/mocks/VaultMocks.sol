// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-20 with any decimals and open mint/burn (tests only).
contract MockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
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

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Token that skims 1% on every transfer (must be refused by the vault's balance-delta check).
contract MockFeeOnTransferToken is MockToken {
    constructor() MockToken("FOT", "FOT", 18) {}

    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @notice zRouter stand-in: swapV3 / swapV4 at a fixed rate per (tokenIn, tokenOut), 1e18 = 1:1 in raw units.
///         Pulls non-ETH input from msg.sender like zRouter, mints MockToken output, pays ETH from its balance;
///         `swapAmount = 0` sells all of msg.value (ETH in), like zRouter.
///         Like zRouter, refunds its whole ETH balance to the payer after an ETH-in swap when `refundOnEthIn` is set.
contract MockRouteRouter {
    mapping(address => mapping(address => uint256)) public rate;
    uint256 public calls;
    uint256 public refundExtra; // ETH (from its balance) to refund to the payer after an ETH-in swap
    bool public lastWasV3;

    receive() external payable {}

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function setRefundExtra(uint256 amount) external {
        refundExtra = amount;
    }

    function swapV3(address to, bool, uint24, address tokenIn, address tokenOut, uint256 swapAmount, uint256 amountLimit, uint256)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut)
    {
        lastWasV3 = true;
        return _swap(to, tokenIn, tokenOut, swapAmount, amountLimit);
    }

    function swapV4(
        address to,
        bool,
        uint24,
        int24,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        lastWasV3 = false;
        return _swap(to, tokenIn, tokenOut, swapAmount, amountLimit);
    }

    function _swap(address to, address tokenIn, address tokenOut, uint256 swapAmount, uint256 amountLimit)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        ++calls;
        uint256 r = rate[tokenIn][tokenOut];
        require(r != 0, "MockRouteRouter: no rate");
        if (swapAmount == 0) swapAmount = tokenIn == address(0) ? msg.value : MockToken(tokenIn).balanceOf(address(this));
        amountIn = swapAmount;
        amountOut = swapAmount * r / 1e18;
        require(amountLimit == 0 || amountOut >= amountLimit, "Slippage");
        if (tokenIn == address(0)) {
            require(msg.value == swapAmount, "msg.value");
        } else {
            MockToken(tokenIn).transferFrom(msg.sender, address(this), swapAmount);
        }
        if (tokenOut == address(0)) {
            (bool ok,) = payable(to).call{value: amountOut}("");
            require(ok, "eth out");
        } else {
            MockToken(tokenOut).mint(to, amountOut);
        }
        if (tokenIn == address(0) && refundExtra != 0) {
            uint256 x = refundExtra;
            refundExtra = 0;
            (bool ok,) = payable(msg.sender).call{value: x}("");
            require(ok, "refund");
        }
    }
}

/// @notice Token whose transferFrom does not spend the allowance (some real tokens behave so for their own reasons):
///         makes the vault's approval reset observable.
contract StickyAllowanceToken is MockToken {
    constructor() MockToken("STICKY", "STICKY", 18) {}

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        _move(from, to, amount);
        return true;
    }
}

/// @notice Token with an admin "seize" (like a regulated token's wipe): lets a target take more than it was approved.
contract SeizableToken is MockToken {
    constructor() MockToken("SEIZE", "SEIZE", 18) {}

    function seize(address from, address to, uint256 amount) external {
        _move(from, to, amount);
    }
}

interface IReenterVault {
    function collectFees() external;
}

/// @notice An aggregator target for the vault's guard tests: swaps at a fixed rate like MockRouteRouter, and can
///         misbehave in one way at a time.
contract MockAggregator {
    enum Mode {
        Normal,
        UnderDeliver, // pays out half
        PullLess, // pulls 1 unit less than asked
        OverPull, // also seizes 1 unit beyond the amount (SeizableToken)
        ReturnEth, // sends `extraEth` of its own ETH back to the caller
        Reenter, // calls back into the vault
        SendElsewhere, // pays the output to `elsewhere`
        RefundInput, // pulls the amount, then sends 1 unit back
        Revert, // reverts with a reason
        SeizeOther, // also seizes 1 unit of `other` (a SeizableToken the vault holds for someone else)
        PullMore // tries to pull 1 unit more than the amount with transferFrom
    }

    mapping(address => mapping(address => uint256)) public rate;
    Mode public mode;
    uint256 public extraEth;
    address public elsewhere = address(0xbeef);
    bytes public reenterCall;
    address public other;

    receive() external payable {}

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setExtraEth(uint256 e) external {
        extraEth = e;
    }

    function setOther(address o) external {
        other = o;
    }

    function setReenterCall(bytes calldata c) external {
        reenterCall = c;
    }

    /// @dev Sell `amountIn` (0 = all of msg.value) of `tokenIn` for `tokenOut`, paid to msg.sender.
    function swap(address tokenIn, uint256 amountIn, address tokenOut) external payable returns (uint256 out) {
        if (mode == Mode.Revert) revert("MockAggregator: no route");
        if (amountIn == 0) amountIn = msg.value;
        uint256 r = rate[tokenIn][tokenOut];
        require(r != 0, "MockAggregator: no rate");
        if (tokenIn == address(0)) {
            require(msg.value == amountIn, "msg.value");
        } else {
            uint256 pull = mode == Mode.PullLess ? amountIn - 1 : mode == Mode.PullMore ? amountIn + 1 : amountIn;
            MockToken(tokenIn).transferFrom(msg.sender, address(this), pull);
            if (mode == Mode.OverPull) SeizableToken(tokenIn).seize(msg.sender, address(this), 1);
            if (mode == Mode.RefundInput) MockToken(tokenIn).transfer(msg.sender, 1);
        }
        if (mode == Mode.SeizeOther) SeizableToken(other).seize(msg.sender, address(this), 1);
        out = amountIn * r / 1e18;
        if (mode == Mode.UnderDeliver) out /= 2;
        address to = mode == Mode.SendElsewhere ? elsewhere : msg.sender;
        if (tokenOut == address(0)) {
            (bool ok,) = payable(to).call{value: out}("");
            require(ok, "eth out");
        } else {
            MockToken(tokenOut).mint(to, out);
        }
        if (mode == Mode.ReturnEth) {
            (bool ok,) = payable(msg.sender).call{value: extraEth}("");
            require(ok, "eth back");
        }
        if (mode == Mode.Reenter) {
            (bool ok, bytes memory ret) = msg.sender.call(reenterCall);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
