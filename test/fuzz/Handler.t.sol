// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test{
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timeMintIsCalled = 0;

    address[] public senders;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc){
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory collaterals = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collaterals[0]);
        wbtc = ERC20Mock(collaterals[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        console.log(amountCollateral);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        console.log("Helu: ", msg.sender, dscEngine.getAccountCollateralValueInUSD(msg.sender));
        vm.stopPrank();
        
        senders.push(msg.sender);
    }
    
    function redeemCollateral(uint256 collateralSeed, uint256 amountToRedeem) public{
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountToRedeem = bound(amountToRedeem, 0, dscEngine.getCollateralAmountOfaUser(address(collateral), msg.sender));
        if (amountToRedeem == 0){
            return;
        }

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountToRedeem);
        vm.stopPrank();

    }

    function mintDsc(uint256 amount, uint256 addressSeed) public{
        if (senders.length == 0){
            return;
        }

        address sender = senders[addressSeed % senders.length];
        vm.startPrank(sender);

        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(sender);
        uint256 maxAmountToMint = (collateralValueInUSD / 2) - totalDscMinted;
        if (maxAmountToMint < 0){
            return;
        }

        amount = bound(amount, 0, maxAmountToMint);
        if (amount == 0){
            return;
        }
        dscEngine.mintDsc(amount);
        vm.stopPrank();

        ++timeMintIsCalled;
    }

    // function updateCollateralPrice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock){
        if (collateralSeed % 2 == 0) return weth;
        return wbtc;
    }



}