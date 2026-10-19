// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC7739Utils} from "@openzeppelin/contracts/utils/cryptography/draft-ERC7739Utils.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ERC7913P256Verifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {StaffRoles} from "../../contracts/core/StaffRoles.sol";
import {HoldRegister} from "../../contracts/core/HoldRegister.sol";
import {PartnerKeys, Partners} from "../../contracts/core/PartnerKeys.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {Attestations} from "../../contracts/core/Attestations.sol";
import {CashOperations} from "../../contracts/core/CashOperations.sol";
import {BranchApprovals} from "../../contracts/core/BranchApprovals.sol";
import {AssistedOperations} from "../../contracts/core/AssistedOperations.sol";
import {CustomerLimits} from "../../contracts/core/CustomerLimits.sol";
import {AccountRecovery} from "../../contracts/core/AccountRecovery.sol";
import {DisputeReversal} from "../../contracts/core/DisputeReversal.sol";
import {IncidentLog} from "../../contracts/core/IncidentLog.sol";

/// @dev Deploys the bank as docs/roles.md describes it: governance is a time lock behind the
/// officers' multi-signer account, holding the admin and governance roles, the staff roles module
/// administers every staff and machine role, the hold register sets every frozen amount, the
/// partner key register holds the keys the clearing system and the custodian sign with, the
/// payments module holds money in waiting, attested figures check the partners' statements
/// against the ledger, the cash module keeps the cash, and the assisted operations module holds
/// transfers through a teller while they climb the approval ladder, the recovery module is fixed in
/// customers' accounts, the dispute reversal module freezes and reverses disputed transfers, and finance
/// reports incidents to the regulator in the incident log. The test contract deploys and wires the
/// contracts, hands the admin role to governance and gives up its own, and governance then posts
/// the opening balance sheet in docs/scenarios.md and splits its cash as docs/roles.md does.
abstract contract BankFixture is Test {
    /// @dev One Hong Kong dollar, in the token's cents.
    uint256 constant HKD = 100;
    uint256 constant GOVERNANCE_DELAY = 2 days;
    uint64 constant GOVERNANCE_THRESHOLD = 3;
    uint64 constant BRANCHES = 2;
    uint256 constant SCREENING_THRESHOLD = 50_000 * HKD;
    bytes32 constant CLEARING = Partners.CLEARING;
    bytes32 constant CUSTODIAN = Partners.CUSTODIAN;
    uint256 constant STATEMENT_MAX_AGE = 2 days;
    uint256 constant DRAWER_LIMIT = 100_000 * HKD;
    uint256 constant ATM_LIMIT = 5_000 * HKD;
    uint256 constant CASH_REPORT_THRESHOLD = 100_000 * HKD;
    uint256 constant DISPENSE_TIMEOUT = 2 minutes;
    uint256 constant LADDER_FIRST = 50_000 * HKD;
    uint256 constant LADDER_SECOND = 500_000 * HKD;
    uint256 constant APP_LIMIT = 10_000 * HKD;
    uint256 constant UNREGISTERED_PAYEE_LIMIT = 2_000 * HKD;
    uint256 constant PAYEE_WAIT = 24 hours;

    AccessManager manager;
    CustomerLimits limits;
    DepositToken token;
    GeneralLedger ledger;
    StaffRoles staffRoles;
    HoldRegister holds;
    PartnerKeys partnerKeys;
    Payments payments;
    Attestations attestations;
    CashOperations cash;
    AssistedOperations assisted;
    AccountRecovery recovery;
    DisputeReversal disputes;
    IncidentLog incidents;
    ERC7913P256Verifier p256;
    MultiSignerAccount officers;
    TimelockController timelock;
    /// @dev The time lock, which holds the admin and governance roles.
    address governance;

    uint256[] officerKeys;
    uint256 clearingKey = _key("clearing");
    uint256 custodianKey = _key("custodian");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    /// @dev Every other customer's deposits on the opening balance sheet, held together.
    address otherCustomers = makeAddr("otherCustomers");
    /// @dev A bank-owned account, such as pending withdrawals.
    address pending = makeAddr("pending");
    /// @dev Stands in for treasury's own module, still to come, holding the bookkeeper role.
    address treasury = makeAddr("treasury");
    /// @dev Branch 1's first teller and its ATM, whose drawer and machine hold cash at opening.
    address teller1;
    address atm1 = makeAddr("atm1");

    function setUp() public virtual {
        officerKeys = [uint256(0x0F1), 0x0F2, 0x0F3, 0x0F4];
        p256 = new ERC7913P256Verifier();
        officers = new MultiSignerAccount(_verifiers(), _signers(officerKeys), GOVERNANCE_THRESHOLD, address(0));
        address[] memory proposers = new address[](1);
        proposers[0] = address(officers);
        // Anyone may carry out a decision once its delay has passed.
        timelock = new TimelockController(GOVERNANCE_DELAY, proposers, new address[](1), address(0));
        governance = address(timelock);

        manager = new AccessManager(address(this));
        limits = new CustomerLimits(
            address(manager),
            CustomerLimits.Limits(APP_LIMIT, UNREGISTERED_PAYEE_LIMIT, PAYEE_WAIT)
        );
        token = new DepositToken(address(manager), limits);
        ledger = new GeneralLedger(address(manager), token);
        staffRoles = new StaffRoles(manager, officers);
        holds = new HoldRegister(manager, token);
        partnerKeys = new PartnerKeys(address(manager));
        payments = new Payments(address(manager), ledger, partnerKeys, SCREENING_THRESHOLD);
        attestations = new Attestations(address(manager), ledger, partnerKeys, STATEMENT_MAX_AGE);
        recovery = new AccountRecovery(manager);
        disputes = new DisputeReversal(manager, token, holds);
        incidents = new IncidentLog(address(manager));
        cash = new CashOperations(
            address(manager),
            ledger,
            CashOperations.Limits(DRAWER_LIMIT, ATM_LIMIT, CASH_REPORT_THRESHOLD, DISPENSE_TIMEOUT),
            recovery,
            BranchApprovals.Ladder(LADDER_FIRST, LADDER_SECOND)
        );
        assisted = new AssistedOperations(address(manager), token, recovery, BranchApprovals.Ladder(LADDER_FIRST, LADDER_SECOND));
        teller1 = _staff("teller1");
        // How movements into the modules count, set while the deployer is still the admin.
        limits.setChannel(address(cash), CustomerLimits.Channel.Own);
        limits.setChannel(address(assisted), CustomerLimits.Channel.Own);
        limits.setChannel(address(payments), CustomerLimits.Channel.PayeeCheckedThere);

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
        _wire(address(attestations), attestations.setMaxAge.selector, Roles.GOVERNANCE);
        _wire(address(cash), cash.openCash.selector, Roles.GOVERNANCE);
        _wire(address(cash), cash.setLimits.selector, Roles.GOVERNANCE);
        _wire(address(cash), cash.withdrawAtAtm.selector, Roles.ATM);
        _wire(address(cash), cash.confirmDispense.selector, Roles.ATM);
        _wire(address(cash), cash.reportFailure.selector, Roles.ATM);
        _wire(address(cash), cash.setLadder.selector, Roles.GOVERNANCE);
        _wire(address(assisted), assisted.setLadder.selector, Roles.GOVERNANCE);
        _wire(address(limits), limits.countMovement.selector, Roles.LIMIT_KEEPER);
        _wire(address(limits), limits.countPayment.selector, Roles.LIMIT_KEEPER);
        _wire(address(limits), limits.enrol.selector, Roles.GOVERNANCE);
        _wire(address(limits), limits.setChannel.selector, Roles.GOVERNANCE);
        _wire(address(limits), limits.setLimits.selector, Roles.GOVERNANCE);
        _wire(address(incidents), incidents.report.selector, Roles.FINANCE);

        manager.grantRole(Roles.LEDGER, address(ledger), 0);
        manager.grantRole(Roles.STAFF_ADMIN, address(staffRoles), 0);
        manager.grantRole(Roles.FREEZER, address(holds), 0);
        manager.grantRole(Roles.BOOKKEEPER, address(payments), 0);
        manager.grantRole(Roles.BOOKKEEPER, address(cash), 0);
        manager.grantRole(Roles.ENFORCER, address(cash), 0);
        manager.grantRole(Roles.ENFORCER, address(assisted), 0);
        manager.grantRole(Roles.LIMIT_KEEPER, address(token), 0);
        manager.grantRole(Roles.LIMIT_KEEPER, address(payments), 0);
        manager.grantRole(Roles.ENFORCER, address(disputes), 0);
        manager.grantRole(Roles.DISPUTE_HOLDER, address(disputes), 0);
        manager.grantRole(Roles.BOOKKEEPER, treasury, 0);
        uint64[] memory staff = _staffAdministered();
        for (uint256 i = 0; i < staff.length; ++i) manager.setRoleAdmin(staff[i], Roles.STAFF_ADMIN);

        token.allowUser(alice);
        token.allowUser(bob);
        token.allowUser(otherCustomers);
        token.allowUser(pending);
        token.allowUser(address(payments));
        token.allowUser(address(cash));
        token.allowUser(address(assisted));

        manager.grantRole(Roles.ADMIN, governance, 0);
        manager.grantRole(Roles.GOVERNANCE, governance, 0);
        manager.renounceRole(Roles.ADMIN, address(this));

        _govern(address(ledger), _openingCall());
        _govern(address(cash), _openCashCall());
        _govern(address(partnerKeys), abi.encodeCall(PartnerKeys.setKey, (CLEARING, _signer(clearingKey))));
        _govern(address(partnerKeys), abi.encodeCall(PartnerKeys.setKey, (CUSTODIAN, _signer(custodianKey))));
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
        return address(new MultiSignerAccount(_verifiers(), _signers(keys), 1, address(0)));
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
        bytes32 digest = MessageHashUtils.toTypedDataHash(_separator(address(account)), structHash);
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

    /// @dev A card's authorisation of `amount` from `customer` to `module`, for the intent whose key is
    /// `key`, under the next one-use number for that intent, valid for an hour.
    function _cardAuthorisation(
        uint256 cardKey,
        address customer,
        address module,
        uint192 key,
        uint256 amount
    ) internal view returns (BranchApprovals.CardAuthorisation memory) {
        bytes32 nonce = bytes32((uint256(key) << 64) | token.nonces(customer, key));
        return
            BranchApprovals.CardAuthorisation(
                customer,
                amount,
                0,
                block.timestamp + 1 hours,
                nonce,
                _cardSignature(cardKey, customer, module, amount, nonce)
            );
    }

    /// @dev A card's P-256 signature over the token's authorisation of a transfer of `amount` from
    /// `account` to `to`, valid for an hour, nested under ERC-7739 for the account that checks it.
    function _cardSignature(uint256 key, address account, address to, uint256 amount, bytes32 nonce) internal view returns (bytes memory) {
        string memory receiveType = "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)";
        bytes32 contents = keccak256(
            abi.encode(keccak256(bytes(receiveType)), account, to, amount, 0, block.timestamp + 1 hours, nonce)
        );
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "TypedDataSign(ReceiveWithAuthorization contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                receiveType
            )
        );
        bytes memory accountDomain = abi.encode(keccak256("MultiSignerAccount"), keccak256("1"), block.chainid, account, bytes32(0));
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            _separator(address(token)),
            keccak256(abi.encodePacked(typehash, contents, accountDomain))
        );
        uint256[] memory keys = new uint256[](1);
        keys[0] = key;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signP256(key, digest);
        return ERC7739Utils.encodeTypedDataSig(abi.encode(_signers(keys), sigs), _separator(address(token)), contents, receiveType);
    }

    /// @dev The EIP-712 domain separator of `signedFor`, from its own ERC-5267 description.
    function _separator(address signedFor) internal view returns (bytes32) {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt, ) = IERC5267(
            signedFor
        ).eip712Domain();
        return MessageHashUtils.toDomainSeparator(fields, name, version, chainId, verifying, salt);
    }

    function _verifiers() internal view returns (address[] memory verifiers) {
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

    /// @dev Cash opens split as 250,000 in the vault, 50,000 in the teller's drawer and 200,000 in the ATM.
    function _openCashCall() private view returns (bytes memory) {
        CashOperations.Location[] memory at = new CashOperations.Location[](3);
        at[0] = _vault(1);
        at[1] = _drawer(1, teller1);
        at[2] = _atm(1, atm1);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 250_000 * HKD;
        amounts[1] = 50_000 * HKD;
        amounts[2] = 200_000 * HKD;
        return abi.encodeCall(CashOperations.openCash, (at, amounts));
    }

    function _vault(uint64 branch) internal pure returns (CashOperations.Location memory) {
        return CashOperations.Location(CashOperations.Place.Vault, branch, address(0));
    }

    function _drawer(uint64 branch, address teller) internal pure returns (CashOperations.Location memory) {
        return CashOperations.Location(CashOperations.Place.Drawer, branch, teller);
    }

    function _atm(uint64 branch, address machine) internal pure returns (CashOperations.Location memory) {
        return CashOperations.Location(CashOperations.Place.Atm, branch, machine);
    }

    function _hkd(int128 amount) internal pure returns (int128) {
        return amount * int128(int256(HKD));
    }

    function _holds(uint64 role, address account) internal view returns (bool member) {
        (member, ) = manager.hasRole(role, account);
    }

    /// @dev Moves the settlement account against securities, as treasury selling or buying them.
    function _moveSettlement(int256 amount) internal {
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](2);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Settlement, int128(amount));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Securities, -int128(amount));
        vm.prank(treasury);
        ledger.post(lines, "treasury");
    }

    function _assertBooksBalance() internal view {
        int256[] memory all = ledger.balances();
        int256 sum;
        for (uint256 i = 0; i < all.length; ++i) sum += all[i];
        assertEq(sum, 0, "assets equal liabilities and equity");
    }
}
