// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBankV3 - DeFi vault with USDC normalization and direct Uniswap V2 swap
 * @author Corina Puyuelo
 * @notice This contract allows users to deposit ETH, USDC, or any ERC-20 token that has a direct USDC pair on Uniswap V2.
 * Every non-USDC asset is immediately converted into USDC and the internal accounting is kept in 6-decimal USDC.
 * If the incoming token does not have a direct USDC pool on Uniswap V2, the transaction reverts to preserve the vault invariant.
 * @dev This is a self-contained version for Remix: it inlines minimal Ownable, ReentrancyGuard, ERC-20, Chainlink and Uniswap interfaces.
 * Uses CEI pattern, enforces a global USDC-denominated cap, and exposes admin functions to adjust limits.
 */

/*//////////////////////////////////////////////////////////////
                        MINIMAL INTERFACES
//////////////////////////////////////////////////////////////*/

/**
 * @dev Minimal ERC-20 interface used for transfers and allowances.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/**
 * @dev Minimal WETH interface: ERC-20 + deposit() to wrap ETH.
 */
interface IWETH is IERC20 {
    function deposit() external payable;
}

/**
 * @dev Minimal Uniswap V2 router interface, only used to read WETH and factory.
 */
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
}

/**
 * @dev Minimal Uniswap V2 factory interface, used to get the pair for tokenIn-tokenOut.
 */
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @dev Minimal Uniswap V2 pair interface, used to read reserves and execute the swap.
 */
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @dev Trimmed Chainlink AggregatorV3Interface, used only for price reads.
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/*//////////////////////////////////////////////////////////////
                        MINIMAL OWNABLE
//////////////////////////////////////////////////////////////*/

/**
 * @title Ownable (minimal)
 * @notice Basic access control: a single account (the owner) can perform admin actions.
 * @dev Owner is passed explicitly in the child contract constructor.
 */
abstract contract Ownable {
    /// @notice Current contract owner.
    address private _owner;

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Initializes the contract setting the deployer (or given address) as the initial owner.
     * @param initialOwner Address that will be granted admin privileges.
     */
    constructor(address initialOwner) {
        require(initialOwner != address(0), "Owner zero");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /**
     * @notice Restricts a function to the current owner.
     */
    modifier onlyOwner() {
        require(msg.sender == _owner, "Not owner");
        _;
    }

    /**
     * @notice Returns the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @notice Transfers ownership to a new address.
     * @param newOwner Address of the new owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Owner zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/*//////////////////////////////////////////////////////////////
                    MINIMAL REENTRANCY GUARD
//////////////////////////////////////////////////////////////*/

/**
 * @title ReentrancyGuard (minimal)
 * @notice Protects sensitive functions from reentrant calls.
 * @dev Classic two-state pattern.
 */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @dev Reentrancy status
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @notice Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/*//////////////////////////////////////////////////////////////
                        KIPUBANK V3
//////////////////////////////////////////////////////////////*/

/**
 * @title KipuBankV3
 * @notice DeFi vault that normalizes all incoming assets to USDC and keeps a global cap.
 * @dev Uses direct Uniswap V2 pair swaps (not router swaps) to reduce gas.
 * If no direct token→USDC pair exists, the transaction reverts.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard {

    /*//////////////////////////////////////////////////////////////
                            VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V2 router, used only to read WETH and factory.
    IUniswapV2Router02 public immutable router;

    /// @notice Uniswap V2 factory, used to fetch token→USDC pairs.
    IUniswapV2Factory public immutable factory;

    /// @notice USDC token (6 decimals) used as the internal accounting unit.
    IERC20 public immutable usdc;

    /// @notice WETH token for this network, used to wrap incoming ETH.
    IWETH public immutable weth;

    /// @notice Chainlink ETH/USD price feed (kept for external price reads).
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Global vault cap in USDC (6 decimals). Total USDC in the vault cannot exceed this.
    uint256 public bankCapUSD;

    /// @notice Per-transaction withdrawal limit in USDC (6 decimals).
    uint256 public withdrawalLimit;

    /// @notice Total amount of USDC currently accounted in the vault.
    uint256 public totalUSDC;

    /// @notice Mapping of user address to their USDC-denominated balance.
    mapping(address => uint256) public balances;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted whenever a deposit is credited to a user.
     * @param user Address of the depositor.
     * @param amountUSDC Amount of USDC credited (6 decimals).
     */
    event Deposit(address indexed user, uint256 amountUSDC);

    /**
     * @notice Emitted whenever a withdrawal is performed.
     * @param user Address of the withdrawer.
     * @param amountUSDC Amount of USDC withdrawn.
     */
    event Withdrawal(address indexed user, uint256 amountUSDC);

    /**
     * @notice Emitted whenever a token is swapped to USDC through a Uniswap V2 pair.
     * @param user Address that initiated the swap (the depositor).
     * @param tokenIn Address of the input token.
     * @param amountIn Amount of input tokens sent to the pair.
     * @param amountUSDCOut Amount of USDC received from the swap.
     */
    event TokenSwapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountUSDCOut);

    /**
     * @notice Emitted when the global bank cap is updated.
     * @param newCapUSDC New cap value in USDC.
     */
    event BankCapUpdated(uint256 newCapUSDC);

    /**
     * @notice Emitted when the per-transaction withdrawal limit is updated.
     * @param newLimitUSDC New per-transaction withdrawal limit in USDC.
     */
    event WithdrawalLimitUpdated(uint256 newLimitUSDC);


    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a function is called with a zero amount.
    error ZeroAmount();

    /// @notice Thrown when an ERC-20 transfer or pair transfer fails.
    error TransferFailed();

    /// @notice Thrown when a deposit would push the vault over its global USDC cap.
    error CapExceeded();

    /// @notice Thrown when a withdrawal exceeds the per-transaction limit.
    error WithdrawalLimitExceeded();

    /// @notice Thrown when there is no direct token→USDC Uniswap V2 pair for the token being deposited.
    error NoDirectUSDCPath();


    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures that the provided amount is greater than zero.
     * @param amount Amount to validate.
     */
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the vault with all core dependencies.
     * @param initialOwner Address that will be set as the contract owner.
     * @param _bankCapUSD Global bank cap in USDC (6 decimals).
     * @param _withdrawalLimit Per-transaction withdrawal limit in USDC (6 decimals).
     * @param _router Address of the Uniswap V2 router (to read WETH and factory).
     * @param _usdc Address of the USDC token.
     * @param _priceFeed Address of the Chainlink ETH/USD price feed.
     */
    constructor(
        address initialOwner,
        uint256 _bankCapUSD,
        uint256 _withdrawalLimit,
        address _router,
        address _usdc,
        address _priceFeed
    )
        Ownable(initialOwner)
    {
        require(_router != address(0), "router zero");
        require(_usdc != address(0), "usdc zero");
        require(_priceFeed != address(0), "priceFeed zero");

        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(IUniswapV2Router02(_router).factory());
        usdc = IERC20(_usdc);
        weth = IWETH(IUniswapV2Router02(_router).WETH());
        priceFeed = AggregatorV3Interface(_priceFeed);

        bankCapUSD = _bankCapUSD;
        withdrawalLimit = _withdrawalLimit;
    }

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits native ETH into the vault.
     * @dev ETH is wrapped to WETH, then swapped directly WETH→USDC through the pair.
     * Reverts if no WETH/USDC pair exists.
     */
    function depositETH() external payable nonZero(msg.value) nonReentrant {
        _handleETHDeposit(msg.sender, msg.value);
    }

    /**
     * @notice Internal handler for ETH deposits, used by both depositETH() and receive().
     * @param depositor Address to credit.
     * @param amount Amount of ETH sent.
     */
    function _handleETHDeposit(address depositor, uint256 amount) internal {
        // wrap ETH
        weth.deposit{value: amount}();

        // swap WETH → USDC (must exist)
        uint256 usdcOut = _swapDirect(address(weth), address(usdc), amount);

        emit TokenSwapped(depositor, address(weth), amount, usdcOut);

        // credit user
        _handleDeposit(depositor, usdcOut);
    }

    /**
     * @notice Deposits USDC directly into the vault.
     * @param amount Amount of USDC to deposit (6 decimals).
     */
    function depositUSDC(uint256 amount) public nonZero(amount) nonReentrant {
        bool ok = usdc.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        _handleDeposit(msg.sender, amount);
    }

    /**
     * @notice Deposits any ERC-20 supported by a direct USDC pair in Uniswap V2.
     * @dev If the token is already USDC, it is forwarded to depositUSDC().
     * If there is no direct token→USDC pair, reverts.
     * @param token ERC-20 token address to deposit.
     * @param amount Amount of the token to deposit.
     */
    function depositToken(address token, uint256 amount) external nonZero(amount) nonReentrant {
        // shortcut for USDC
        if (token == address(usdc)) {
            depositUSDC(amount);
            return;
        }

        // pull tokens into this contract
        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        // swap token → USDC through the direct pair (or revert)
        uint256 usdcOut = _swapDirect(token, address(usdc), amount);

        emit TokenSwapped(msg.sender, token, amount, usdcOut);

        _handleDeposit(msg.sender, usdcOut);
    }

    /**
     * @notice Withdraws USDC from the caller's balance.
     * @dev Enforces per-tx withdrawal limit and balance sufficiency.
     * @param amount Amount of USDC (6 decimals) to withdraw.
     */
    function withdraw(uint256 amount) external nonZero(amount) nonReentrant {
        if (amount > withdrawalLimit) revert WithdrawalLimitExceeded();

        uint256 bal = balances[msg.sender];
        require(bal >= amount, "insufficient balance");

        // effects
        unchecked {
            balances[msg.sender] = bal - amount;
            totalUSDC -= amount;
        }

        // interaction
        bool ok = usdc.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    /**
     * @notice Common internal deposit logic: enforces cap, updates storage, emits event.
     * @param user Address to credit.
     * @param amountUSDC Amount of USDC to credit.
     */
    function _handleDeposit(address user, uint256 amountUSDC) internal {
        uint256 newTotal = totalUSDC + amountUSDC;
        if (newTotal > bankCapUSD) revert CapExceeded();

        totalUSDC = newTotal;
        balances[user] += amountUSDC;

        emit Deposit(user, amountUSDC);
    }

    /**
     * @notice Performs a direct Uniswap V2 pair swap (tokenIn → tokenOut).
     * @dev This contract assumes a 0.3% fee pair (997/1000). If the pair does not exist, reverts.
     * @param tokenIn Token to send to the pair.
     * @param tokenOut Token to receive from the pair (USDC in our use case).
     * @param amountIn Amount of tokenIn to swap.
     * @return amountOut Amount of tokenOut received.
     */
    function _swapDirect(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        // fetch the pair
        address pair = factory.getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert NoDirectUSDCPath();

        // read reserves
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        // send tokenIn to the pair
        bool ok = IERC20(tokenIn).transfer(pair, amountIn);
        if (!ok) revert TransferFailed();

        // compute amountOut using Uniswap V2 formula
        if (tokenIn == token0) {
            // tokenIn is token0 → we output token1
            uint256 amountInWithFee = amountIn * 997;
            uint256 numerator = amountInWithFee * reserve1;
            uint256 denominator = uint256(reserve0) * 1000 + amountInWithFee;
            amountOut = numerator / denominator;

            IUniswapV2Pair(pair).swap(0, amountOut, address(this), "");
        } else if (tokenIn == token1) {
            // tokenIn is token1 → we output token0
            uint256 amountInWithFee = amountIn * 997;
            uint256 numerator = amountInWithFee * reserve0;
            uint256 denominator = uint256(reserve1) * 1000 + amountInWithFee;
            amountOut = numerator / denominator;

            IUniswapV2Pair(pair).swap(amountOut, 0, address(this), "");
        } else {
            // safety: tokenIn must be one of the two tokens in the pair
            revert NoDirectUSDCPath();
        }
    }

    /**
     * @notice Updates the global USDC-denominated cap.
     * @dev Only callable by the owner.
     * @param newCapUSDC New global cap, in USDC (6 decimals).
     */
    function setBankCap(uint256 newCapUSDC) external onlyOwner {
        bankCapUSD = newCapUSDC;
        emit BankCapUpdated(newCapUSDC);
    }

    /**
     * @notice Updates the per-transaction withdrawal limit.
     * @dev Only callable by the owner.
     * @param newLimitUSDC New per-tx withdrawal limit, in USDC (6 decimals).
     */
    function setWithdrawalLimit(uint256 newLimitUSDC) external onlyOwner {
        withdrawalLimit = newLimitUSDC;
        emit WithdrawalLimitUpdated(newLimitUSDC);
    }

    /**
     * @notice Returns the USDC balance of a given account.
     * @param user Address to query.
     * @return balanceUSDC USDC balance (6 decimals).
     */
    function getBalance(address user) external view returns (uint256 balanceUSDC) {
        return balances[user];
    }

    /**
     * @notice Returns the latest ETH/USD price from Chainlink.
     * @dev Returned value has the decimals defined by the specific feed (commonly 8).
     */
    function getLatestETHPrice() external view returns (int256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        return price;
    }

    /**
     * @notice Allows sending ETH directly to the contract and treats it as a deposit.
     * @dev Calls the internal ETH deposit handler to keep logic DRY.
     */
    receive() external payable {
        if (msg.value > 0) {
            _handleETHDeposit(msg.sender, msg.value);
        }
    }
}
