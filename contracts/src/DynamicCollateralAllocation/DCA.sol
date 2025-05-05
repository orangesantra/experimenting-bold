
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import ".././Dependencies/Ownable.sol";
import "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin/contracts/token/ERC20/IERC20.sol";
import "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {AutomationCompatibleInterface} from "contracts/lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

/**
 * @title Dynamic Collateral Optimizer
 * @notice Automatically manages and optimizes collateral positions in Bold Protocol
 * @dev Integrates with Bold Protocol to rebalance collateral for optimal yield and safety
 */
    // ============ Interfaces ============
    // @notice - using interfaces directly instead of importing for making it compatible with remix as well.
    interface ITroveNFT is IERC721Metadata {
        function mint(address _owner, uint256 _troveId) external;
        function burn(uint256 _troveId) external;
    }
    interface IAddressesRegistry {
        function troveManager() external view returns (address);
        function troveNFT() external view returns (address);
        function borrowerOperations() external view returns (address);
        function priceFeed() external view returns (address);
        function activePool() external view returns (address);
        function collToken() external view returns (address);
    }

    interface ITroveManager {
        struct LatestTroveData {
            uint256 entireDebt;
            uint256 entireColl;
            uint256 recordedDebt;
            uint256 accruedInterest;
            uint256 accruedBatchManagementFee;
            uint256 redistBoldDebtGain;
            uint256 redistCollGain;
            uint256 weightedRecordedDebt;
            uint256 annualInterestRate;
            uint64 lastInterestRateAdjTime;
        }

        function getCurrentICR(uint256 _troveId, uint256 _price) external view returns (uint256);
        function getTroveStatus(uint256 _troveId) external view returns (uint256);
        function getTroveDebt(uint256 _troveId) external view returns (uint256);
        function getTroveColl(uint256 _troveId) external view returns (uint256);
        function getTroveInterestRate(uint256 _troveId) external view returns (uint256);
    }

    interface IBorrowerOperations {
        function adjustTrove(
            uint256 _troveId,
            uint256 _collChange,
            bool _isCollIncrease,
            uint256 _boldChange,
            bool _isDebtIncrease,
            uint256 _maxFeePercentage,
            uint256 _newInterestRate,
            uint256 _senderAddress,
            address _batchAddress,
            address _interestRateAdjuster,
            address _receiverAddress
        ) external;
        
        function openTrove(
            address _borrower,
            uint256 _troveId,
            uint256 _collAmount,
            uint256 _boldAmount,
            uint256 _maxFeePercentage,
            uint256 _newInterestRate,
            uint256 _upperHint,
            uint256 _lowerHint,
            address _batchAddress,
            address _interestRateAdjuster,
            address _receiverAddress
        ) external returns (uint256);
    }

    interface IPriceFeed {
        function fetchPrice() external returns (uint256, bool);
    }

    // Yield oracle interfaces
    interface IYieldOracle {
        function getCollateralYield(address _collateral) external view returns (uint256 yield);
        function getSupportedCollateral() external view returns (address[] memory);
    }

    interface ISwapRouter {
        function swapExactTokensForTokens(
            uint256 amountIn,
            uint256 amountOutMin,
            address[] calldata path,
            address to,
            uint256 deadline
        ) external returns (uint256[] memory amounts);
    }
contract DynamicCollateralOptimizer is Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct OptimizationStrategy {
        uint256 targetLTV;          // Target Loan-to-Value ratio (in bps, e.g. 7000 = 70%)
        uint256 riskTolerance;      // 1-10 scale of risk preference
        bool yieldPrioritized;      // Whether yield is prioritized over stability
        uint256 rebalanceThreshold; // Minimum benefit required to trigger rebalance (in bps)
        address[] allowedCollaterals; // List of collateral tokens this strategy can use
    }

    struct TroveData {
        address owner;
        uint256 debt;
        uint256 coll;
        uint256 interestRate;
        uint8 status;
        address collateralType;
    }

    struct CollateralAllocation {
        address token;
        uint256 amount;
        uint256 yield;
        uint256 volatilityScore; // Higher = more volatile
    }

    struct SwapOperation {
        address fromToken;
        address toToken;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    uint256 public constant BASIS_POINTS = 10000; // 100% in basis points
    uint256 public constant MIN_REBALANCE_THRESHOLD = 50; // 0.5% minimum threshold
    uint256 public constant SAFETY_MARGIN = 500; // 5% safety margin above MCR
    uint256 public constant MCR = 11000; // 110% Minimum Collateralization Ratio in bps

    uint32 public lastCalled_global; // Last time the optimizer function is called.

    IAddressesRegistry public registry;
    ITroveManager public troveManager;
    IBorrowerOperations public borrowerOperations;
    IPriceFeed public priceFeed;
    IYieldOracle public yieldOracle;
    ISwapRouter public swapRouter;
    ITroveNFT public troveNFT;

    // User strategies and permissions
    mapping(address => OptimizationStrategy) public userStrategies;
    mapping(address => bool) public isUserActive;
    mapping(uint256 => address) public troveToUser;
    mapping(address => uint256[]) public userTroves;

    // Protocol config
    uint256 public protocolFeePercent; // In basis points
    address public feeCollector;
    uint256 public lastRebalanceTimestamp;
    uint256 public minTimeBetweenRebalances;
    
    bool public emergencyShutdown;

    // ============ Events ============

    event StrategyCreated(address indexed user, uint256 targetLTV, uint256 riskTolerance);
    event TroveOptimized(uint256 indexed troveId, address owner, address fromCollateral, address toCollateral, uint256 amount);
    event TroveRegistered(uint256 indexed troveId, address indexed owner);
    event TroveUnregistered(uint256 indexed troveId, address indexed owner);
    event EmergencyShutdown(bool active);
    event ProtocolFeeChanged(uint256 newFee);

    // ============ Constructor ============

    constructor(
        address _registry,
        address _yieldOracle,
        address _swapRouter,
        uint256 _protocolFeePercent,
        address _feeCollector,
        uint256 _minTimeBetweenRebalances
    ) {
        troveNFT = ITroveNFT(IAddressesRegistry(_registry).troveNFT());

        registry = IAddressesRegistry(_registry);
        yieldOracle = IYieldOracle(_yieldOracle);
        swapRouter = ISwapRouter(_swapRouter);
        
        // Initialize Bold Protocol interfaces
        troveManager = ITroveManager(registry.troveManager());
        borrowerOperations = IBorrowerOperations(registry.borrowerOperations());
        priceFeed = IPriceFeed(registry.priceFeed());
        
        // Set protocol parameters
        protocolFeePercent = _protocolFeePercent;
        feeCollector = _feeCollector;
        minTimeBetweenRebalances = _minTimeBetweenRebalances;
    }

    // ============ Modifiers ============

    modifier onlyTroveOwner(uint256 _troveId) {
        require(troveToUser[_troveId] == msg.sender, "DCO: Not trove owner");
        _;
    }

    modifier whenNotShutdown() {
        require(!emergencyShutdown, "DCO: Protocol is in emergency shutdown");
        _;
    }

    modifier validRebalanceTiming() {
        require(
            block.timestamp >= lastRebalanceTimestamp + minTimeBetweenRebalances,
            "DCO: Too soon to rebalance"
        );
        _;
    }

    // ============ Chainlink Automation ============
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        // @notice - currently, it's been set to 1 hour, though the idea is make to dynamic, may be in future.
        upkeepNeeded = (block.timestamp - lastCalled_global) >= 1 hours;
    }

    // TODO : need to figure out how to pass all the troves, either need to create new manager
    // contract or need to modify optmizeCollateral function to accept multiple trove ids.
    function performUpkeep(bytes calldata /* performData */, uint256 _troveId) external {
        if ((block.timestamp - lastCalled_global) > 1 hours) {
            optimizeCollateral(_troveId);
        }
    }

    // ============ User Strategy Management ============

    /**
     * @notice Creates or updates a user's optimization strategy
     * @param _targetLTV Target loan-to-value ratio (in basis points)
     * @param _riskTolerance Risk tolerance on scale of 1-10
     * @param _yieldPrioritized Whether yield is prioritized over stability
     * @param _rebalanceThreshold Minimum benefit to trigger rebalance (in bps)
     * @param _allowedCollaterals Array of allowed collateral token addresses
     */
    function setUserStrategy(
        uint256 _targetLTV,
        uint256 _riskTolerance,
        bool _yieldPrioritized,
        uint256 _rebalanceThreshold,
        address[] calldata _allowedCollaterals
    ) external {
        require(_targetLTV <= 9000, "DCO: LTV too high"); // Max 90% LTV
        require(_targetLTV >= 5000, "DCO: LTV too low");  // Min 50% LTV
        require(_riskTolerance >= 1 && _riskTolerance <= 10, "DCO: Invalid risk tolerance");
        require(_rebalanceThreshold >= MIN_REBALANCE_THRESHOLD, "DCO: Threshold too low");
        require(_allowedCollaterals.length > 0, "DCO: No collaterals specified");
        
        // Verify all collaterals are supported
        for (uint i = 0; i < _allowedCollaterals.length; i++) {
            require(_isCollateralSupported(_allowedCollaterals[i]), "DCO: Unsupported collateral");
        }
        
        userStrategies[msg.sender] = OptimizationStrategy({
            targetLTV: _targetLTV,
            riskTolerance: _riskTolerance,
            yieldPrioritized: _yieldPrioritized,
            rebalanceThreshold: _rebalanceThreshold,
            allowedCollaterals: _allowedCollaterals
        });
        
        isUserActive[msg.sender] = true;
        
        emit StrategyCreated(msg.sender, _targetLTV, _riskTolerance);
    }

    /**
     * @notice Register a trove to be managed by the optimizer
     * @param _troveId The ID of the trove to register
     */
    function registerTrove(uint256 _troveId) external {
        require(isUserActive[msg.sender], "DCO: No active strategy");
        
        // Verify trove ownership
        address owner1 = troveNFT.ownerOf(_troveId);
        uint256 status = troveManager.getTroveStatus(_troveId);
        require(owner1 == msg.sender, "DCO: Not trove owner");
        require(status == 1, "DCO: Trove not active"); // 1 = active
        
        troveToUser[_troveId] = msg.sender;
        userTroves[msg.sender].push(_troveId);
        
        emit TroveRegistered(_troveId, msg.sender);
    }

    /**
     * @notice Unregister a trove from the optimizer
     * @param _troveId The ID of the trove to unregister
     */
    function unregisterTrove(uint256 _troveId) external onlyTroveOwner(_troveId) {
        delete troveToUser[_troveId];
        
        // Remove trove from user's array
        uint256[] storage troves = userTroves[msg.sender];
        for (uint256 i = 0; i < troves.length; i++) {
            if (troves[i] == _troveId) {
                troves[i] = troves[troves.length - 1];
                troves.pop();
                break;
            }
        }
        
        emit TroveUnregistered(_troveId, msg.sender);
    }

    // ============ Optimization Core Functions ============

    /**
     * @notice Optimizes a single trove's collateral composition
     * @param _troveId The ID of the trove to optimize
     */
    function optimizeCollateral(uint256 _troveId) 
        public 
        whenNotShutdown
        validRebalanceTiming
        nonReentrant 
    {

        lastCalled_global = uint32(block.timestamp);
        address user = troveToUser[_troveId];
        require(user != address(0), "DCO: Trove not registered");
        
        OptimizationStrategy storage strategy = userStrategies[user];
        
        // Get current trove data
        TroveData memory trove = _getTroveData(_troveId);
        
        // Get current collateral price
        (uint256 currentPrice, ) = priceFeed.fetchPrice();
        
        // Calculate current ICR and check if it's safe
        uint256 currentICR = troveManager.getCurrentICR(_troveId, currentPrice);
        require(currentICR >= MCR, "DCO: Trove below MCR");
        
        // Find the optimal collateral allocation
        CollateralAllocation memory optimalCollateral = _findOptimalCollateral(
            trove,
            strategy,
            currentPrice,
            currentICR
        );
        
        // Check if rebalancing is beneficial
        if (_isRebalanceWorthwhile(trove, optimalCollateral, strategy.rebalanceThreshold)) {
            // Execute the rebalancing
            _executeCollateralSwap(_troveId, trove, optimalCollateral);
            
            lastRebalanceTimestamp = block.timestamp;
        }
    }
    
    /**
     * @notice Batch optimizes multiple troves for gas efficiency
     * @param _troveIds Array of trove IDs to optimize
     */
    // function batchOptimizeTroves(uint256[] calldata _troveIds) 
    //     external
    //     whenNotShutdown
    //     validRebalanceTiming
    //     nonReentrant
    // {
    //     require(_troveIds.length > 0, "DCO: Empty troves array");
        
    //     for (uint256 i = 0; i < _troveIds.length; i++) {
    //         uint256 troveId = _troveIds[i];
    //         address user = troveToUser[troveId];
            
    //         // Skip if trove not registered or user not the owner
    //         if (user != msg.sender) continue;
            
    //         // Get strategy and trove data
    //         OptimizationStrategy storage strategy = userStrategies[user];
    //         TroveData memory trove = _getTroveData(troveId);
            
    //         // Get current price and ICR
    //         (uint256 currentPrice, ) = priceFeed.fetchPrice();
    //         uint256 currentICR = troveManager.getCurrentICR(troveId, currentPrice);
            
    //         // Skip if trove is unsafe
    //         if (currentICR < MCR) continue;
            
    //         // Find optimal allocation and check if rebalance is worthwhile
    //         CollateralAllocation memory optimalCollateral = _findOptimalCollateral(
    //             trove,
    //             strategy,
    //             currentPrice,
    //             currentICR
    //         );
            
    //         if (_isRebalanceWorthwhile(trove, optimalCollateral, strategy.rebalanceThreshold)) {
    //             _executeCollateralSwap(troveId, trove, optimalCollateral);
    //         }
    //     }
        
    //     lastRebalanceTimestamp = block.timestamp;
    // }

    // ============ Internal Functions ============

    /**
     * @dev Gets trove data in a structured format
     * @param _troveId The trove ID
     * @return TroveData struct with trove information
     */
    function _getTroveData(uint256 _troveId) internal view returns (TroveData memory) {
        uint256 debt = troveManager.getTroveDebt(_troveId);
        uint256 coll = troveManager.getTroveColl(_troveId);
        uint256 interestRate = troveManager.getTroveInterestRate(_troveId);
        uint8 status = uint8(troveManager.getTroveStatus(_troveId));
        address owner1 = troveNFT.ownerOf(_troveId);
        
        address collateralType = registry.collToken(); // In Bold protocol, this fetches the collateral token
        
        return TroveData({
            owner: owner1,
            debt: debt,
            coll: coll,
            interestRate: interestRate,
            status: status,
            collateralType: collateralType
        });
    }

    /**
     * @dev Finds the optimal collateral type based on user strategy
     * @param _trove Current trove data
     * @param _strategy User's optimization strategy
     * @param _price Current collateral price
     * @param _currentICR Current ICR of the trove
     * @return The optimal collateral allocation
     */
    function _findOptimalCollateral(
        TroveData memory _trove,
        OptimizationStrategy storage _strategy,
        uint256 _price,
        uint256 _currentICR
    ) internal view returns (CollateralAllocation memory) {
        address[] memory allowedCollaterals = _strategy.allowedCollaterals;
        
        // Initialize with current collateral data
        CollateralAllocation memory bestAllocation = CollateralAllocation({
            token: _trove.collateralType,
            amount: _trove.coll,
            yield: yieldOracle.getCollateralYield(_trove.collateralType),
            volatilityScore: 5 // Assuming median volatility for current collateral
        });
        
        uint256 highestScore = 0;
        
        // Evaluate each allowed collateral
        for (uint256 i = 0; i < allowedCollaterals.length; i++) {
            address collateralToken = allowedCollaterals[i];
            uint256 yield = yieldOracle.getCollateralYield(collateralToken);
            
            // Simulated volatility score (1-10, where 10 is most volatile)
            // In a real implementation, this would come from an oracle
            uint256 volatilityScore = 5; // Placeholder
            
            // Calculate score based on strategy priorities
            uint256 score;
            // @notice - see mathematics in readme file.
            if (_strategy.yieldPrioritized) {
                // Yield-prioritized scoring: yield is weighted by risk tolerance
                score = yield * _strategy.riskTolerance / (11 - _strategy.riskTolerance + volatilityScore);
            } else {
                // Safety-prioritized scoring: yield is weighted inversely to risk tolerance
                score = yield * (11 - _strategy.riskTolerance) / (_strategy.riskTolerance + volatilityScore);
            }
            
            // Keep track of highest scoring option
            if (score > highestScore) {
                highestScore = score;
                
                // Calculate equivalent amount preserving the same value
                uint256 equivalentAmount = _trove.coll; // For simplicity, assuming 1:1 price ratio
                
                bestAllocation = CollateralAllocation({
                    token: collateralToken,
                    amount: equivalentAmount,
                    yield: yield,
                    volatilityScore: volatilityScore
                });
            }
        }
        
        return bestAllocation;
    }

    /**
     * @dev Checks if rebalancing is worthwhile based on yield improvement and gas costs
     * @param _currentTrove Current trove data
     * @param _newCollateral New optimal collateral allocation
     * @param _threshold Minimum benefit threshold in basis points
     * @return Whether rebalancing is beneficial
     */
    function _isRebalanceWorthwhile(
        TroveData memory _currentTrove,
        CollateralAllocation memory _newCollateral,
        uint256 _threshold
    ) internal view returns (bool) {
        // If token is the same, no rebalancing needed
        if (_currentTrove.collateralType == _newCollateral.token) {
            return false;
        }
        
        // Calculate current yield and new yield
        uint256 currentYield = yieldOracle.getCollateralYield(_currentTrove.collateralType);
        uint256 newYield = _newCollateral.yield;
        
        // Calculate improvement in basis points
        if (newYield <= currentYield) {
            return false;
        }
        
        uint256 improvementBps = ((newYield - currentYield) * BASIS_POINTS) / currentYield;
        
        // Return true if improvement exceeds threshold
        return improvementBps >= _threshold;
    }

    /**
     * @dev Executes collateral swap by withdrawing and depositing
     * @param _troveId Trove ID to modify
     * @param _currentTrove Current trove data
     * @param _newCollateral New collateral allocation
     */
    function _executeCollateralSwap(
        uint256 _troveId,
        TroveData memory _currentTrove,
        CollateralAllocation memory _newCollateral
    ) internal {
        // First, withdraw current collateral
        // Note: In Bold Protocol, this would involve closing the trove and opening a new one
        // or using a specialized collateral swap function if available
        
        // For demonstration purposes, we'll simulate this with a two-step process:
        
        // 1. Create swap operation
        SwapOperation memory swap = SwapOperation({
            fromToken: _currentTrove.collateralType,
            toToken: _newCollateral.token,
            amountIn: _currentTrove.coll,
            minAmountOut: _calculateMinAmountOut(_currentTrove.coll, _currentTrove.collateralType, _newCollateral.token)
        });
        
        // 2. Execute the swap (this is simplified and would depend on the exact Bold protocol interface)
        uint256 newCollAmount = _executeSwap(swap);
        
        // 3. Update the trove with new collateral (simplified)
        // In practice, this would involve a series of Bold protocol operations
        
        emit TroveOptimized(
            _troveId,
            _currentTrove.owner,
            _currentTrove.collateralType,
            _newCollateral.token,
            newCollAmount
        );
    }

    /**
     * @dev Execute an actual token swap using a DEX
     * @param _swap The swap operation details
     * @return The amount of tokens received
     */
    function _executeSwap(SwapOperation memory _swap) internal returns (uint256) {
        // Approve the router to spend tokens
        IERC20(_swap.fromToken).approve(address(swapRouter), _swap.amountIn);
        
        // Create the swap path
        address[] memory path = new address[](2);
        path[0] = _swap.fromToken;
        path[1] = _swap.toToken;
        
        // Execute the swap
        uint256[] memory amounts = swapRouter.swapExactTokensForTokens(
            _swap.amountIn,
            _swap.minAmountOut,
            path,
            address(this),
            block.timestamp + 300 // 5 minute deadline
        );
        
        // Return the amount of tokens received
        return amounts[amounts.length - 1];
    }

    /**
     * @dev Calculate minimum output amount for a swap with slippage tolerance
     * @param _amountIn Input amount
     * @param _tokenIn Input token
     * @param _tokenOut Output token
     */
    function _calculateMinAmountOut(
        uint256 _amountIn, 
        address _tokenIn, 
        address _tokenOut
    ) internal view returns (uint256) {
        // In a real implementation, this would use proper price oracles and DEX quotes
        // For simplicity, we're assuming a 1:1 price ratio with 0.5% slippage tolerance
        return _amountIn * 995 / 1000; // 0.5% slippage
    }

    /**
     * @dev Checks if a collateral token is supported by the protocol
     * @param _collateral The collateral token address to check
     */
    function _isCollateralSupported(address _collateral) internal view returns (bool) {
        address[] memory supportedCollaterals = yieldOracle.getSupportedCollateral();
        
        for (uint256 i = 0; i < supportedCollaterals.length; i++) {
            if (supportedCollaterals[i] == _collateral) {
                return true;
            }
        }
        
        return false;
    }

    // ============ Admin Functions ============

    /**
     * @notice Updates the protocol fee percentage
     * @param _newFeePercent New fee percent in basis points
     */
    function setProtocolFee(uint256 _newFeePercent) external onlyOwner {
        require(_newFeePercent <= 1000, "DCO: Fee too high"); // Max 10%
        protocolFeePercent = _newFeePercent;
        emit ProtocolFeeChanged(_newFeePercent);
    }

    /**
     * @notice Updates the fee collector address
     * @param _newFeeCollector New fee collector address
     */
    function setFeeCollector(address _newFeeCollector) external onlyOwner {
        require(_newFeeCollector != address(0), "DCO: Invalid address");
        feeCollector = _newFeeCollector;
    }
    
    /**
     * @notice Updates the minimum time between rebalances
     * @param _newMinTime New minimum time in seconds
     */
    function setMinTimeBetweenRebalances(uint256 _newMinTime) external onlyOwner {
        minTimeBetweenRebalances = _newMinTime;
    }

    /**
     * @notice Emergency shutdown of the contract
     * @param _shutdown Whether to activate emergency shutdown
     */
    function setEmergencyShutdown(bool _shutdown) external onlyOwner {
        emergencyShutdown = _shutdown;
        emit EmergencyShutdown(_shutdown);
    }

    /**
     * @notice Update yield oracle address
     * @param _newYieldOracle New yield oracle address
     */
    function setYieldOracle(address _newYieldOracle) external onlyOwner {
        require(_newYieldOracle != address(0), "DCO: Invalid address");
        yieldOracle = IYieldOracle(_newYieldOracle);
    }

    /**
     * @notice Update swap router address
     * @param _newSwapRouter New swap router address
     */
    function setSwapRouter(address _newSwapRouter) external onlyOwner {
        require(_newSwapRouter != address(0), "DCO: Invalid address");
        swapRouter = ISwapRouter(_newSwapRouter);
    }
    
    /**
     * @notice Updates the Bold Protocol registry address and refreshes interfaces
     * @param _newRegistry New registry address
     */
    function updateRegistry(address _newRegistry) external onlyOwner {
        require(_newRegistry != address(0), "DCO: Invalid address");
        registry = IAddressesRegistry(_newRegistry);
        
        // Update interface pointers
        troveManager = ITroveManager(registry.troveManager());
        borrowerOperations = IBorrowerOperations(registry.borrowerOperations());
        priceFeed = IPriceFeed(registry.priceFeed());
    }
}
