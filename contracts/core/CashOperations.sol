// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccountRecovery} from "./AccountRecovery.sol";
import {BranchApprovals} from "./BranchApprovals.sol";
import {DailyLimit} from "./DailyLimit.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {Roles} from "./Roles.sol";

/// @dev The cash module: cash taken in at the counter, paid out at the ATM, moved between the vault,
/// the tellers' drawers and the ATMs, and counted. The ledger keeps one cash account; the module
/// keeps how it splits between those places, always summing to it. A deposit is posted by a teller
/// of the branch, within the drawer limit. An ATM withdrawal is the customer's card authorisation,
/// an EIP-3009 transfer to this module, which holds the amount as the pending account until the ATM
/// confirms the dispense, reports a failure, or neither by the dispense timeout, when it is flagged
/// and settled at that machine's next count. Moving cash, banking the surplus and counting are each
/// recorded by the branch's vault custodian and confirmed by another person, a supervisor of the
/// branch, as a bank keeps cash under dual control. A count that differs posts nothing and marks the
/// place's figure unmatched. A withdrawal at the counter climbs the branch approval ladder, and is
/// paid out of the teller's drawer once approved. See open questions 17 and 19 in docs/plan.md.
contract CashOperations is BranchApprovals {
    using DailyLimit for DailyLimit.Limiter;
    using SafeCast for uint256;
    using SafeCast for int256;

    bytes32 public constant ATM_CHANNEL = "atm";
    /// @dev The purposes a customer's authorisation is given for: a withdrawal at one ATM, or at the
    /// counter of one branch.
    bytes32 public constant ATM_WITHDRAWAL = "atm withdrawal";
    bytes32 public constant COUNTER_WITHDRAWAL = "counter withdrawal";

    enum Place {
        Vault,
        Drawer,
        Atm
    }

    /// @dev Where cash is held: a branch's vault, or a teller's drawer or an ATM at that branch.
    struct Location {
        Place place;
        uint64 branch;
        address holder;
    }

    struct Limits {
        uint256 drawer;
        uint256 atm;
        uint256 cashReport;
        uint256 dispenseTimeout;
    }

    enum WithdrawalStatus {
        None,
        Held,
        Dispensed,
        Returned
    }

    struct Withdrawal {
        address customer;
        uint48 heldAt;
        WithdrawalStatus status;
        address atm;
        bytes32 location;
        uint256 amount;
    }

    enum OrderKind {
        None,
        Move,
        Bank,
        Count
    }

    /// @dev A move, banking or count waiting for its supervisor. A count's `amount` is what was counted.
    struct Order {
        OrderKind kind;
        address maker;
        uint64 branch;
        bytes32 from;
        bytes32 to;
        uint256 amount;
    }

    struct CountResult {
        uint256 counted;
        uint256 book;
        uint48 at;
        bool matched;
    }

    GeneralLedger public immutable ledger;

    Limits public limits;
    bool public opened;
    uint256 public orderCount;
    mapping(bytes32 location => uint256) public cashAt;
    /// @dev ATM withdrawals held and not yet confirmed, failed or settled, per machine.
    mapping(bytes32 location => uint256) public inFlight;
    mapping(bytes32 location => CountResult) private _counts;
    mapping(bytes32 location => bytes32[]) private _held;
    mapping(bytes32 ref => Withdrawal) private _withdrawals;
    mapping(uint256 id => Order) private _orders;
    DailyLimit.Limiter private _atmLimit;

    event CashOpened(bytes32 indexed location, uint256 amount);
    event CashDeposited(bytes32 indexed ref, address indexed customer, address indexed teller, bytes32 location, uint256 amount);
    /// @dev Compliance is told of cash paid in or out at the counter at or above the cash report threshold.
    event CashReported(bytes32 indexed ref, address indexed customer, uint256 amount);
    event WithdrawalHeld(bytes32 indexed ref, address indexed customer, address indexed atm, uint256 amount);
    event WithdrawalDispensed(bytes32 indexed ref, address indexed customer, uint256 amount, bool atCount);
    event WithdrawalReturned(bytes32 indexed ref, address indexed customer, uint256 amount, bool atCount);
    event OrderProposed(uint256 indexed id, OrderKind kind, address indexed maker, bytes32 from, bytes32 to, uint256 amount);
    event OrderCancelled(uint256 indexed id);
    event CashMoved(uint256 indexed id, bytes32 indexed from, bytes32 indexed to, uint256 amount, address maker, address approver);
    event CashBanked(uint256 indexed id, bytes32 indexed ref, bytes32 from, uint256 amount, address maker, address approver);
    event CashCounted(
        uint256 indexed id,
        bytes32 indexed location,
        uint256 counted,
        uint256 book,
        bool matched,
        address maker,
        address approver
    );
    event LimitsSet(Limits limits);

    error AlreadyOpened();
    error OpeningMismatch(uint256 split, int256 ledgerCash);
    error InvalidLocation(Location location);
    error OtherBranch(uint64 branch, uint64 otherBranch);
    error NotCustodian(address caller, uint64 branch);
    error NotSupervisor(address caller, uint64 branch);
    error NotMaker(address caller, uint256 id);
    error ApproverIsMaker(address approver);
    error NoSuchOrder(uint256 id);
    error DrawerLimit(uint256 inDrawer, uint256 amount, uint256 limit);
    error InsufficientCash(bytes32 location, uint256 available, uint256 amount);
    error NotHeld(bytes32 ref, WithdrawalStatus status);
    error NotItsAtm(bytes32 ref, address caller);
    error DispenseTimedOut(bytes32 ref);
    error DispenseInProgress(bytes32 ref);

    constructor(
        address manager,
        GeneralLedger ledger_,
        Limits memory limits_,
        AccountRecovery recovery_,
        Ladder memory ladder_
    ) BranchApprovals(manager, ledger_.token(), recovery_, ladder_) {
        ledger = ledger_;
        limits = limits_;
    }

    // Views

    function locationId(Location memory l) public pure returns (bytes32) {
        return keccak256(abi.encode(l.place, l.branch, l.holder));
    }

    function withdrawal(bytes32 ref) external view returns (Withdrawal memory) {
        return _withdrawals[ref];
    }

    function order(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    function lastCount(bytes32 location) external view returns (CountResult memory) {
        return _counts[location];
    }

    /// @dev Held past the dispense timeout with neither a confirmation nor a reported failure, so it
    /// waits for the machine's next count.
    function isFlagged(bytes32 ref) public view returns (bool) {
        Withdrawal storage w = _withdrawals[ref];
        return w.status == WithdrawalStatus.Held && block.timestamp > w.heldAt + limits.dispenseTimeout;
    }

    /// @dev What the customer may still withdraw at ATMs today.
    function atmAvailable(address customer) external view returns (uint256) {
        return _atmLimit.available(_atmKey(customer), limits.atm);
    }

    // Governance

    /// @dev Splits the opening balance sheet's cash between its places, once. The split must sum to
    /// the ledger's cash account.
    function openCash(Location[] calldata locations, uint256[] calldata amounts) external restricted {
        if (opened) revert AlreadyOpened();
        uint256 sum;
        for (uint256 i = 0; i < locations.length; ++i) {
            bytes32 id = _checkLocation(locations[i]);
            cashAt[id] += amounts[i];
            sum += amounts[i];
            emit CashOpened(id, amounts[i]);
        }
        int256 ledgerCash = ledger.balanceOf(GeneralLedger.Account.Cash);
        if (sum.toInt256() != ledgerCash) revert OpeningMismatch(sum, ledgerCash);
        opened = true;
    }

    function setLimits(Limits calldata limits_) external restricted {
        limits = limits_;
        emit LimitsSet(limits_);
    }

    // At the counter

    /// @dev A teller of `branch` takes cash into their drawer and the customer's deposit is created
    /// against it. Refused over the drawer limit; at or above the cash report threshold compliance is
    /// told, and the deposit still goes through.
    function deposit(uint64 branch, address customer, uint256 amount) external returns (bytes32 ref) {
        _requireTeller(branch);
        if (amount == 0) revert ZeroAmount();
        bytes32 drawer = locationId(Location(Place.Drawer, branch, msg.sender));
        uint256 inDrawer = cashAt[drawer];
        if (inDrawer + amount > limits.drawer) revert DrawerLimit(inDrawer, amount, limits.drawer);

        ref = _nextRef();
        cashAt[drawer] = inDrawer + amount;
        ledger.postWithMint(customer, amount, _cash(_signed(amount)), ref);
        emit CashDeposited(ref, customer, msg.sender, drawer, amount);
        if (amount >= limits.cashReport) emit CashReported(ref, customer, amount);
    }

    // At the ATM

    /// @dev An enrolled ATM at `branch` submits the customer's card authorisation: the amount moves
    /// from the customer to this module and waits for the dispense. Refused over the customer's ATM
    /// limit for the day, or beyond what the machine holds less what is already on its way out.
    function withdrawAtAtm(uint64 branch, CardAuthorisation calldata card) external restricted returns (bytes32 ref) {
        if (card.amount == 0) revert ZeroAmount();
        bytes32 atm = locationId(Location(Place.Atm, branch, msg.sender));
        _checkFree(atm, card.amount);
        _atmLimit.consume(_atmKey(card.customer), card.amount, limits.atm);

        ref = _nextRef();
        inFlight[atm] += card.amount;
        _withdrawals[ref] = Withdrawal(
            card.customer,
            block.timestamp.toUint48(),
            WithdrawalStatus.Held,
            msg.sender,
            atm,
            card.amount
        );
        _held[atm].push(ref);
        _receive(card, intentKey(ATM_WITHDRAWAL, branch, msg.sender));
        emit WithdrawalHeld(ref, card.customer, msg.sender, card.amount);
    }

    /// @dev The ATM dispensed: the held tokens are destroyed against the machine's cash.
    function confirmDispense(bytes32 ref) external restricted {
        _dispense(_heldBy(ref), ref, false);
    }

    /// @dev The ATM failed to dispense: the amount goes back to the customer, and back on their limit.
    function reportFailure(bytes32 ref) external restricted {
        _return(_heldBy(ref), ref, false);
    }

    /// @dev A teller of `branch` opens a withdrawal at the counter on the customer's device or card. It
    /// is paid out of the teller's drawer once the approvers the ladder names have approved, and
    /// compliance is told of one at or above the cash report threshold.
    function withdrawAtCounter(uint64 branch, CardAuthorisation calldata authorisation) external returns (bytes32 ref) {
        _checkDrawer(branch, authorisation.amount);
        ref = _openSigned(branch, COUNTER_WITHDRAWAL, address(0), 0, authorisation);
        _reportCash(ref, authorisation.customer, authorisation.amount);
    }

    /// @dev A teller of `branch` opens a withdrawal at the counter on the customer's signed paper slip.
    function withdrawAtCounterOnPaper(uint64 branch, address customer, uint256 amount, bytes32 slipHash) external returns (bytes32 ref) {
        _checkDrawer(branch, amount);
        ref = _openOnPaper(branch, customer, address(0), 0, amount, slipHash);
        _reportCash(ref, customer, amount);
    }

    /// @dev The teller's drawer must hold the cash when the withdrawal opens, and again when it is paid.
    function _checkDrawer(uint64 branch, uint256 amount) private view {
        _checkFree(locationId(Location(Place.Drawer, branch, msg.sender)), amount);
    }

    function _reportCash(bytes32 ref, address customer, uint256 amount) private {
        if (amount >= limits.cashReport) emit CashReported(ref, customer, amount);
    }

    /// @dev Pays the withdrawal out of the drawer of the teller who opened it, which must hold the cash.
    function _carryOut(bytes32 ref, Operation storage op) internal override {
        bytes32 drawer = locationId(Location(Place.Drawer, op.branch, op.teller));
        _take(drawer, op.amount);
        ledger.postWithBurn(address(this), op.amount, _cash(-_signed(op.amount)), ref);
    }

    // Under dual control

    /// @dev The branch's vault custodian moves cash between two of its places.
    function proposeMove(Location calldata from, Location calldata to, uint256 amount) external returns (uint256) {
        if (from.branch != to.branch) revert OtherBranch(from.branch, to.branch);
        return _propose(OrderKind.Move, from.branch, _checkLocation(from), _checkLocation(to), amount);
    }

    /// @dev The branch's vault custodian banks surplus cash from the vault to the settlement account.
    function proposeBanking(uint64 branch, uint256 amount) external returns (uint256) {
        bytes32 vault = _checkLocation(Location(Place.Vault, branch, address(0)));
        return _propose(OrderKind.Bank, branch, vault, 0, amount);
    }

    /// @dev The branch's vault custodian records what one place holds.
    function proposeCount(Location calldata at, uint256 counted) external returns (uint256) {
        return _propose(OrderKind.Count, at.branch, _checkLocation(at), 0, counted);
    }

    /// @dev A supervisor of the order's branch, other than its maker, confirms it and it takes effect.
    function confirmOrder(uint256 id) external {
        Order memory o = _orders[id];
        if (o.kind == OrderKind.None) revert NoSuchOrder(id);
        if (msg.sender == o.maker) revert ApproverIsMaker(msg.sender);
        if (!_has(Roles.atBranch(o.branch, Roles.SUPERVISOR), msg.sender)) revert NotSupervisor(msg.sender, o.branch);
        if (!_has(Roles.atBranch(o.branch, Roles.VAULT_CUSTODIAN), o.maker)) revert NotCustodian(o.maker, o.branch);
        delete _orders[id];

        if (o.kind == OrderKind.Move) {
            _take(o.from, o.amount);
            cashAt[o.to] += o.amount;
            emit CashMoved(id, o.from, o.to, o.amount, o.maker, msg.sender);
        } else if (o.kind == OrderKind.Bank) {
            _take(o.from, o.amount);
            GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](2);
            lines[0] = GeneralLedger.Line(GeneralLedger.Account.Cash, -_signed(o.amount));
            lines[1] = GeneralLedger.Line(GeneralLedger.Account.Settlement, _signed(o.amount));
            bytes32 ref = _nextRef();
            ledger.post(lines, ref);
            emit CashBanked(id, ref, o.from, o.amount, o.maker, msg.sender);
        } else {
            _count(id, o, msg.sender);
        }
    }

    function cancelOrder(uint256 id) external {
        Order storage o = _orders[id];
        if (o.kind == OrderKind.None) revert NoSuchOrder(id);
        if (o.maker != msg.sender) revert NotMaker(msg.sender, id);
        delete _orders[id];
        emit OrderCancelled(id);
    }

    // Internal

    function _propose(OrderKind kind, uint64 branch, bytes32 from, bytes32 to, uint256 amount) private returns (uint256 id) {
        if (!_has(Roles.atBranch(branch, Roles.VAULT_CUSTODIAN), msg.sender)) revert NotCustodian(msg.sender, branch);
        if (amount == 0 && kind != OrderKind.Count) revert ZeroAmount();
        id = ++orderCount;
        _orders[id] = Order(kind, msg.sender, branch, from, to, amount);
        emit OrderProposed(id, kind, msg.sender, from, to, amount);
    }

    /// @dev Settles the place's flagged withdrawals against its shortfall in the order they were held:
    /// each the shortfall covers was dispensed, the rest were not and go back to their customers. Any
    /// difference left marks the place's figure unmatched, posting nothing. A machine is not counted
    /// while a dispense is still within its timeout, as the cash it is paying out would show as a
    /// difference; a bank takes the machine out of service to count it. A customer blocked since
    /// withdrawing cannot be paid back, so that withdrawal waits for the next count. The held list
    /// is only compacted here, so it grows with a machine's withdrawals between counts, which a bank
    /// makes at every refill.
    function _count(uint256 id, Order memory o, address approver) private {
        bytes32 at = o.from;
        uint256 shortfall = o.amount < cashAt[at] ? cashAt[at] - o.amount : 0;
        bytes32[] storage held = _held[at];
        uint256 kept;
        for (uint256 i = 0; i < held.length; ++i) {
            bytes32 ref = held[i];
            Withdrawal storage w = _withdrawals[ref];
            if (w.status != WithdrawalStatus.Held) continue;
            if (!isFlagged(ref)) revert DispenseInProgress(ref);
            if (w.amount <= shortfall) {
                shortfall -= w.amount;
                _dispense(w, ref, true);
            } else if (token.canTransact(w.customer)) {
                _return(w, ref, true);
            } else {
                held[kept++] = ref;
            }
        }
        while (held.length > kept) held.pop();

        uint256 book = cashAt[at];
        bool matched = o.amount == book;
        _counts[at] = CountResult(o.amount, book, block.timestamp.toUint48(), matched);
        emit CashCounted(id, at, o.amount, book, matched, o.maker, approver);
    }

    function _dispense(Withdrawal storage w, bytes32 ref, bool atCount) private {
        w.status = WithdrawalStatus.Dispensed;
        (bytes32 location, uint256 amount) = (w.location, w.amount);
        inFlight[location] -= amount;
        cashAt[location] -= amount;
        ledger.postWithBurn(address(this), amount, _cash(-_signed(amount)), ref);
        emit WithdrawalDispensed(ref, w.customer, amount, atCount);
    }

    /// @dev A customer blocked since withdrawing cannot be paid back, so a failure reported for one
    /// waits until compliance lifts the block, as a rejected payment does.
    function _return(Withdrawal storage w, bytes32 ref, bool atCount) private {
        w.status = WithdrawalStatus.Returned;
        inFlight[w.location] -= w.amount;
        _atmLimit.release(_atmKey(w.customer), w.amount, DailyLimit.dayOf(w.heldAt));
        token.transfer(w.customer, w.amount);
        emit WithdrawalReturned(ref, w.customer, w.amount, atCount);
    }

    /// @dev A withdrawal still held, reported on by the ATM that took it, within the dispense timeout.
    function _heldBy(bytes32 ref) private view returns (Withdrawal storage w) {
        w = _withdrawals[ref];
        if (w.status != WithdrawalStatus.Held) revert NotHeld(ref, w.status);
        if (w.atm != msg.sender) revert NotItsAtm(ref, msg.sender);
        if (isFlagged(ref)) revert DispenseTimedOut(ref);
    }

    /// @dev Takes cash out of a place, leaving what an ATM still has on its way out.
    function _take(bytes32 location, uint256 amount) private {
        _checkFree(location, amount);
        cashAt[location] -= amount;
    }

    function _checkFree(bytes32 location, uint256 amount) private view {
        uint256 free = cashAt[location] - inFlight[location];
        if (amount > free) revert InsufficientCash(location, free, amount);
    }

    function _checkLocation(Location memory l) private pure returns (bytes32) {
        bool vault = l.place == Place.Vault;
        if (l.branch == 0 || vault != (l.holder == address(0))) revert InvalidLocation(l);
        return locationId(l);
    }

    function _atmKey(address customer) private pure returns (bytes32) {
        return keccak256(abi.encode(customer, ATM_CHANNEL));
    }

    function _signed(uint256 amount) private pure returns (int128) {
        return amount.toInt256().toInt128();
    }

    function _cash(int128 amount) private pure returns (GeneralLedger.Line[] memory lines) {
        lines = new GeneralLedger.Line[](1);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Cash, amount);
    }
}
