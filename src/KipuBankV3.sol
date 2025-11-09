// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KipuBankV3 - DeFi-like vault with Uniswap V2 integration
/// @notice Accepts ETH, USDC, and any ERC20 with a direct USDC pair on Uniswap V2. Swaps to USDC and credits user balance, while enforcing a global bank cap and withdrawal limit.
/// @dev This contract is a pedagogical evolution of KipuBankV2. It preserves the core logic (per-user balances, events, reentrancy guard) and adds router-based deposits.

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

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

contract KipuBankV3 {
    // ===== STATE =====

    /// @notice Maximum total USDC (or USDC-equivalent) the contract will hold
    uint256 public immutable bankCap;

    /// @notice Maximum amount a user can withdraw per transaction (in USDC units)
    uint256 public immutable withdrawalLimit;

    /// @notice Uniswap V2 router used to perform swaps
    IUniswapV2Router02 public immutable router;

    /// @notice USDC token address used as accounting unit
    address public immutable usdc;

    /// @notice Per-user balances, always stored in USDC units
    mapping(address => uint256) private balances;

    /// @notice Number of deposits per user (preserved from V2 for observability)
    mapping(address => uint256) public depositCount;

    /// @notice Number of withdrawals per user (preserved from V2)
    mapping(address => uint256) public withdrawalCount;

    /// @notice Total USDC-equivalent stored in the bank
    uint256 public totalDeposits;

    /// @notice Simple reentrancy guard (1 = unlocked, 2 = locked)
    uint256 private _locked = 1;

    // ===== EVENTS =====

    event Deposit(address indexed user, uint256 amountUSDC);
    event Withdrawal(address indexed user, uint256 amountUSDC);

    // ===== ERRORS =====

    error ZeroAmount();
    error BankCapExceeded();
    error ExceedsWithdrawalLimit();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidParams();
    error Reentrancy();
    error NotUSDC();

    // ===== MODIFIERS =====

    modifier nonZero(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ===== CONSTRUCTOR =====

    /// @param _bankCap Max USDC the contract will hold (in USDC decimals)
    /// @param _withdrawalLimit Max USDC a user can withdraw per tx
    /// @param _router Uniswap V2 router address
    /// @param _usdc USDC token address
    constructor(
        uint256 _bankCap,
        uint256 _withdrawalLimit,
        address _router,
        address _usdc
    ) {
        if (_bankCap == 0 || _withdrawalLimit == 0 || _router == address(0) || _usdc == address(0)) {
            revert InvalidParams();
        }
        bankCap = _bankCap;
        withdrawalLimit = _withdrawalLimit;
        router = IUniswapV2Router02(_router);
        usdc = _usdc;
    }

    // ===== PUBLIC / EXTERNAL FUNCTIONS =====

    /// @notice Deposit native ETH, swap it to USDC through Uniswap V2 and credit the sender
    /// @dev Uses path [WETH, USDC]. amountOutMin = 0 for simplicity (see README threat analysis).
    function depositETH() external payable nonReentrant nonZero(msg.value) {
        address weth = router.WETH();

        address;
        path[0] = weth;
        path[1] = usdc;

        // swap ETH -> USDC
        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0, // amountOutMin (see README: should be improved)
            path,
            address(this),
            block.timestamp
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        _credit(msg.sender, usdcReceived);
    }

    /// @notice Deposit USDC directly (no swap needed)
    /// @param amount Amount of USDC to deposit
    function depositUSDC(uint256 amount) external nonReentrant nonZero(amount) {
        // pull USDC from user
        bool ok = IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        _credit(msg.sender, amount);
    }

    /// @notice Deposit any ERC20 that has a direct pair with USDC on Uniswap V2
    /// @param token Address of the ERC20 token
    /// @param amount Amount of token to deposit
    function depositToken(address token, uint256 amount) external nonReentrant nonZero(amount) {
        if (token == usdc) {
            // if it's actually USDC, treat it as a direct deposit
            bool ok0 = IERC20(usdc).transferFrom(msg.sender, address(this), amount);
            if (!ok0) revert TransferFailed();
            _credit(msg.sender, amount);
            return;
        }

        // pull tokens from user
        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        // approve router to spend
        // NOTE: for production you'd want to reset allowance or use SafeERC20
        IERC20(token).approve(address(router), amount);

        address;
        path[0] = token;
        path[1] = usdc;

        uint[] memory amounts = router.swapExactTokensForTokens(
            amount,
            0,              // amountOutMin = 0 (see README)
            path,
            address(this),
            block.timestamp
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        _credit(msg.sender, usdcReceived);
    }

    /// @notice Withdraw USDC previously deposited/swapped, respecting per-tx limit
    /// @param amount Amount of USDC to withdraw
    function withdraw(uint256 amount) external nonReentrant nonZero(amount) {
        uint256 userBalance = balances[msg.sender];
        if (amount > userBalance) revert InsufficientBalance();
        if (amount > withdrawalLimit) revert ExceedsWithdrawalLimit();

        // effects
        balances[msg.sender] = userBalance - amount;
        unchecked {
            totalDeposits -= amount;
            withdrawalCount[msg.sender]++;
        }

        // interaction
        bool ok = IERC20(usdc).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    /// @notice Read user balance in USDC units
    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    /// @notice Allow direct ETH sends to trigger deposit
    receive() external payable {
        // mirror depositETH() but with minimal overhead
        address weth = router.WETH();

        address;
        path[0] = weth;
        path[1] = usdc;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        _credit(msg.sender, usdcReceived);
    }

    // ===== INTERNAL LOGIC =====

    /// @dev Centralized crediting logic: enforces bankCap, updates balances and counters
    function _credit(address user, uint256 amountUSDC) internal {
        // check cap BEFORE writing
        uint256 newTotal = totalDeposits + amountUSDC;
        if (newTotal > bankCap) revert BankCapExceeded();

        balances[user] += amountUSDC;
        totalDeposits = newTotal;

        unchecked {
            depositCount[user]++;
        }

        emit Deposit(user, amountUSDC);
    }
}

