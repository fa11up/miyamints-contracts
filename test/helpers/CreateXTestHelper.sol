// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CREATEX} from "../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

/// @notice Mixin that etches CreateX bytecode at its canonical address for local tests
abstract contract CreateXTestHelper is Test {
    function _etchCreateX() internal {
        vm.etch(CREATEX, CREATEX_BYTECODE);
    }
}
