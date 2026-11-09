// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { EligibilityGate } from "../../src/markets/EligibilityGate.sol";

contract EligibilityGateTest is MarketsBase {
    function _p(address wallet, uint64 issuedAt, uint64 expiresAt)
        internal
        pure
        returns (MarketTypes.EligibilityPass memory)
    {
        return MarketTypes.EligibilityPass({ wallet: wallet, issuedAt: issuedAt, expiresAt: expiresAt });
    }

    function test_validPass() public view {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        gate.check(alice, p, sig);
    }

    function test_replayByAnotherWallet_rejected() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.expectRevert(EligibilityGate.WrongWallet.selector);
        gate.check(bob, p, sig);
        // rewriting the wallet breaks the signature
        p.wallet = bob;
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        gate.check(bob, p, sig);
    }

    function test_replayInAnotherMarketByOwner_isAllowedWithinTtl() public {
        // A pass admits its wallet, not a single stake: it is reusable until it expires.
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        gate.check(alice, p, sig);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        gate.check(alice, p, sig);
    }

    function test_expiredPass_rejected() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.warp(p.expiresAt + 1);
        vm.expectRevert(EligibilityGate.PassExpired.selector);
        gate.check(alice, p, sig);
    }

    function test_passAtExactExpiry_accepted() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.warp(p.expiresAt);
        gate.check(alice, p, sig);
    }

    function test_futurePass_rejected() public {
        MarketTypes.EligibilityPass memory p =
            _p(alice, uint64(vm.getBlockTimestamp() + 10), uint64(vm.getBlockTimestamp() + 100));
        bytes memory sig = _signPass(p, KYC_KEY);
        vm.expectRevert(EligibilityGate.PassNotYetValid.selector);
        gate.check(alice, p, sig);
    }

    function test_longLivedPass_rejected() public {
        MarketTypes.EligibilityPass memory p =
            _p(alice, uint64(vm.getBlockTimestamp()), uint64(vm.getBlockTimestamp() + 1 days + 1));
        bytes memory sig = _signPass(p, KYC_KEY);
        vm.expectRevert(EligibilityGate.PassTooLong.selector);
        gate.check(alice, p, sig);
    }

    function test_wrongChain_rejected() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.chainId(11155111);
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        gate.check(alice, p, sig);
    }

    function test_otherGate_rejected() public {
        EligibilityGate other = new EligibilityGate(owner, kycSigner);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice); // signed for `gate`
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        other.check(alice, p, sig);
    }

    function test_wrongSigner_rejected() public {
        (MarketTypes.EligibilityPass memory p,) = _pass(alice);
        bytes memory sig = _signPass(p, 0xBAD);
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        gate.check(alice, p, sig);
    }

    function test_malformedSignature_rejected() public {
        (MarketTypes.EligibilityPass memory p,) = _pass(alice);
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        gate.check(alice, p, hex"1234");
    }

    function test_revoke_refusesEarlierPasses() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.prank(kycSigner);
        gate.revoke(alice);
        vm.expectRevert(EligibilityGate.PassRevoked.selector);
        gate.check(alice, p, sig);
        // a pass issued after the revocation works again
        vm.warp(vm.getBlockTimestamp() + 1);
        (p, sig) = _pass(alice);
        gate.check(alice, p, sig);
    }

    function test_revoke_onlyOwnerOrSigner() public {
        vm.prank(alice);
        vm.expectRevert(EligibilityGate.NotAuthorized.selector);
        gate.revoke(bob);
        vm.prank(owner);
        gate.revoke(bob);
    }

    function test_setSigner_rotatesAndOnlyOwner() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gate.setSigner(alice);
        vm.prank(owner);
        vm.expectRevert(EligibilityGate.InvalidAddress.selector);
        gate.setSigner(address(0));
        vm.prank(owner);
        gate.setSigner(vm.addr(0xC0DE));
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        gate.check(alice, p, sig);
        gate.check(alice, p, _signPass(p, 0xC0DE));
    }
}
