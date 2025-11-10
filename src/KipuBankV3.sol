// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBankV3 - DeFi vault with automatic USDC conversion
 * @author Corina Puyuelo
 * @notice This contract allows users to deposit ETH, USDC, or any ERC20 token supported by Uniswap V2.
 * All non-USDC tokens are automatically swapped to USDC using the Uniswap V2 router.
 * The contract maintains all internal accounting in USDC (6 decimals), enforcing a global USD-denominated cap.
 * @dev Implements CEI (Checks-Effects-Interactions) pattern, uses Ownable access control,
 * integrates Chainlink Data Feeds for price validation, and minimizes gas by reducing storage access.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal interface for Uniswap V2 Router (only required swap methods)
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract KipuBankV3 is Ownable {

    // ============ VARIABLES ============

    /// @notice Maximum total value (in USD, 6 decimals like USDC) the bank may hold.
    uint256 public immutable bankCapUSD;

    /// @notice Per-transaction withdrawal limit, denominated in USDC (6 decimals).
    uint256 public immutable withdrawalLimit;

    /// @notice Address of the USDC token contract.
    address public immutable usdc;

    /// @notice Instance of the Uniswap V2 router used for token swaps.
    IUniswapV2Router02 public immutable router;

    /// @notice Chainlink ETH/USD price feed used to enforce USD-denominated cap.
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Mapping of user address to their vault balance (in USDC).
    mapping(address => uint256) private balances;

    /// @notice Number of deposits per user (for tracking activity).
    mapping(address => uint256) public depositCount;

    /// @notice Number of withdrawals per user (for tracking activity).
    mapping(address => uint256) public withdrawalCount;

    /// @notice Total USDC currently deposited in the bank.
    uint256 public totalDeposits;

    /// @notice Reentrancy guard flag (1 = unlocked, 2 = locked).
    uint256 private _locked = 1;

    // ============ EVENTS ============

    /// @notice Emitted when a user deposits USDC into the bank.
    /// @param user Address of the depositor.
    /// @param amountUSDC Amount of USDC credited.
    event Deposit(address indexed user, uint256 amountUSDC);

    /// @notice Emitted when a user withdraws USDC from the bank.
    /// @param user Address of the withdrawer.
    /// @param amountUSDC Amount of USDC withdrawn.
    event Withdrawal(address indexed user, uint256 amountUSDC);

    /// @notice Emitted when a token is swapped to USDC via Uniswap.
    /// @param user Address initiating the swap.
    /// @param tokenIn Token address being swapped.
    /// @param amountIn Amount of input token.
    /// @param amountOutUSDC Resulting USDC received.
    event TokenSwapped(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOutUSDC);

    // ============ ERRORS ============

    /// @notice Thrown when a function receives a zero amount.
    error ZeroAmount();

    /// @notice Thrown when total bank deposits would exceed the USD-denominated cap.
    error BankCapExceeded();

    /// @notice Thrown when a user tries to withdraw more than the allowed per-transaction limit.
    error ExceedsWithdrawalLimit();

    /// @notice Thrown when a user attempts to withdraw more than their balance.
    error InsufficientBalance();

    /// @notice Thrown when an ERC20 or native transfer fails.
    error TransferFailed();

    /// @notice Thrown when invalid constructor parameters are provided.
    error InvalidParams();

    /// @notice Thrown when a reentrancy attempt is detected.
    error Reentrancy();

    // ============ MODIFIERS ============

    /// @notice Ensures that an amount parameter is non-zero.
    /// @param _amount The amount to validate.
    modifier nonZero(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    /// @notice Simple reentrancy protection mechanism.
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ============ CONSTRUCTOR ============

    /**
     * @notice Deploys the KipuBankV3 contract.
     * @param _bankCapUSD Global bank cap in USD (6 decimals, same as USDC).
     * @param _withdrawalLimit Maximum per-transaction withdrawal limit (in USDC).
     * @param _router Address of the Uniswap V2 router.
     * @param _usdc Address of the USDC token contract.
     * @param _priceFeed Address of the Chainlink ETH/USD price feed.
     */
    constructor(
        uint256 _bankCapUSD,
        uint256 _withdrawalLimit,
        address _router,
        address _usdc,
        address _priceFeed
    ) {
        if (
            _bankCapUSD == 0 ||
            _withdrawalLimit == 0 ||
            _router == address(0) ||
            _usdc == address(0) ||
            _priceFeed == address(0)
        ) revert InvalidParams();

        bankCapUSD = _bankCapUSD;
        withdrawalLimit = _withdrawalLimit;
        router = IUniswapV2Router02(_router);
        usdc = _usdc;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // ============ FUNCTIONS ============

    /**
     * @notice Allows a user to deposit native ETH, which is automatically swapped to USDC.
     * @dev Uses Uniswap V2's swapExactETHForTokens. Emits TokenSwapped and Deposit.
     */
    function depositETH() external payable nonZero(msg.value) nonReentrant {
        address ;
        path[0] = router.WETH();
        path[1] = usdc;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0, path, address(this), block.timestamp
        );
        uint256 usdcOut = amounts[1];
        emit TokenSwapped(msg.sender, path[0], msg.value, usdcOut);

        _handleDeposit(msg.sender, usdcOut);
    }

    /**
     * @notice Deposits USDC directly without swaps.
     * @param amount Amount of USDC to deposit (6 decimals).
     */
    function depositUSDC(uint256 amount) external nonZero(amount) nonReentrant {
        bool ok = IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        _handleDeposit(msg.sender, amount);
    }

    /**
     * @notice Deposits any ERC20 token supported by Uniswap V2 and converts it to USDC.
     * @param token Address of the ERC20 token to deposit.
     * @param amount Amount of token to deposit.
     */
    function depositToken(address token, uint256 amount) external nonZero(amount) nonReentrant {
        if (token == usdc) {
            depositUSDC(amount);
            return;
        }

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        IERC20(token).approve(address(router), amount);

        address ;
        path[0] = token;
        path[1] = usdc;

        uint[] memory amounts = router.swapExactTokensForTokens(
            amount, 0, path, address(this), block.timestamp
        );
        uint256 usdcOut = amounts[1];
        emit TokenSwapped(msg.sender, token, amount, usdcOut);

        _handleDeposit(msg.sender, usdcOut);
    }

    /**
     * @notice Withdraws USDC up to the per-transaction limit.
     * @param amount Amount of USDC to withdraw.
     */
    function withdraw(uint256 amount) external nonZero(amount) nonReentrant {
        uint256 userBalance = balances[msg.sender];
        if (amount > userBalance) revert InsufficientBalance();
        if (amount > withdrawalLimit) revert ExceedsWithdrawalLimit();

        balances[msg.sender] = userBalance - amount;
        unchecked {
            totalDeposits -= amount;
            withdrawalCount[msg.sender]++;
        }

        bool ok = IERC20(usdc).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    /**
     * @notice Returns the USDC balance of a user.
     * @param user Address to query.
     * @return balance User balance in USDC.
     */
    function getBalance(address user) external view returns (uint256 balance) {
        return balances[user];
    }

    /**
     * @notice Handles the internal logic of crediting user balances.
     * @dev Enforces the bank cap in USD before updating storage.
     * @param user Address of the depositor.
     * @param amountUSDC Amount of USDC credited.
     */
    function _handleDeposit(address user, uint256 amountUSDC) private {
        uint256 newTotal = totalDeposits + amountUSDC;
        if (_exceedsCapInUSD(newTotal)) revert BankCapExceeded();

        balances[user] += amountUSDC;
        unchecked { depositCount[user]++; }
        totalDeposits = newTotal;

        emit Deposit(user, amountUSDC);
    }

    /**
     * @notice Compares the total deposits (in USDC) to the USD-denominated bank cap.
     * @dev Uses Chainlink ETH/USD feed for normalization (feed 8 decimals → USDC 6 decimals).
     * @param newTotalUSDC The new total USDC balance after deposit.
     * @return exceeded True if the new total exceeds the allowed USD cap.
     */
    function _exceedsCapInUSD(uint256 newTotalUSDC) private view returns (bool exceeded) {
        (, int256 ethUsd,,,) = priceFeed.latestRoundData();
        require(ethUsd > 0, "Invalid oracle price");

        // Normalize between 8-decimal price feed and 6-decimal USDC
        uint256 capUSDC = (bankCapUSD * 1e8) / uint256(ethUsd);
        return newTotalUSDC > capUSDC;
    }

    /**
     * @notice Fallback to receive ETH directly.
     * @dev Automatically routes ETH deposits through depositETH().
     */
    receive() external payable {
        depositETH();
    }
}
