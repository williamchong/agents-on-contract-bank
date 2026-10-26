// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @dev The bank's rates, as a bank prices its products. Treasury proposes the savings and loan rates and
/// risk the loss allowance rates, each with the hash of the paper that argues for them, and the proposal
/// waits here until governance applies it, through its signatures and time lock, which stand for the
/// notice a bank gives before a rate changes. Governance applies a proposal by its paper, so one replaced
/// while governance waits is not the one it applies. A rate applies from then on; a loan keeps the rate it
/// was proposed at. See open questions 24 and 28 in docs/plan.md.
contract Rates is AccessManaged {
    uint256 private constant BPS = 10_000;

    /// @dev The savings and loan rates a year, in basis points.
    struct ProductRates {
        uint256 savingsBps;
        uint256 loanBps;
    }

    /// @dev The loss allowance on a loan performing, in arrears and in default, in basis points of what
    /// is outstanding.
    struct AllowanceRates {
        uint256 performingBps;
        uint256 arrearsBps;
        uint256 defaultBps;
    }

    ProductRates public products;
    AllowanceRates public allowance;
    ProductRates public proposedProducts;
    AllowanceRates public proposedAllowance;
    /// @dev The paper each pending proposal rests on, zero while none waits.
    bytes32 public productsPaper;
    bytes32 public allowancePaper;

    event ProductRatesProposed(bytes32 indexed paper, address indexed by, ProductRates rates);
    event AllowanceRatesProposed(bytes32 indexed paper, address indexed by, AllowanceRates rates);
    event ProductRatesApplied(bytes32 indexed paper, ProductRates rates);
    event AllowanceRatesApplied(bytes32 indexed paper, AllowanceRates rates);

    error RateAboveWhole(uint256 bps);
    error NoPaper();
    error NotThePaperProposed(bytes32 paper, bytes32 proposed);

    constructor(address manager, ProductRates memory products_, AllowanceRates memory allowance_) AccessManaged(manager) {
        _checkProducts(products_);
        _checkAllowance(allowance_);
        products = products_;
        allowance = allowance_;
        emit ProductRatesApplied(bytes32(0), products_);
        emit AllowanceRatesApplied(bytes32(0), allowance_);
    }

    function proposeProductRates(ProductRates calldata rates, bytes32 paper) external restricted {
        _checkProducts(rates);
        if (paper == bytes32(0)) revert NoPaper();
        (proposedProducts, productsPaper) = (rates, paper);
        emit ProductRatesProposed(paper, msg.sender, rates);
    }

    function proposeAllowanceRates(AllowanceRates calldata rates, bytes32 paper) external restricted {
        _checkAllowance(rates);
        if (paper == bytes32(0)) revert NoPaper();
        (proposedAllowance, allowancePaper) = (rates, paper);
        emit AllowanceRatesProposed(paper, msg.sender, rates);
    }

    function applyProductRates(bytes32 paper) external restricted {
        _checkProposed(paper, productsPaper);
        ProductRates memory rates = proposedProducts;
        products = rates;
        delete proposedProducts;
        delete productsPaper;
        emit ProductRatesApplied(paper, rates);
    }

    function applyAllowanceRates(bytes32 paper) external restricted {
        _checkProposed(paper, allowancePaper);
        AllowanceRates memory rates = proposedAllowance;
        allowance = rates;
        delete proposedAllowance;
        delete allowancePaper;
        emit AllowanceRatesApplied(paper, rates);
    }

    function _checkProposed(bytes32 paper, bytes32 proposed) private pure {
        if (paper == bytes32(0) || paper != proposed) revert NotThePaperProposed(paper, proposed);
    }

    function _checkProducts(ProductRates memory rates) private pure {
        _checkBps(rates.savingsBps);
        _checkBps(rates.loanBps);
    }

    function _checkAllowance(AllowanceRates memory rates) private pure {
        _checkBps(rates.performingBps);
        _checkBps(rates.arrearsBps);
        _checkBps(rates.defaultBps);
    }

    function _checkBps(uint256 bps) private pure {
        if (bps > BPS) revert RateAboveWhole(bps);
    }
}
