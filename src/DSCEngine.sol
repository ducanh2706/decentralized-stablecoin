// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";
// import ""

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

/**
 * @title DSCEngine
 * @author DucAnhLe
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 peg
 * This stable has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algoritmtically Stable
 * 
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC
 * 
 * Our DSC System should always be
 * @notice This contract is the core of the DSC System. It handles all the logic for 
 * mining and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely based on MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard{

    ////////////////////
    //// ERRORS        /
    //////////////////// 
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////
    //// TYPES /       /
    //////////////////// 

    using OracleLib for AggregatorV3Interface;

    /////////////////////
    //// STATE VARIABLEs/
    /////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) public s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;


    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////
    //// EVENTS         /
    /////////////////////

    event CollateralDeposited(address indexed user, address indexed tokenAddress, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed tokenAddress, uint256 amount);
    ////////////////////
    //// MODIFIERS /////
    ////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token){
        if (s_priceFeeds[token] == address(0)){
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////
    //// FUNCTIONS     /
    //////////////////// 

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedAddress.length){
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // USD Price Feed: ETH/USD, BTC/USD

        for (uint256 i = 0; i < tokenAddress.length; i++){
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }



    ////////////////////
    //// EXTERNAL      /
    //////////////////// 

    /**
     * 
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral  The amount of collateral to deposit
     * @param amountDscToMint  The amount of Dsc want to mint
     * @notice User can deposit collateral and mint stablecoin in one transactions.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * 
     * @param tokenCollateralAddress The address of the collateral token to redeem 
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC want to burn
     * @notice This function first burn DSC then redeem Collateral in 1 transaction.
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral, uint256 
        amountDscToBurn
    ) external {
         _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    function liquidate(address collateral, address user, uint256 debtToCover) 
        external moreThanZero(debtToCover) nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(user, msg.sender, collateral, tokenAmountFromDebtCovered + bonusCollateral);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
        
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        external moreThanZero(amountCollateral) nonReentrant
    {
        // redeem khi nào? Khi nào trả hết nợ hoặc tiền collateral nó ko bị xuống dưới mức threshold so với
        // số tiền mình đã mint?
        // 1. Health factor must be over 1 AFTER COLLATERAL PULL

        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i don't think this would be ever reached
    }


    function getHealthFactor() external view {

    }




    //////////////////////////////
    //// PUBLIC     /
    //////////////////// /////////

    /**
     * @notice follow CEIS (check, effect, interact)
     * @param tokenCollateralAddress address of the collateral token
     * @param amountCollateral amount to deposit
    */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant{
        // effect
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // interact
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     * @notice follow CEI (Check, effect, interact)
     * @param amountDscToMint amount of DSC token user wants to mint
     * @notice They must have more collateral value than the threshold value
     */
    function mintDsc(uint256 amountDscToMint) public {
        s_DscMinted[msg.sender] += amountDscToMint;
        // if they minted too much
        // revert if health factor is broken
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted){
            revert DSCEngine__MintFailed();
        }
    }


    //////////////////////////////
    //// PRIVATE + INTERNAL      /
    //////////////////// /////////

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private{
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /**
     * 
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUSD){
        totalDscMinted = s_DscMinted[user];
        collateralValueInUSD = getAccountCollateralValueInUSD(user);
        return (totalDscMinted, collateralValueInUSD);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view{
        // 1. Check health factor (has enough collateral)
        // 2. revert if bad
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }

    }



    ////////////////////////////////////////////
    //// Public and external view function     /
    ///////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
    
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUSD(address user) public view returns(uint256 totalCollateralValueInUSD){
        // loop through each collateral token, get amount -> map to price
        for (uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUsdValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUSD){
        return _getAccountInformation(user);
    }

    function getCollateralAmountOfaUser(address token, address user) public view isAllowedToken(token) returns (uint256 amount){
        amount = s_collateralDeposited[user][token];
    }
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}