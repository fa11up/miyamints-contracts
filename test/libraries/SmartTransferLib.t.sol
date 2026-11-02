// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SmartTransferLib} from "../../src/libraries/SmartTransferLib.sol";

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert();
    }
}

contract NoReceiver {
    // no receive or fallback
}

/// @dev Harness to expose the internal library function
contract SmartTransferHarness {
    function smartTransferETH(address to, uint256 amount, address weth) external {
        SmartTransferLib.smartTransferETH(to, amount, weth);
    }

    receive() external payable {}
}

contract SmartTransferLibTest is Test {
    SmartTransferHarness harness;
    MockWETH weth;

    function setUp() public {
        harness = new SmartTransferHarness();
        weth = new MockWETH();
    }

    function test_smartTransferETH_sendsToEOA() public {
        address eoa = makeAddr("eoa");
        vm.deal(address(harness), 1 ether);

        harness.smartTransferETH(eoa, 1 ether, address(weth));

        assertEq(eoa.balance, 1 ether);
    }

    function test_smartTransferETH_zeroAmount() public {
        address eoa = makeAddr("eoa");
        // Should be a no-op, no revert
        harness.smartTransferETH(eoa, 0, address(weth));
        assertEq(eoa.balance, 0);
    }

    function test_smartTransferETH_fallbackToWETH_revertingReceiver() public {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(harness), 1 ether);

        harness.smartTransferETH(address(receiver), 1 ether, address(weth));

        // ETH should not be at receiver, WETH should
        assertEq(address(receiver).balance, 0);
        assertEq(weth.balanceOf(address(receiver)), 1 ether);
    }

    function test_smartTransferETH_fallbackToWETH_noReceive() public {
        NoReceiver receiver = new NoReceiver();
        vm.deal(address(harness), 1 ether);

        harness.smartTransferETH(address(receiver), 1 ether, address(weth));

        assertEq(address(receiver).balance, 0);
        assertEq(weth.balanceOf(address(receiver)), 1 ether);
    }

    function test_smartTransferETH_emitsEventOnFallback() public {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(harness), 1 ether);

        vm.expectEmit(true, false, false, true);
        emit SmartTransferLib.ETHTransferFallbackToWETH(address(receiver), 1 ether);

        harness.smartTransferETH(address(receiver), 1 ether, address(weth));
    }

    function test_smartTransferETH_noEventOnDirectTransfer() public {
        address eoa = makeAddr("eoa");
        vm.deal(address(harness), 1 ether);

        vm.recordLogs();
        harness.smartTransferETH(eoa, 1 ether, address(weth));

        // No logs should be emitted for direct transfer
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_smartTransferETH_revertsOnDoubleFailure() public {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(harness), 1 ether);

        // Use a bad weth address (not a contract) — both paths fail
        vm.expectRevert();
        harness.smartTransferETH(address(receiver), 1 ether, address(0xdead));
    }
}
