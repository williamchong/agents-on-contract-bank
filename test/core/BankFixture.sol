// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ERC7913P256Verifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {StaffRoles} from "../../contracts/core/StaffRoles.sol";
import {HoldRegister} from "../../contracts/core/HoldRegister.sol";
import {PartnerKeys} from "../../contracts/core/PartnerKeys.sol";
import {Payments} from "../../contracts/core/Payments.sol";

/// @dev Deploys the bank as docs/roles.md describes it: governance is a time lock behind the
/// officers' multi-signer account, holding the admin and governance roles, the staff roles module
/// administers every staff and machine role, the hold register sets every frozen amount, and the
/// partner key register holds the keys partners sign with, among them the clearing system's, and
/// the payments module holds money in waiting. The test contract deploys and wires the
/// contracts, hands the admin role to governance and gives up its own, and governance then posts
/// the opening balance sheet in docs/scenarios.md.
abstract contract BankFixture is Test {
    /// @dev One Hong Kong dollar, in the token's cents.
    uint256 constant HKD = 100;
    uint256 constant GOVERNANCE_DELAY = 2 days;
    uint64 constant GOVERNANCE_THRESHOLD = 3;
    uint64 constant BRANCHES = 2;
    uint256 constant SCREENING_THRESHOLD = 50_000 * HKD;
    bytes32 constant CLEARING = keccak256("clearing");

    AccessManager manager;
    DepositToken token;
    GeneralLedger ledger;
    StaffRoles staffRoles;
    HoldRegister holds;
    PartnerKeys partnerKeys;
    Payments payments;
    ERC7913P256Verifier p256;
    MultiSignerAccount officers;
    TimelockController timelock;
    /// @dev The time lock, which holds the admin and governance roles.
    address governance;

    uint256[] officerKeys;
    uint256 clearingKey = _key("clearing");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    /// @dev Every other customer's deposits on the opening balance sheet, held together.
    address otherCustomers = makeAddr("otherCustomers");
    /// @dev A bank-owned account, such as pending withdrawals.
    address pending = makeAddr("pending");

    function setUp() public virtual {
        officerKeys = [uint256(0x0F1), 0x0F2, 0x0F3, 0x0F4];
        p256 = new ERC7913P256Verifier();
        officers = new MultiSignerAccount(_verifiers(), _signers(officerKeys), GOVERNANCE_THRESHOLD);
        address[] memory proposers = new address[](1);
        proposers[0] = address(officers);
        // Anyone may carry out a decision once its delay has passed.
        timelock = new TimelockController(GOVERNANCE_DELAY, proposers, new address[](1), address(0));
        governance = address(timelock);

        manager = new AccessManager(address(this));
        token = new DepositToken(address(manager));
        ledger = new GeneralLedger(address(manager), token);
        staffRoles = new StaffRoles(manager, officers);
        holds = new HoldRegister(manager, token);
        partnerKeys = new PartnerKeys(address(manager));
        payments = new Payments(address(manager), ledger, partnerKeys, SCREENING_THRESHOLD);

        _wire(address(token), token.mint.selector, Roles.LEDGER);
        _wire(address(token), token.burn.selector, Roles.LEDGER);
        _wire(address(token), token.forcedTransfer.selector, Roles.ENFORCER);
        _wire(address(token), token.setFrozenTokens.selector, Roles.FREEZER);
        _wire(address(token), token.blockUser.selector, Roles.COMPLIANCE);
        _wire(address(token), token.unblockUser.selector, Roles.GOVERNANCE);
        _wire(address(ledger), ledger.post.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postWithMint.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postWithBurn.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postOpening.selector, Roles.GOVERNANCE);
        _wire(address(partnerKeys), partnerKeys.setKey.selector, Roles.GOVERNANCE);
        _wire(address(partnerKeys), partnerKeys.revokeKey.selector, Roles.IT_SECURITY);
        _wire(address(payments), payments.clearIncoming.selector, Roles.COMPLIANCE);
        _wire(address(payments), payments.returnIncoming.selector, Roles.COMPLIANCE);
        _wire(address(payments), payments.clearOutgoing.selector, Roles.COMPLIANCE);
        _wire(address(payments), payments.returnOutgoing.selector, Roles.COMPLIANCE);
        _wire(address(payments), payments.setScreeningThreshold.selector, Roles.GOVERNANCE);

        manager.grantRole(Roles.LEDGER, address(ledger), 0);
        manager.grantRole(Roles.STAFF_ADMIN, address(staffRoles), 0);
        manager.grantRole(Roles.FREEZER, address(holds), 0);
        manager.grantRole(Roles.BOOKKEEPER, address(payments), 0);
        uint64[] memory staff = _staffAdministered();
        for (uint256 i = 0; i < staff.length; ++i) manager.setRoleAdmin(staff[i], Roles.STAFF_ADMIN);

        token.allowUser(alice);
        token.allowUser(bob);
        token.allowUser(otherCustomers);
        token.allowUser(pending);
        token.allowUser(address(payments));

        manager.grantRole(Roles.ADMIN, governance, 0);
        manager.grantRole(Roles.GOVERNANCE, governance, 0);
        manager.renounceRole(Roles.ADMIN, address(this));

        _govern(address(ledger), _openingCall());
        _govern(address(partnerKeys), abi.encodeCall(PartnerKeys.setKey, (CLEARING, _signer(clearingKey))));
    }

    // Governance

    /// @dev A decision taken as governance takes it: three officers sign, the time lock holds it
    /// for its delay, and it is then carried out.
    function _govern(address target, bytes memory data) internal {
        _execute(target, data, _schedule(target, data, _quorum()));
    }

    /// @dev Waits out the time lock's delay and carries out a scheduled decision.
    function _execute(address target, bytes memory data, bytes32 salt) internal {
        vm.warp(block.timestamp + GOVERNANCE_DELAY);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    /// @dev Has the officers' account schedule `data` on the time lock, signed by `keys`.
    function _schedule(address target, bytes memory data, uint256[] memory keys) internal returns (bytes32 salt) {
        salt = bytes32(officers.executionNonce());
        bytes memory schedule = abi.encodeCall(
            TimelockController.schedule,
            (target, 0, data, bytes32(0), salt, GOVERNANCE_DELAY)
        );
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(timelock), 0, schedule);
        bytes memory executionData = ERC7579Utils.encodeBatch(batch);
        officers.executeSigned(executionData, _signExecution(officers, executionData, keys));
    }

    /// @dev The first three officers' keys.
    function _quorum() internal view returns (uint256[] memory keys) {
        keys = new uint256[](GOVERNANCE_THRESHOLD);
        for (uint256 i = 0; i < keys.length; ++i) keys[i] = officerKeys[i];
    }

    // Accounts and keys

    /// @dev A staff member's account with one P-256 key of its own.
    function _staff(string memory name) internal returns (address) {
        uint256[] memory keys = new uint256[](1);
        keys[0] = _key(name);
        return address(new MultiSignerAccount(_verifiers(), _signers(keys), 1));
    }

    /// @dev Grants a role governance grants, as governance through the staff roles module.
    function _grantStaff(address account, uint64 role) internal {
        vm.prank(governance);
        staffRoles.grant(account, role);
    }

    function _key(string memory name) internal pure returns (uint256) {
        return (uint256(keccak256(bytes(name))) % (P256.N - 1)) + 1;
    }

    function _signer(uint256 key) internal view returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        return abi.encodePacked(address(p256), x, y);
    }

    function _signers(uint256[] memory keys) internal view returns (bytes[] memory signers) {
        signers = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) signers[i] = _signer(keys[i]);
    }

    /// @dev The signature `account` checks for its next signed batch.
    function _signExecution(
        MultiSignerAccount account,
        bytes memory executionData,
        uint256[] memory keys
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Execute(bytes executionData,uint256 nonce)"),
                keccak256(executionData),
                account.executionNonce()
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_separator(account), structHash);
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) sigs[i] = _signP256(keys[i], digest);
        return abi.encode(_signers(keys), sigs);
    }

    /// @dev P-256 signatures are accepted only in their low-s form, so the high form is folded down.
    function _signP256(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        if (uint256(s) > P256.N / 2) s = bytes32(P256.N - uint256(s));
        return abi.encodePacked(r, s);
    }

    function _separator(MultiSignerAccount account) private view returns (bytes32) {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt, ) = account
            .eip712Domain();
        return MessageHashUtils.toDomainSeparator(fields, name, version, chainId, verifying, salt);
    }

    function _verifiers() private view returns (address[] memory verifiers) {
        verifiers = new address[](1);
        verifiers[0] = address(p256);
    }

    // Wiring

    function _wire(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    /// @dev Every staff and machine role, for each branch the bank has.
    function _staffAdministered() internal pure returns (uint64[] memory roles) {
        roles = new uint64[](11 + 5 * BRANCHES);
        uint256 n;
        for (uint64 r = Roles.RISK; r <= Roles.INTERNAL_AUDIT; ++r) roles[n++] = r;
        roles[n++] = Roles.ATM;
        roles[n++] = Roles.SCHEDULER;
        for (uint64 b = 1; b <= BRANCHES; ++b) {
            for (uint64 r = Roles.TELLER; r <= Roles.ACCOUNT_OPENING_OFFICER; ++r) roles[n++] = Roles.atBranch(b, r);
        }
    }

    // The books

    function _openingCall() private view returns (bytes memory) {
        address[] memory holders = new address[](3);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = otherCustomers;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100_000 * HKD;
        amounts[1] = 100_000 * HKD;
        amounts[2] = 12_100_000 * HKD;

        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](6);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Settlement, _hkd(1_000_000));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Cash, _hkd(500_000));
        lines[2] = GeneralLedger.Line(GeneralLedger.Account.Securities, _hkd(2_500_000));
        lines[3] = GeneralLedger.Line(GeneralLedger.Account.Loans, _hkd(9_300_000));
        lines[4] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -_hkd(93_000));
        lines[5] = GeneralLedger.Line(GeneralLedger.Account.Equity, -_hkd(907_000));

        return abi.encodeCall(GeneralLedger.postOpening, (holders, amounts, lines, "opening"));
    }

    function _hkd(int128 amount) internal pure returns (int128) {
        return amount * int128(int256(HKD));
    }

    function _holds(uint64 role, address account) internal view returns (bool member) {
        (member, ) = manager.hasRole(role, account);
    }

    function _assertBooksBalance() internal view {
        int256[] memory all = ledger.balances();
        int256 sum;
        for (uint256 i = 0; i < all.length; ++i) sum += all[i];
        assertEq(sum, 0, "assets equal liabilities and equity");
    }
}
