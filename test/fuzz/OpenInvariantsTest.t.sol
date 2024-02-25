// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantTest is StdInvariant, Test{
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;

//     address weth;
//     address wbtc;

//     function setUp() external{
//         deployer = new DeployDSC();
//         (dsc, dscEngine, helperConfig) = deployer.run();
//         (,,weth,wbtc,) = helperConfig.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view{
//         uint256 totalSupply = dsc.totalSupply();

//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWethDeposited);

//         assert(wethValue + wbtcValue >= totalSupply);

//     }
// }