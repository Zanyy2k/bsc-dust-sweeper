// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

contract DustSweeper is ReentrancyGuard {
    address public owner;
    address public feeRecipient;
    uint256 public feeBps;         // e.g. 1500 = 15%
    uint256 public slippageBps;    // e.g. 500 = 5% max slippage
    uint256 public constant MAX_TOKENS_PER_SWEEP = 20;

    IPancakeRouter public router;
    address public wbnb;

    mapping(address => bool) public whitelistedTokens;

    event Swept(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 userReceived,
        uint256 feeAmount
    );
    event TokenWhitelisted(address indexed token, bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _router, address _feeRecipient, uint256 _feeBps) {
        require(_router != address(0) && _feeRecipient != address(0), "zero address");
        require(_feeBps <= 3000, "max 30%");
        owner = msg.sender;
        router = IPancakeRouter(_router);
        wbnb = router.WETH();
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        slippageBps = 500;
    }

    // Bot calls this to sweep dust tokens for a user
    function sweep(address user, address[] calldata tokens) external nonReentrant {
        require(tokens.length <= MAX_TOKENS_PER_SWEEP, "too many tokens");
        for (uint256 i = 0; i < tokens.length; i++) {
            if (whitelistedTokens[tokens[i]]) {
                _sweepToken(user, tokens[i]);
            }
        }
    }

    function _sweepToken(address user, address token) internal {
        IERC20 erc20 = IERC20(token);

        uint256 allowance = erc20.allowance(user, address(this));
        if (allowance == 0) return;

        uint256 balance = erc20.balanceOf(user);
        uint256 amount = allowance < balance ? allowance : balance;
        if (amount == 0) return;

        // Calculate minimum BNB output with slippage protection
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wbnb;

        uint256 expectedOut;
        try router.getAmountsOut(amount, path) returns (uint[] memory amounts) {
            expectedOut = amounts[1];
        } catch {
            return; // no liquidity, skip
        }
        if (expectedOut == 0) return;

        uint256 amountOutMin = expectedOut * (10000 - slippageBps) / 10000;

        uint256 balanceBefore = erc20.balanceOf(address(this));
        if (!erc20.transferFrom(user, address(this), amount)) return;
        uint256 actualAmount = erc20.balanceOf(address(this)) - balanceBefore; // handles fee-on-transfer
        if (actualAmount == 0) return;

        erc20.approve(address(router), actualAmount);

        uint256 bnbBefore = address(this).balance;

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            actualAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp + 300
        ) {
            uint256 received = address(this).balance - bnbBefore;
            if (received == 0) return;

            uint256 fee = (received * feeBps) / 10000;
            uint256 userAmount = received - fee;

            if (fee > 0) {
                (bool s1, ) = feeRecipient.call{value: fee}("");
                require(s1, "fee transfer failed");
            }
            if (userAmount > 0) {
                (bool s2, ) = user.call{value: userAmount}("");
                require(s2, "user transfer failed");
            }

            emit Swept(user, token, amount, userAmount, fee);
        } catch {
            // return whatever we actually hold (not original amount)
            uint256 remaining = erc20.balanceOf(address(this)) - balanceBefore;
            if (remaining > 0) erc20.transfer(user, remaining);
        }
    }

    // Owner adds/removes tokens from whitelist
    function setTokenWhitelist(address token, bool status) external onlyOwner {
        require(token != address(0) && token != wbnb, "invalid token");
        whitelistedTokens[token] = status;
        emit TokenWhitelisted(token, status);
    }

    function setTokenWhitelistBatch(address[] calldata tokens, bool status) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && tokens[i] != wbnb, "invalid token");
            whitelistedTokens[tokens[i]] = status;
            emit TokenWhitelisted(tokens[i], status);
        }
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "zero address");
        feeRecipient = _feeRecipient;
    }

    function rescueBNB() external onlyOwner {
        (bool ok, ) = owner.call{value: address(this).balance}("");
        require(ok, "transfer failed");
    }

    function rescueToken(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(owner, bal);
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 3000, "max 30%");
        feeBps = _feeBps;
    }

    function setSlippageBps(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= 2000, "max 20%");
        slippageBps = _slippageBps;
    }

    receive() external payable {}
}
