// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* @title DecentralizedStableCoin
 * @author Duc Anh Le
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral type: Crypto
 * 
 * This contract meant to be owned by DSCEngine. It is an ERC20 token that can be minted and burned by the DSCEngine Smart Contract
*/

contract DecentralizedStableCoin is ERC20Burnable, Ownable{
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("a", "b") Ownable() {

    }

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0){
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount){
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool){
        if (_to == address(0)){
            revert DecentralizedStableCoin__NotZeroAddress();
        }

        if (_amount <= 0){
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;

    }
}

