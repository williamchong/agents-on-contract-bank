// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Roles} from "../../contracts/core/Roles.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {Attestations} from "../../contracts/core/Attestations.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks attested figures against open question 16 in docs/plan.md and the ledger mismatch
/// scenario in docs/scenarios.md: a partner's statement is accepted only under the key of the
/// partner that attests its account, only in sequence, and is compared with the ledger's balance at
/// its own date; a mismatch posts nothing, and a figure is current only while it matched and is
/// young enough.
contract AttestationsTest is BankFixture {
    GeneralLedger.Account constant SETTLEMENT = GeneralLedger.Account.Settlement;
    GeneralLedger.Account constant SECURITIES = GeneralLedger.Account.Securities;

    uint256 sequence;

    function setUp() public override {
        super.setUp();
        vm.warp(block.timestamp + 1 hours);
    }

    // Matching

    function test_Match_PaymentsDay() public {
        Payments.CreditAdvice memory advice = Payments.CreditAdvice(
            keccak256("E2E-1"),
            1_000 * HKD,
            "HKD",
            bytes32(uint256(uint160(alice))),
            block.timestamp,
            keccak256("camt.054")
        );
        payments.receiveCredit(advice, _signP256(clearingKey, payments.hashCreditAdvice(advice)));
        uint256 closing = _balance(SETTLEMENT);
        uint256 dayEnd = block.timestamp;
        vm.warp(block.timestamp + 1 hours);

        Attestations.Statement memory m = _statement(closing, dayEnd);
        vm.expectEmit(address(attestations));
        emit Attestations.StatementAccepted(SETTLEMENT, m.statementId, m.sequence, closing, closing, true, m.documentHash);
        _accept(SETTLEMENT, m, clearingKey);

        assertTrue(attestations.figure(SETTLEMENT).matched);
        assertTrue(attestations.isCurrent(SETTLEMENT));
    }

    function test_Match_ComparedAtItsOwnDate() public {
        uint256 closing = _balance(SETTLEMENT);
        uint256 dayEnd = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        _moveSettlement(-int256(10_000 * HKD));

        _accept(SETTLEMENT, _statement(closing, dayEnd), clearingKey);
        assertTrue(attestations.isCurrent(SETTLEMENT), "a later movement is not a mismatch");
    }

    function test_Custodian_AttestsSecurities() public {
        _accept(SECURITIES, _statement(_balance(SECURITIES), block.timestamp - 1), custodianKey);
        assertTrue(attestations.isCurrent(SECURITIES));
    }

    function test_NoFigure_NotCurrent() public view {
        assertFalse(attestations.isCurrent(SETTLEMENT));
    }

    // Mismatch

    function test_Mismatch_MarkedAndPostsNothing() public {
        uint256 ledgerBalance = _balance(SETTLEMENT);
        uint256 entries = ledger.entryCount();
        Attestations.Statement memory m = _statement(ledgerBalance + 1, block.timestamp - 1);

        vm.expectEmit(address(attestations));
        emit Attestations.StatementAccepted(
            SETTLEMENT,
            m.statementId,
            m.sequence,
            ledgerBalance + 1,
            ledgerBalance,
            false,
            m.documentHash
        );
        _accept(SETTLEMENT, m, clearingKey);

        Attestations.Figure memory f = attestations.figure(SETTLEMENT);
        assertFalse(f.matched);
        assertEq(f.amount, ledgerBalance + 1);
        assertEq(f.ledgerBalance, ledgerBalance);
        assertFalse(attestations.isCurrent(SETTLEMENT));
        assertEq(ledger.entryCount(), entries, "nothing is posted");
        assertEq(_balance(SETTLEMENT), ledgerBalance);
        _assertBooksBalance();
    }

    function test_Mismatch_ClearedByALaterMatch() public {
        _accept(SETTLEMENT, _statement(1, block.timestamp - 1), clearingKey);
        vm.warp(block.timestamp + 1 days);
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), block.timestamp - 1), clearingKey);
        assertTrue(attestations.isCurrent(SETTLEMENT));
    }

    // Refusals

    function test_Refused_Forged() public {
        _expectBadSignature(SETTLEMENT, _key("forger"), attestations);
    }

    function test_Refused_CustodianCannotAttestSettlement() public {
        _expectBadSignature(SETTLEMENT, custodianKey, attestations);
    }

    function test_Refused_AnyFieldChanged() public {
        Attestations.Statement memory signed = _statement(_balance(SETTLEMENT), block.timestamp - 1);
        bytes memory sig = _signP256(clearingKey, attestations.hashStatement(signed));
        for (uint256 field = 0; field < 5; ++field) {
            Attestations.Statement memory m = Attestations.Statement(
                field == 0 ? keccak256("other") : signed.statementId,
                field == 1 ? signed.sequence + 1 : signed.sequence,
                field == 2 ? signed.closingBalance + 1 : signed.closingBalance,
                field == 3 ? signed.asOf - 1 : signed.asOf,
                field == 4 ? keccak256("another document") : signed.documentHash
            );
            vm.expectRevert(Attestations.InvalidPartnerSignature.selector);
            attestations.acceptStatement(SETTLEMENT, m, sig);
        }
    }

    function test_Refused_OtherDeployment() public {
        Attestations other = new Attestations(address(manager), ledger, partnerKeys, STATEMENT_MAX_AGE);
        _expectBadSignature(SETTLEMENT, clearingKey, other);
    }

    function test_Refused_RevokedKey() public {
        address itSecurity = _staff("itSecurity");
        _grantStaff(itSecurity, Roles.IT_SECURITY);
        vm.prank(itSecurity);
        partnerKeys.revokeKey(CLEARING);
        _expectBadSignature(SETTLEMENT, clearingKey, attestations);
    }

    function test_Refused_AccountsWithNoPartner() public {
        GeneralLedger.Account[2] memory none = [GeneralLedger.Account.Cash, GeneralLedger.Account.Loans];
        for (uint256 i = 0; i < none.length; ++i) {
            Attestations.Statement memory m = _statement(1, block.timestamp - 1);
            bytes memory sig = _signP256(clearingKey, attestations.hashStatement(m));
            vm.expectRevert(abi.encodeWithSelector(Attestations.NotAttested.selector, none[i]));
            attestations.acceptStatement(none[i], m, sig);
        }
    }

    function test_Sequence_ReplayedOrOlderRefused() public {
        Attestations.Statement memory first = _statement(_balance(SETTLEMENT), block.timestamp - 2);
        _accept(SETTLEMENT, first, clearingKey);
        _expectRefused(first, abi.encodeWithSelector(Attestations.StaleStatement.selector, 1, 1));

        Attestations.Statement memory second = _statement(_balance(SETTLEMENT), block.timestamp - 1);
        _accept(SETTLEMENT, second, clearingKey);
        _expectRefused(first, abi.encodeWithSelector(Attestations.StaleStatement.selector, 1, 2));
    }

    function test_Sequence_ANumberMayBeSkipped() public {
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), block.timestamp - 2), clearingKey);
        sequence += 3;
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), block.timestamp - 1), clearingKey);
        assertEq(attestations.figure(SETTLEMENT).sequence, 5);
    }

    function test_Date_FutureRefused() public {
        Attestations.Statement memory m = _statement(_balance(SETTLEMENT), block.timestamp + 1);
        _expectRefused(m, abi.encodeWithSelector(Attestations.FutureStatement.selector, block.timestamp + 1));
    }

    /// @dev Later transactions in the same block could still move the balance it attests.
    function test_Date_ThisBlockRefused() public {
        Attestations.Statement memory m = _statement(_balance(SETTLEMENT), block.timestamp);
        _expectRefused(m, abi.encodeWithSelector(Attestations.FutureStatement.selector, block.timestamp));
    }

    function test_Date_NotAfterTheLatestRefused() public {
        uint256 asOf = block.timestamp - 1;
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), asOf), clearingKey);
        vm.warp(block.timestamp + 1 hours);
        Attestations.Statement memory m = _statement(_balance(SETTLEMENT), asOf);
        _expectRefused(m, abi.encodeWithSelector(Attestations.OutOfDateStatement.selector, asOf, asOf));
    }

    // Age

    function test_Age_StaleAfterTheMaximum() public {
        uint256 asOf = block.timestamp - 1;
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), asOf), clearingKey);
        vm.warp(asOf + STATEMENT_MAX_AGE);
        assertTrue(attestations.isCurrent(SETTLEMENT));
        vm.warp(asOf + STATEMENT_MAX_AGE + 1);
        assertFalse(attestations.isCurrent(SETTLEMENT));
    }

    function test_Age_SetByGovernance() public {
        uint256 asOf = block.timestamp - 1;
        _accept(SETTLEMENT, _statement(_balance(SETTLEMENT), asOf), clearingKey);
        _govern(address(attestations), abi.encodeCall(Attestations.setMaxAge, (5 days)));
        vm.warp(asOf + 5 days);
        assertTrue(attestations.isCurrent(SETTLEMENT));
        vm.warp(asOf + 5 days + 1);
        assertFalse(attestations.isCurrent(SETTLEMENT));
    }

    // Helpers

    function _statement(uint256 closing, uint256 asOf) private returns (Attestations.Statement memory) {
        ++sequence;
        return
            Attestations.Statement(
                keccak256(abi.encode("STMT", sequence)),
                sequence,
                closing,
                asOf,
                keccak256(abi.encode("camt.053", sequence))
            );
    }

    function _accept(GeneralLedger.Account account, Attestations.Statement memory m, uint256 key) private {
        attestations.acceptStatement(account, m, _signP256(key, attestations.hashStatement(m)));
    }

    function _expectBadSignature(GeneralLedger.Account account, uint256 key, Attestations signedFor) private {
        Attestations.Statement memory m = _statement(_balance(account), block.timestamp - 1);
        bytes memory sig = _signP256(key, signedFor.hashStatement(m));
        vm.expectRevert(Attestations.InvalidPartnerSignature.selector);
        attestations.acceptStatement(account, m, sig);
    }

    function _expectRefused(Attestations.Statement memory m, bytes memory reason) private {
        bytes memory sig = _signP256(clearingKey, attestations.hashStatement(m));
        vm.expectRevert(reason);
        attestations.acceptStatement(SETTLEMENT, m, sig);
    }

    function _balance(GeneralLedger.Account account) private view returns (uint256) {
        return uint256(ledger.balanceOf(account));
    }
}
